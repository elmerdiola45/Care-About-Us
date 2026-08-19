import 'medicine_dictionary_service.dart';

/// Looks up real per-unit prices for the MDRP price section — sourced
/// ONLY from this pharmacy's own catalog (CARE-ABOUT-US-PHARMACY.docx,
/// seeded into `products`, served by GET
/// /api/pharmacies/{id}/medicines). There is no hardcoded price map
/// here anymore: [priceFor] reads whatever
/// [MedicineDictionaryService.variantsFor] has cached for that name,
/// which is only ever populated from the backend call.
///
/// A medicine matched through the PNF-EML offline fallback (no backend
/// reachable) has no variants cached at all, so this correctly returns
/// 0.0 ("needs manual entry") rather than inventing a number — pricing
/// a fallback-matched name against another pharmacy's/EML's price would
/// be actively wrong, not just imprecise.
///
/// Many generic names have several priced SKUs (different dosage/form,
/// sometimes different brand) — e.g. "Amoxicillin" alone has 6+ entries
/// in the real catalog at different strengths. [priceFor] matches on
/// the OCR-extracted dosage string against each variant's dosage_form
/// (normalized: lowercased, non-alphanumeric stripped, so "500mg" and
/// "500 MG." compare equal).
///
/// OCR handwriting reads regularly mis-scan a single digit (e.g. "500mg"
/// read as "580mg" — a 0/8 mixup). Rather than dropping straight to
/// "needs manual entry" the moment the exact string doesn't match, we
/// fall back to the numerically CLOSEST same-unit strength (e.g. "580mg"
/// -> "500 MG", not "250 MG"). This only ever compares plain
/// "<number><unit>" strengths (mg/mcg/g/ml) against each other — ratio/
/// suspension forms like "125/60ML" are never pulled in as a nearest
/// match for a plain strength, since a number-only distance between
/// "580mg" and "125/60ml" is meaningless.
///
/// A match found this way is flagged as NOT exact (see [PriceLookupResult]
/// / [isExactMatch]) so the UI can visibly ask the pharmacist to verify
/// the dosage rather than silently trusting a guess — still safer for
/// MDRP compliance than either a bare 0.00 or a silent wrong price.
///
/// This only ever activates when the target dosage parses as a
/// plain strength AND at least one same-unit candidate exists. If
/// nothing comparable exists, or no dosage was extracted at all, and
/// there's more than one priced variant for that name, this still
/// returns "no match" — there's nothing sensible left to guess.
///
/// Several SKUs commonly share the SAME dosage but differ by brand
/// (e.g. plain "Amoxicillin 500 MG" vs. "Amoxicillin (Himox) 500 MG"
/// vs. "Amoxicillin (Amoxil) 500 MG") — different real prices for the
/// exact same strength. If the prescription itself named a brand, that
/// brand is matched directly. If it didn't, and more than one brand
/// exists at the resolved dosage, [lookup] does NOT silently guess
/// between them — it returns [needsBrandSelection] = true with the
/// full [candidates] list so the pharmacist picks the actual box on
/// the shelf.
class PriceLookupResult {
  final double unitPrice;

  /// True if this came from an exact dosage-string match (or the name
  /// only had one SKU at all). False if this came from the
  /// nearest-strength fallback and should be visibly flagged for the
  /// pharmacist to double check.
  final bool isExactMatch;

  /// The specific SKU this price came from, if one was resolved.
  final MedicineVariant? variant;

  /// True when there are multiple same-dosage SKUs differing only by
  /// brand and no brand could be resolved automatically (prescription
  /// didn't name one, or named one that isn't in [candidates]) — the
  /// UI should show [candidates] as a picker instead of trusting
  /// [unitPrice], which is 0.0 in this case.
  final bool needsBrandSelection;

  /// True when [medicineName] has ZERO SKUs in this pharmacy's catalog
  /// at all — not a different dosage, not a different brand, nothing.
  /// The pharmacist needs to know this isn't stocked here at all
  /// (rather than seeing an unexplained ₱0.00), see [.notFound].
  final bool medicineNotFound;

  /// True when [medicineName] IS in the catalog, but nothing stocked
  /// is close enough to the requested/OCR'd dosage to treat as the
  /// same SKU (see [PriceLookupService._kMaxNearestRelativeDiff]) —
  /// e.g. the prescription calls for 500mg and this pharmacy only
  /// carries 250mg. Distinct from [needsBrandSelection]: this is a
  /// stock gap, not an ambiguous-but-available choice.
  final bool dosageNotStocked;

  /// All same-dosage SKUs to choose from when [needsBrandSelection] is
  /// true, or every SKU this pharmacy stocks for the name when
  /// [dosageNotStocked] is true (so the UI can show what IS
  /// available), or the single resolved variant otherwise.
  final List<MedicineVariant> candidates;

  const PriceLookupResult({
    required this.unitPrice,
    required this.isExactMatch,
    this.variant,
    this.needsBrandSelection = false,
    this.medicineNotFound = false,
    this.dosageNotStocked = false,
    this.candidates = const [],
  });

  static const notFound = PriceLookupResult(
    unitPrice: 0.0,
    isExactMatch: true,
    medicineNotFound: true,
  );
}

class PriceLookupService {
  /// A "nearest strength" fallback is only accepted when it's within
  /// this fraction of the requested dosage — e.g. "580mg" (a plausible
  /// 8/0 OCR digit-misread of "500mg") is 16% off and still snaps to
  /// "500 MG". A prescription genuinely calling for 500mg when this
  /// pharmacy only stocks 250mg is 100% off and must NOT be silently
  /// substituted — that's a different strength, not a misread of the
  /// same one, and dispensing/pricing it as if it matched would be
  /// wrong on both counts. Anything beyond this tolerance is reported
  /// as [PriceLookupResult.dosageNotStocked] instead of guessed.
  static const double _kMaxNearestRelativeDiff = 0.20;

  /// Resolves [dosage] against [medicineName]'s known variants and
  /// returns the corrected/nearest known dosage LABEL (not just a
  /// price) — reuses the exact same matching rules as [lookup] (see
  /// [_variantsAtDosage]): exact normalized-string match preferred,
  /// else the numerically nearest same-unit plain strength, never a
  /// ratio/suspension form.
  ///
  /// Returns [dosage] unchanged with `isExact: true` when there's
  /// nothing safe to compare against (no cached variants, dosage
  /// isn't a plain strength, or it already matches exactly) — this
  /// never invents a dosage, only snaps to something this pharmacy
  /// actually stocks.
  ///
  /// [lookup]'s price calculation and this method now share one path
  /// through [_variantsAtDosage] rather than two independently-drifting
  /// copies of "what counts as close enough" — this exists specifically
  /// so [PrescriptionParserService] can correct the dosage TEXT shown
  /// on the review screen (e.g. "580mg" -> "500 MG"), not just get a
  /// price computed silently behind an unchanged, still-wrong label.
  static ({String dosage, bool isExact}) resolveDosageLabel(
    String medicineName,
    String dosage,
  ) {
    if (dosage.trim().isEmpty) return (dosage: dosage, isExact: true);

    final variants = MedicineDictionaryService.variantsFor(medicineName);
    if (variants.isEmpty) return (dosage: dosage, isExact: true);

    final result = _variantsAtDosage(variants, dosage);
    if (result.matches.isEmpty || result.isExact) {
      return (dosage: dosage, isExact: true);
    }

    // Every tied candidate in an inexact nearest-match group shares the
    // same dosage_form string by construction (that's what "nearest"
    // means here) — the first one's label represents the correction.
    final label = result.matches.first.dosageForm?.trim();
    if (label == null || label.isEmpty) {
      return (dosage: dosage, isExact: true);
    }
    return (dosage: label, isExact: false);
  }

  static bool hasVariantAtDosage(String medicineName, String dosage) {
    if (dosage.trim().isEmpty) return true;
    final variants = MedicineDictionaryService.variantsFor(medicineName);
    if (variants.isEmpty) return false;
    return _variantsAtDosage(variants, dosage).matches.isNotEmpty;
  }

  /// Returns the variants of [medicineName] that match [dosage], using
  /// the SAME exact/nearest-strength matching rules [lookup] itself
  /// uses (see [_variantsAtDosage]) — this is the single call site the
  /// UI should use to scope a picker's results to a dosage, instead of
  /// pulling the full unfiltered list straight off
  /// [MedicineDictionaryService.variantsFor] (which was the bug: a name
  /// match at the right dosage would still hand back every strength/SKU
  /// of that medicine, e.g. every size of Ceelin, instead of just the
  /// one the prescription actually asked for).
  ///
  /// Falls back to the full variant list when [dosage] is blank or
  /// nothing matches, so a picker built on this never ends up with
  /// zero options.
  static List<MedicineVariant> variantsAtDosage(
    String medicineName,
    String dosage,
  ) {
    final variants = MedicineDictionaryService.variantsFor(medicineName);
    if (dosage.trim().isEmpty) return variants;
    final matched = _variantsAtDosage(variants, dosage).matches;
    return matched.isEmpty ? variants : matched;
  }

  static double priceFor(
    String medicineName, {
    String dosage = '',
    String brand = '',
  }) {
    return lookup(medicineName, dosage: dosage, brand: brand).unitPrice;
  }

  static bool isKnown(
    String medicineName, {
    String dosage = '',
    String brand = '',
  }) {
    return lookup(medicineName, dosage: dosage, brand: brand).variant != null;
  }

  static PriceLookupResult lookup(
    String medicineName, {
    String dosage = '',
    String brand = '',
  }) {
    final variants = MedicineDictionaryService.variantsFor(medicineName);
    if (variants.isEmpty) return PriceLookupResult.notFound;

    // Step 1: narrow down to the set of variants at the resolved dosage
    // (exact string match preferred, else the numerically nearest
    // same-unit strength — see class doc). `dosageIsExact` describes
    // THIS step, independent of whether a brand still needs picking.
    final sameDosage = _variantsAtDosage(variants, dosage);
    final candidates = sameDosage.matches;
    final dosageIsExact = sameDosage.isExact;

    if (candidates.isEmpty) {
      if (sameDosage.dosageComparisonAttempted) {
        // This medicine name IS in the catalog, and the prescription
        // gave a real, comparable numeric strength — but nothing this
        // pharmacy stocks is close enough to count as the same SKU
        // (see _kMaxNearestRelativeDiff). Report this explicitly as a
        // stock gap rather than falling through to a brand guess or
        // an unexplained ₱0.00 — the pharmacist needs to know this
        // ISN'T available at this dosage, not just that pricing
        // failed. [candidates] carries every SKU this pharmacy DOES
        // stock for the name, so the UI can show what's actually on
        // the shelf.
        return PriceLookupResult(
          unitPrice: 0.0,
          isExactMatch: false,
          variant: null,
          dosageNotStocked: true,
          candidates: variants,
        );
      }

      // No usable dosage to compare at all (blank/OCR-missed, or a
      // ratio/suspension form that isn't a plain strength) — this
      // isn't a stock check, just missing data, so fall back to the
      // existing name-only resolution below.
      final target = _plainStrength(dosage);
      if (target != null &&
          !variants.any((v) {
            if (v.dosageForm == null) return false;
            final c = _plainStrength(v.dosageForm!);
            return c != null && c.unit == target.unit;
          })) {
        return PriceLookupResult(
          unitPrice: 0.0,
          isExactMatch: false,
          variant: null,
          dosageNotStocked: true,
          candidates: variants,
        );
      }
      // No dosage-comparable SKU at all — only safe fallback left is a
      // name with exactly one SKU total (nothing else it could be).
      if (variants.length == 1) {
        return PriceLookupResult(
          unitPrice: variants.first.unitPrice ?? 0.0,
          isExactMatch: true,
          variant: variants.first,
          candidates: variants,
        );
      }

      // Multiple SKUs for this name, but not one of them has a
      // dosage_form to compare against at all (a client-data gap, not
      // an OCR problem — e.g. Biogesic's Tab/Drops/250-60 variants all
      // came from the source catalog with no dosage_form recorded).
      // Try the named brand directly first, same as the dosage-matched
      // path below — if the prescription said "Biogesic" and exactly
      // one variant's brand_name contains that, there's nothing
      // ambiguous left to ask the pharmacist about.
      if (brand.trim().isNotEmpty) {
        final brandHits = variants
            .where(
              (v) => v.brandName != null && _brandsMatch(v.brandName!, brand),
            )
            .toList();
        if (brandHits.length == 1) {
          return PriceLookupResult(
            unitPrice: brandHits.first.unitPrice ?? 0.0,
            isExactMatch: false,
            variant: brandHits.first,
            candidates: variants,
          );
        }
      }

      // Still ambiguous (no brand named, or the brand text matches more
      // than one variant, e.g. "Biogesic" alone matching Tab/Drops/
      // 250-60 equally) — surface it for the pharmacist to pick the
      // real SKU rather than silently guessing one or showing an
      // unexplained P0.00.
      return PriceLookupResult(
        unitPrice: 0.0,
        isExactMatch: false,
        variant: null,
        needsBrandSelection: true,
        candidates: variants,
      );
    }

    if (candidates.length == 1) {
      final only = candidates.first;
      return PriceLookupResult(
        unitPrice: only.unitPrice ?? 0.0,
        isExactMatch: dosageIsExact,
        variant: only,
        candidates: candidates,
      );
    }

    // Step 2: multiple SKUs share this dosage — they differ by brand.
    // If the prescription named a brand, match it directly.
    //
    // Collect ALL containment hits first, not just the first one found
    // — the "single dosage-comparable-list" branch above already does
    // this (see `brandHits`/`brandHits.length == 1`), and this branch
    // was inconsistent with it: taking the first `.contains()` hit
    // means "Biogesic" (OCR brand text) silently resolves to whichever
    // of "Biogesic" / "Biogesic Forte" happens to come first in
    // `candidates`, with FULL confidence and no needsBrandSelection
    // flag — the pharmacist never even sees a picker, let alone a
    // warning, for a brand that was actually ambiguous. Requiring
    // exactly one hit (and falling through to needsBrandSelection
    // otherwise, same as every other ambiguous case below) makes this
    // branch behave the same as its sibling instead of silently
    // guessing.
    if (brand.trim().isNotEmpty) {
      final brandHits = candidates
          .where(
            (v) => v.brandName != null && _brandsMatch(v.brandName!, brand),
          )
          .toList();
      if (brandHits.length == 1) {
        return PriceLookupResult(
          unitPrice: brandHits.first.unitPrice ?? 0.0,
          isExactMatch: dosageIsExact,
          variant: brandHits.first,
          candidates: candidates,
        );
      }
    }

    // No brand named, or the named brand isn't one of this pharmacy's
    // SKUs — don't guess which box on the shelf; let the pharmacist
    // pick from the real options.
    return PriceLookupResult(
      unitPrice: 0.0,
      isExactMatch: dosageIsExact,
      variant: null,
      needsBrandSelection: true,
      candidates: candidates,
    );
  }

  /// Returns the variants that share [dosage]'s strength — an exact
  /// normalized-string match if any exist, otherwise every variant
  /// tied at the nearest same-unit strength, but ONLY when that
  /// nearest strength is within [PriceLookupService._kMaxNearestRelativeDiff]
  /// of the target (e.g. two SKUs both at "500 MG" when the OCR read
  /// "580mg" — a plausible digit misread, not a different strength).
  /// Ratio/suspension dosage forms are only compared via exact string
  /// match, never nearest.
  ///
  /// [dosageComparisonAttempted] tells the caller whether this was a
  /// real stock check against a comparable numeric strength (even if
  /// it came back empty) versus "there was nothing sensible to check"
  /// (blank dosage, or a ratio/suspension form) — [PriceLookupService
  /// .lookup] uses this to tell "not stocked at this dosage" apart
  /// from "no dosage data to go on".
  static ({
    List<MedicineVariant> matches,
    bool isExact,
    bool dosageComparisonAttempted,
  })
  _variantsAtDosage(List<MedicineVariant> variants, String dosage) {
    final normDosage = _normalize(dosage);
    if (normDosage.isEmpty) {
      return (
        matches: const [],
        isExact: true,
        dosageComparisonAttempted: false,
      );
    }

    // Exact normalized-string match first — e.g. OCR's "500mg" against
    // the catalog's "500 MG." both normalize to "500mg". Now that
    // _plainStrength tolerates a trailing period (see below), this and
    // the numeric fallback agree on identical dosages, but this path
    // still matters: it also catches ratio/suspension forms like
    // "125/60ML." that _plainStrength intentionally never parses (see
    // its own doc comment) — those still deserve an exact match when
    // the string is identical, not just a "no dosage to compare"
    // shrug from the numeric path below.
    final exact = variants
        .where(
          (v) =>
              v.dosageForm != null && _normalize(v.dosageForm!) == normDosage,
        )
        .toList();
    if (exact.isNotEmpty) {
      return (matches: exact, isExact: true, dosageComparisonAttempted: true);
    }

    final target = _plainStrength(dosage);
    if (target == null) {
      // Ratio/suspension form or unparseable text — nothing sensible
      // to compare against a numeric strength, so this was never
      // actually a stock check.
      return (
        matches: const [],
        isExact: true,
        dosageComparisonAttempted: false,
      );
    }

    double? nearestDiff;
    var sawSameUnitCandidate = false;
    for (final v in variants) {
      if (v.dosageForm == null) continue;
      final candidate = _plainStrength(v.dosageForm!);
      if (candidate == null || candidate.unit != target.unit) continue;
      sawSameUnitCandidate = true;
      final diff = (candidate.value - target.value).abs();
      if (nearestDiff == null || diff < nearestDiff) nearestDiff = diff;
    }

    // There WAS at least one same-unit strength on file to compare
    // against — this counts as a real stock check regardless of how
    // it turns out below.
    final dosageComparisonAttempted = sawSameUnitCandidate;

    if (nearestDiff == null) {
      return (
        matches: const [],
        isExact: true,
        dosageComparisonAttempted: dosageComparisonAttempted,
      );
    }

    if (target.value <= 0 ||
        nearestDiff / target.value > _kMaxNearestRelativeDiff) {
      // Closest thing on the shelf is still too far from what was
      // asked for to treat as the same SKU — a genuine stock gap, not
      // an OCR misread. Let the caller report it as such instead of
      // silently substituting a different strength.
      return (
        matches: const [],
        isExact: true,
        dosageComparisonAttempted: true,
      );
    }

    final nearestGroup = <MedicineVariant>[];
    for (final v in variants) {
      if (v.dosageForm == null) continue;
      final candidate = _plainStrength(v.dosageForm!);
      if (candidate == null || candidate.unit != target.unit) continue;
      if ((candidate.value - target.value).abs() == nearestDiff) {
        nearestGroup.add(v);
      }
    }
    return (
      matches: nearestGroup,
      isExact: false,
      dosageComparisonAttempted: true,
    );
  }

  static String _normalize(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// True if [candidateBrand] (a catalog SKU's brand, e.g. "Himox 500/60")
  /// and [targetBrand] (what the prescription/OCR actually said, e.g.
  /// "Himiox") refer to the same brand.
  ///
  /// A plain substring check alone is too strict for OCR/handwritten
  /// brand names: a single misread or extra letter ("Himiox" vs.
  /// "Himox") breaks .contains() in both directions even though a
  /// pharmacist reading both would immediately recognize them as the
  /// same brand. So this first tries the exact substring check (either
  /// direction, so "Himox" also matches a catalog entry like "Himox
  /// 250/60"), and only falls back to an edit-distance comparison when
  /// that fails.
  ///
  /// The fallback is deliberately narrow: at most ONE insert/delete/
  /// substitute, OR a single pair of adjacent letters swapped (see
  /// [_isSingleAdjacentTransposition]) — a transposition costs two
  /// edits under plain Levenshtein, but it's common enough on short
  /// OCR'd brand names ("Himox" -> "Hmiox") to deserve its own
  /// allowance. That's enough for a single OCR/handwriting slip
  /// ("Himiox" -> "Himox" is exactly one inserted letter) without
  /// opening the door to matching two brand names that just happen to
  /// be similarly spelled but are genuinely different drugs -- any
  /// real one-letter collision like that is rare enough, and the
  /// consequence (still routed through needsBrandSelection if it ties
  /// with another candidate, never a silent multi-way guess) is safer
  /// than leaving every OCR typo unresolved at ₱0.00.
  static bool _brandsMatch(String candidateBrand, String targetBrand) {
    final normCandidate = _normalize(candidateBrand);
    final normTarget = _normalize(targetBrand);
    if (normCandidate.isEmpty || normTarget.isEmpty) return false;
    if (normCandidate.contains(normTarget) ||
        normTarget.contains(normCandidate)) {
      return true;
    }

    final lenDiff = (normCandidate.length - normTarget.length).abs();
    if (lenDiff > 1) return false;

    if (_levenshteinDistance(normCandidate, normTarget) <= 1) return true;

    // A single pair of adjacent letters swapped ("himox" -> "hmiox")
    // isn't reachable in one insert/delete/substitute — standard
    // Levenshtein counts a transposition as two edits — but it's
    // exactly the OCR/handwriting slip a short brand name is prone to,
    // and a pharmacist reading both would recognize them as the same
    // brand immediately. Only equal-length strings differing by
    // exactly one adjacent swap qualify; anything else (a swap plus an
    // insert/delete, or two separate swaps) still falls through to
    // needsBrandSelection rather than being guessed.
    return normCandidate.length == normTarget.length &&
        _isSingleAdjacentTransposition(normCandidate, normTarget);
  }

  /// True if [a] and [b] are the same length and identical except for
  /// exactly one pair of adjacent characters swapped — e.g.
  /// "himox"/"hmiox" (positions 1 and 2 swapped). Used only by
  /// [_brandsMatch]'s near-miss fallback.
  static bool _isSingleAdjacentTransposition(String a, String b) {
    if (a.length != b.length) return false;
    final diffPositions = <int>[];
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        diffPositions.add(i);
        if (diffPositions.length > 2) return false;
      }
    }
    if (diffPositions.length != 2) return false;
    final i = diffPositions[0];
    final j = diffPositions[1];
    return j == i + 1 && a[i] == b[j] && a[j] == b[i];
  }

  /// Standard edit distance (insert/delete/substitute) between two
  /// already-normalized strings -- used only by [_brandsMatch]'s
  /// near-miss fallback, not for any other comparison in this file.
  static int _levenshteinDistance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    var prevRow = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 0; i < a.length; i++) {
      final currRow = List<int>.filled(b.length + 1, 0);
      currRow[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final cost = a[i] == b[j] ? 0 : 1;
        final deletion = prevRow[j + 1] + 1;
        final insertion = currRow[j] + 1;
        final substitution = prevRow[j] + cost;
        currRow[j + 1] = [
          deletion,
          insertion,
          substitution,
        ].reduce((a, b) => a < b ? a : b);
      }
      prevRow = currRow;
    }
    return prevRow[b.length];
  }

  /// Parses a plain "<number><unit>" strength like "500mg", "500 MG.",
  /// "0.5g" into its numeric value + unit. Returns null for anything
  /// that isn't a single plain strength (ratio forms like "125/60ML",
  /// blank strings, non-numeric text, etc.) so those never enter the
  /// nearest-match comparison.
  static ({double value, String unit})? _plainStrength(String raw) {
    final s = raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9.]'), '');
    // This pharmacy's own catalog convention writes dosage forms with a
    // trailing period ("500 MG.", "250 MG.") — the unit-letter group
    // alone won't reach the end-of-string anchor when that's there, so
    // every plain strength in the real catalog was silently failing to
    // parse (returning null) and getting skipped from dosage matching
    // entirely, regardless of how well the name/brand matched.
    final m = RegExp(r'^(\d+(?:\.\d+)?)(mg|mcg|g|ml)\.?$').firstMatch(s);
    if (m == null) return null;
    final value = double.tryParse(m.group(1)!);
    if (value == null) return null;
    return (value: value, unit: m.group(2)!);
  }
}
