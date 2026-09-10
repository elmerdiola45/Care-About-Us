// ocr_review_screen.dart - main review screen for OCR prescription scans
//
// OCR Prescription Scan → Review (end-to-end)
// - Uses this app's OCR.space + Tesseract.js pipeline (see
//   PrescriptionOcrService) for structured patient/doctor/medicine
//   fields, and a regex fallback parser for the fields that pipeline
//   doesn't extract yet (diagnosis, license/PTR/S2 numbers, address).
// - Shows scanned OCR text preview with "OCR Complete" badge
// - Provides editable fields: Doctor, Date, Patient, Diagnosis, etc.
// - Shows MDRP Compliant auto-generated price list table
// - Saves only when the pharmacist explicitly taps "Save & Continue"
//   after reviewing/correcting fields. Shows a success banner and a
//   "View Saved List" button afterward.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common/widgets/tap_target.dart';
import '../../common/widgets/responsive_center.dart';
import '../models/prescription_scan_result.dart';
import '../models/prescription.dart';
import '../services/correction_memory_service.dart';
import '../services/price_lookup_service.dart';
import '../services/prescription_api_service.dart'
    show PrescriptionSaveResult, PossibleDuplicateException;
import '../services/prescription_parser_service.dart'
    show PrescriptionParserService;
import '../services/medicine_dictionary_service.dart'
    show MedicineVariant, MedicineDictionaryService;
import '../data/saved_prescriptions_store.dart';
import 'prescription_detail_screen.dart';

/// Picks the brand text to show/save for a matched medicine row.
///
/// [PriceLookupService.lookup] only sets `variant` when it resolved one
/// specific SKU — which requires an exact (or near-strength) dosage
/// match. The moment the requested dosage isn't stocked at all (see
/// [PriceLookupResult.dosageNotStocked]), `variant` stays null even
/// though `candidates` is still populated with every SKU this pharmacy
/// DOES carry for that generic name (used to build the "Available: …"
/// message) — and those candidates carry the catalog's correctly
/// spelled brand names. Trusting the raw OCR-read brand text in that
/// case is exactly how a handwriting misread like "Hmiox" survives to
/// the screen even though the pharmacy's own records say "Himox".
///
/// So: prefer the resolved variant's brand when there is one; otherwise
/// fuzzy-match the raw OCR brand text against the candidate SKUs' own
/// brand names (same matching PrescriptionParserService already uses
/// for drug names) and use the closest one if it's a confident match;
/// otherwise fall back to the raw OCR text as-is (better than nothing
/// for a brand this pharmacy has never seen).
String _resolvedBrandLabel(String ocrBrand, PriceLookupResult priced) {
  final catalogBrand = priced.variant?.brandName?.trim() ?? '';
  if (catalogBrand.isNotEmpty) return catalogBrand;

  final trimmedOcrBrand = ocrBrand.trim();
  if (trimmedOcrBrand.isEmpty) return '';

  final candidateBrands = priced.candidates
      .map((v) => v.brandName?.trim() ?? '')
      .where((b) => b.isNotEmpty)
      .toSet()
      .toList();
  if (candidateBrands.isEmpty) return trimmedOcrBrand;

  final match = PrescriptionParserService.fuzzyMatchDrugName(
    trimmedOcrBrand,
    candidateBrands,
  );
  // Threshold matches the confidence bar PrescriptionParserService uses
  // elsewhere for a "close enough to trust" correction — brand names
  // are short, so a couple of misread letters ("Hmiox" vs "Himox") is
  // expected to clear it comfortably while an unrelated brand won't.
  if (match.name != null && match.score >= 0.55) {
    return match.name!;
  }
  return trimmedOcrBrand;
}

/// Combines the Sig-line-derived frequency ("3x daily") and duration
/// ("7 days") into the single label the save/display path actually
/// has room for (MedicineItem.duration — see model). Either half can
/// be empty (no Sig line found, or only one of the two parsed out of
/// it) without breaking the other.
String _combineSig(String frequency, String duration) {
  if (frequency.isNotEmpty && duration.isNotEmpty) {
    return '$frequency for $duration';
  }
  return frequency.isNotEmpty ? frequency : duration;
}

/// Pulls a numeric days-supply out of [MedicineItem.duration] — which by
/// the time this runs is the COMBINED sig label from [_combineSig], e.g.
/// "3x daily for 7 days" (frequency + duration together, since that's the
/// only field the save/display path currently has room for). This is why
/// a naive "first number in the string" match is wrong here: on that
/// example it would grab the "3" out of "3x" and return a frequency, not
/// a days count. Look for the "for N day(s)" shape specifically first;
/// only fall back to a bare leading number for a duration-only string
/// (frequency empty, so _combineSig returned just "7 days" with nothing
/// in front of it).
///
/// The backend requires `days_supply` >= 1 on every medicine (used for
/// adherence tracking — see AdherenceStatus), so this is also the single
/// place responsible for making sure a save is never blocked purely
/// because the parsed/typed duration didn't contain a recognizable day
/// count: unparseable text (e.g. "PRN", "as needed", or an empty field)
/// falls back to 1 rather than 0, since 0 would fail that backend check
/// the exact same way an entirely missing value does. This is a
/// deliberate floor, not a real day count — if you're relying on this
/// value for anything dosage-sensitive, prefer having the pharmacist
/// fill in a real number over trusting this fallback.
int _daysSupplyFromDuration(String duration) {
  final forMatch = RegExp(
    r'for\s+(\d+)\s*days?',
    caseSensitive: false,
  ).firstMatch(duration);
  if (forMatch != null) {
    return int.tryParse(forMatch.group(1)!) ?? 1;
  }

  final leadingMatch = RegExp(
    r'^\s*(\d+)\s*days?\b',
    caseSensitive: false,
  ).firstMatch(duration);
  if (leadingMatch != null) {
    return int.tryParse(leadingMatch.group(1)!) ?? 1;
  }

  return 1;
}

class OcrReviewColors {
  static const teal = Color(0xFF0B7B77);
  static const bg = Color(0xFFF3F4F6);
  static const card = Colors.white;
  static const scanNote = Color(0xFFFFF7E6);
  static const green = Color(0xFF2E9C6B);
  static const greenBg = Color(0xFFDCF3E8);
  static const textPrimary = Color(0xFF1F2937);
  static const textSecondary = Color(0xFF6B7280);
  static const border = Color(0xFFE5E7EB);
}

class OcrReviewScreen extends StatefulWidget {
  final Uint8List imageBytes;
  final PrescriptionScanResult? scanResult;
  final String? rawText;

  /// Which pharmacy this scan belongs to — used to scope correction
  /// logging (see CorrectionMemoryService) so one pharmacy's doctors'
  /// handwriting quirks don't pollute another pharmacy's corrections.
  final String pharmacyId;

  /// Called once the prescription + price list has been reviewed and is
  /// ready to persist. Wire this to your actual save/backend-sync logic
  /// (e.g. your Laravel API service) — this screen no longer assumes a
  /// specific storage layer, since that's outside the scope of the scan
  /// + pricing UI itself. Returns whether the backend reopened an existing
  /// prescription instead of creating a new one (see PrescriptionSaveResult),
  /// and accepts confirmNew to force-create after a possible-duplicate
  /// warning was explicitly dismissed by the pharmacist.
  final Future<PrescriptionSaveResult> Function(
    Prescription prescription,
    String ocrCode, {
    bool confirmNew,
  })?
  onSave;

  /// Called when the user taps "Save to Database" after the initial save
  /// already completed — wire this to navigate to wherever your saved
  /// prescriptions list lives.
  final VoidCallback? onViewSavedList;

  const OcrReviewScreen({
    super.key,
    required this.imageBytes,
    required this.pharmacyId,
    this.scanResult,
    this.rawText,
    this.onSave,
    this.onViewSavedList,
  });

  @override
  State<OcrReviewScreen> createState() => _OcrReviewScreenState();
}

class _OcrReviewScreenState extends State<OcrReviewScreen> {
  late final TextEditingController _doctorController;
  late final TextEditingController _dateController;
  late final TextEditingController _patientController;
  late final TextEditingController _diagnosisController;
  late final TextEditingController _licenseController;
  late final TextEditingController _ptController;
  late final TextEditingController _s2Controller;
  late final TextEditingController _addressController;
  late final TextEditingController _oscaIdController;
  late final TextEditingController _ageController;

  /// Patient sex, normalized to 'M'/'F'. Null means "not yet
  /// confirmed" — deliberately never pre-set to a default, so the
  /// pharmacist has to actually pick one instead of an unread document
  /// silently becoming "M" (see _performSave's validation).
  String? _gender;

  late List<_MatchedMedicine> _matchedMeds;
  final List<String> _validationWarnings = [];

  /// Medicine rows collapse to a one-line summary; the pharmacist taps
  /// Edit to expand the full inline editor. Tracked by
  /// _MatchedMedicine.id (not list index) so the expanded/edited row
  /// follows the medicine across add, delete and reorder.
  final Set<int> _expandedMedIds = {};

  String? _ocrCode;
  bool _isSaved = false;
  bool _isSaving = false;
  bool _isSenior = false;

  /// Guards _navigateToExisting() so a double-tap on "View Existing"
  /// (or a reopened-duplicate flow racing the user) can't fire two
  /// concurrent fresh fetches / two navigations.
  bool _isOpeningExisting = false;

  /// Bumped whenever a fresh load supersedes any in-flight async
  /// enrichment pass (catalog refresh, re-scan) — see
  /// _runEnrichmentPipeline / _onRefreshCatalog.
  int _generation = 0;

  /// Tracks the running total so the price row can update
  /// without triggering a full-screen rebuild on every quantity edit.
  late final ValueNotifier<double> _totalPriceNotifier;

  /// Lines that were already claimed by a known field (patient, doctor,
  /// age, gender, license, ptr, s2, address, diagnosis) during _parseOcr.
  /// _buildMatchedMeds uses this to make sure it never re-reads the same
  /// line as a medicine (this is what was causing age/name lines like
  /// "Juan Dela Cruz 45 M" to be picked up as a fake medicine).
  final Set<int> _lastConsumedLines = {};

  @override
  void initState() {
    super.initState();
    _lastConsumedLines.clear();

    // Our OCR.space+Tesseract pipeline (PrescriptionScanResult) gives us
    // structured patientName/doctorName/medicines, but — unlike the
    // richer field set a full-document LLM extraction would produce —
    // it doesn't extract date/diagnosis/license/PTR/S2/address. Always
    // run the regex parser on the raw text to fill those in, and only
    // let it fall back for patient/doctor/medicines if the pipeline
    // itself came up empty on those.
    final effectiveText = widget.rawText ?? widget.scanResult?.rawText ?? '';
    final parsed = _parseOcr(effectiveText);

    _doctorController = TextEditingController(
      text: _pick(widget.scanResult?.doctorName, parsed.doctor),
    );
    _dateController = TextEditingController(text: parsed.date);
    _patientController = TextEditingController(
      text: _pick(widget.scanResult?.patientName, parsed.patient),
    );
    _diagnosisController = TextEditingController(text: parsed.diagnosis);
    _licenseController = TextEditingController(text: parsed.licenseNo);
    _ptController = TextEditingController(text: parsed.ptNo);
    _s2Controller = TextEditingController(text: parsed.s2);
    _addressController = TextEditingController(text: parsed.address);
    _oscaIdController = TextEditingController(text: '');
    final pickedAge = widget.scanResult?.patientAge ?? parsed.age;
    _ageController = TextEditingController(
      text: pickedAge == null ? '' : '$pickedAge',
    );
    _gender = widget.scanResult?.patientGender ?? parsed.gender;

    _validationWarnings.clear();
    final structuredPatientEmpty = (widget.scanResult?.patientName ?? '')
        .trim()
        .isEmpty;
    final structuredDoctorEmpty = (widget.scanResult?.doctorName ?? '')
        .trim()
        .isEmpty;

    // "Auto-filled from image" means the structured pipeline came up
    // empty but the regex fallback found something — the value shown
    // came from the looser fallback parser, not the primary pipeline,
    // so it's worth a second look. If BOTH came up empty, nothing was
    // filled at all — that gets its own "needs manual entry" warning
    // instead, so the pharmacist isn't told something was filled when
    // the field is actually blank.
    if (structuredPatientEmpty) {
      _validationWarnings.add(
        parsed.patient.trim().isEmpty
            ? 'Patient name could not be read — please enter it manually.'
            : 'Patient name auto-filled from prescription image.',
      );
    }
    if (structuredDoctorEmpty) {
      _validationWarnings.add(
        parsed.doctor.trim().isEmpty
            ? 'Doctor name could not be read — please enter it manually.'
            : 'Doctor name auto-filled from prescription image.',
      );
    }
    if (pickedAge == null) {
      _validationWarnings.add(
        'Patient age could not be read — please enter it manually.',
      );
    }
    if (_gender == null) {
      _validationWarnings.add(
        'Patient sex could not be read — please select it manually.',
      );
    }

    if (widget.scanResult != null && widget.scanResult!.medicines.isNotEmpty) {
      _matchedMeds = widget.scanResult!.medicines.map((m) {
        // Real price from this pharmacy's own catalog, keyed by
        // the matched name + extracted dosage — see
        // PriceLookupService. Falls back to the nearest same-unit
        // strength (e.g. OCR misread "500mg" as "580mg") when
        // there's no exact dosage match; unitPriceIsExact tells
        // the row whether to flag that as a guess needing
        // verification. If several SKUs share that dosage and
        // differ only by brand, and the prescription named one
        // (m.brand), that brand is used directly; otherwise the
        // row is left for the pharmacist to pick via
        // needsBrandSelection/brandCandidates. Still 0.0 /
        // exact=true ("needs manual entry") if this name came
        // from the PNF-EML offline fallback rather than the real
        // backend catalog, or if nothing comparable exists at all.
        final priced = PriceLookupService.lookup(
          m.name,
          dosage: m.dosage,
          brand: m.brand,
        );
        return _MatchedMedicine(
          // Canonical generic from the matched DB row wins over the raw
          // OCR text (which may be a misread) — see
          // PriceLookupResult.canonicalName / the brand+dosage path.
          medicineLabel: priced.canonicalName ?? m.name,
          dosageLabel: m.dosage,
          quantity: int.tryParse(m.quantity) ?? 1,
          unitPrice: priced.unitPrice,
          unitPriceIsExact: priced.isExactMatch,
          catalogProductId: priced.productId,
          // See _resolvedBrandLabel — prefers the catalog's own
          // spelling (from a resolved SKU, or fuzzy-matched against
          // whatever SKUs this pharmacy does stock for the name) over
          // the raw OCR-read brand text, which may just be a misread
          // (e.g. "Hmiox" for "Himox").
          brandLabel: _resolvedBrandLabel(m.brand, priced),
          needsBrandSelection: priced.needsBrandSelection,
          medicineNotFound: priced.medicineNotFound,
          dosageNotStocked: priced.dosageNotStocked,
          brandCandidates: priced.candidates,
          catalogName: priced.variant?.name,
          // Our pipeline doesn't carry a separate essential
          // flag yet — default to essential until that's added
          // upstream. Duration comes from the Sig: line
          // attached to this drug during parsing (frequency +
          // days combined into one label, since that's the
          // only field the save/display path currently has).
          isEssential: true,
          duration: _combineSig(m.frequency, m.duration),
          matchConfidence: m.matchConfidence,
        );
      }).toList();
    } else {
      _matchedMeds = _buildMatchedMeds(effectiveText, _lastConsumedLines);
      if (_matchedMeds.isEmpty) {
        _validationWarnings.add(
          'No medicines detected from prescription image. Add manually.',
        );
      }
    }

    final pendingBrandCount = _matchedMeds
        .where((m) => m.needsBrandSelection)
        .length;
    if (pendingBrandCount > 0) {
      _validationWarnings.add(
        pendingBrandCount == 1
            ? '1 medicine has multiple brand options at that dosage — select a brand to price it.'
            : '$pendingBrandCount medicines have multiple brand options at that dosage — select a brand to price them.',
      );
    }

    final notFoundCount = _matchedMeds.where((m) => m.medicineNotFound).length;
    if (notFoundCount > 0) {
      _validationWarnings.add(
        notFoundCount == 1
            ? '1 medicine could not be matched to the pharmacy catalog (by name or brand).'
            : '$notFoundCount medicines could not be matched to the pharmacy catalog (by name or brand).',
      );
    }

    final dosageGapCount = _matchedMeds.where((m) => m.dosageNotStocked).length;
    if (dosageGapCount > 0) {
      _validationWarnings.add(
        dosageGapCount == 1
            ? '1 medicine: the prescribed strength isn\'t listed in the pharmacy catalog.'
            : '$dosageGapCount medicines: the prescribed strength isn\'t listed in the pharmacy catalog.',
      );
    }

    _totalPriceNotifier = ValueNotifier<double>(_computeTotalPrice());

    _runEnrichmentPipeline();
  }

  Future<void> _runEnrichmentPipeline() async {
    final myGeneration = _generation;
    await _upgradeFallbackMatchesWithFuzzyCorrection(myGeneration);
    if (myGeneration != _generation) return; // superseded, stop
    await _resolveNotFoundMedicines(myGeneration);
  }

  /// The fallback matcher ([_buildMatchedMeds]) runs synchronously in
  /// initState, before there's any chance to await the pharmacy's drug
  /// dictionary — so its rows start out with the raw, uncorrected OCR
  /// name handed straight to PriceLookupService, which only does exact
  /// matching and silently misses anything misspelled. This pass runs
  /// after the fact: fetch the same dictionary + correction-memory the
  /// main pipeline uses (already fetched once during this scan's OCR
  /// pass, so this is normally a cache hit, not a fresh network call —
  /// see MedicineDictionaryService/CorrectionMemoryService), fuzzy-match
  /// each fallback row's original OCR text against it the same way
  /// PrescriptionParserService does, and re-price anything that
  /// resolves. Rows stay flagged as isFallbackMatch regardless of
  /// whether a correction is found, since the line itself (dosage/qty
  /// extraction) still came from the looser fallback regex, not the
  /// main pipeline's stricter parsing.
  Future<void> _upgradeFallbackMatchesWithFuzzyCorrection(
    int myGeneration,
  ) async {
    final hasFallbackRows = _matchedMeds.any((m) => m.isFallbackMatch);
    if (!hasFallbackRows) return;

    final results = await Future.wait([
      MedicineDictionaryService.getDictionary(pharmacyId: widget.pharmacyId),
      CorrectionMemoryService.getCorrections(pharmacyId: widget.pharmacyId),
    ]);
    final dictionary = results[0] as List<String>;
    final corrections = results[1] as Map<String, String>;
    if (!mounted || myGeneration != _generation) return;

    final changed = _applyFuzzyCorrectionToFallbackRows(
      dictionary,
      corrections,
    );
    if (changed && mounted && myGeneration == _generation) {
      setState(() => _totalPriceNotifier.value = _computeTotalPrice());
    }
  }

  /// When the pharmacy's local medicine catalog is empty or a scanned
  /// medicine isn't in it, search the backend products database
  /// directly for that medicine name and update the row with the real
  /// dosage, brand, generic name and price found there.
  Future<void> _resolveNotFoundMedicines(int myGeneration) async {
    final notFound = _matchedMeds.where((m) => m.medicineNotFound).toList();
    if (notFound.isEmpty) return;

    var changed = false;
    for (var i = 0; i < _matchedMeds.length; i++) {
      if (!mounted || myGeneration != _generation) return;
      final med = _matchedMeds[i];
      if (!med.medicineNotFound) continue;

      List<MedicineVariant> results;
      try {
        results = await MedicineDictionaryService.searchProducts(
          med.medicineLabel,
        );
      } catch (_) {
        continue; // lookup failure on one row shouldn't abort the rest
      }
      if (results.isEmpty) continue;

      final best = results.first;
      // MedicineVariant doesn't carry its own generic name — look it up
      // via the dictionary's separate generic-name map, keyed by the
      // variant's own catalog name.
      final generic = best.name == null
          ? null
          : MedicineDictionaryService.genericNameFor(best.name!);
      final resolvedName = (generic?.trim().isNotEmpty ?? false)
          ? generic!
          : (best.name ?? med.medicineLabel);

      _matchedMeds[i] = _MedicineResolution.resolve(
        current: med,
        name: resolvedName,
        dosage: med.dosageLabel.isNotEmpty ? med.dosageLabel : best.dosageForm,
        brand: med.brandLabel.isNotEmpty ? med.brandLabel : best.brandName,
      );
      changed = true;
    }

    if (changed && mounted && myGeneration == _generation) {
      setState(() => _totalPriceNotifier.value = _computeTotalPrice());
    }
  }

  /// Fuzzy-corrects every current [isFallbackMatch] row against
  /// [dictionary]/[corrections] and re-prices anything that resolves.
  /// Mutates [_matchedMeds] in place; returns whether anything changed.
  /// Shared by [_upgradeFallbackMatchesWithFuzzyCorrection] (runs once,
  /// automatically, right after the screen loads) and [_onRefreshCatalog]
  /// (runs on demand, against a freshly re-fetched dictionary) so both
  /// paths apply the exact same correction logic instead of drifting.
  bool _applyFuzzyCorrectionToFallbackRows(
    List<String> dictionary,
    Map<String, String> corrections,
  ) {
    if (dictionary.isEmpty && corrections.isEmpty) return false;

    var changed = false;
    for (var i = 0; i < _matchedMeds.length; i++) {
      final med = _matchedMeds[i];
      if (!med.isFallbackMatch) continue;

      final candidate = med.originalOcrLabel;
      final key = candidate.trim().toLowerCase();

      // Same priority as the main pipeline: an institutional correction
      // (a pharmacist already fixed this exact OCR misread before for
      // this pharmacy) beats a fresh fuzzy-match guess.
      String? corrected = corrections[key];
      var confidence = corrected != null ? 1.0 : 0.0;

      if (corrected == null &&
          PrescriptionParserService.hasEnoughLettersToBeAName(candidate)) {
        final match = PrescriptionParserService.fuzzyMatchDrugName(
          candidate,
          dictionary,
        );
        corrected = match.name;
        confidence = match.score;
      }

      // No confident correction — leave the row exactly as it was
      // rather than guess.
      if (corrected == null || corrected.trim().toLowerCase() == key) {
        continue;
      }

      _matchedMeds[i] = _MedicineResolution.resolve(
        current: med,
        name: corrected,
      ).copyWith(matchConfidence: confidence, isFallbackMatch: true);
      changed = true;
    }
    return changed;
  }

  bool _isRefreshingCatalog = false;

  /// Manual escape hatch for the "no way to force a refresh from the UI"
  /// gap — until now, the only way to pick up a catalog/price/correction
  /// change made in the backend mid-session was closing the tab (the
  /// dictionary/corrections caches are in-memory with a 30-minute TTL
  /// and no invalidation trigger). This clears both caches, re-fetches
  /// from the backend, re-prices every row currently on screen against
  /// the fresh data, and gives another fuzzy-correction pass to any
  /// still-unresolved fallback-matched rows — all without requiring a
  /// re-scan.
  Future<void> _onRefreshCatalog() async {
    if (_isRefreshingCatalog) return;
    setState(() => _isRefreshingCatalog = true);
    _generation++;
    final myGeneration = _generation;

    try {
      MedicineDictionaryService.invalidateCache();
      CorrectionMemoryService.invalidateCache();

      final results = await Future.wait([
        MedicineDictionaryService.getDictionary(
          pharmacyId: widget.pharmacyId,
          forceRefresh: true,
        ),
        CorrectionMemoryService.getCorrections(
          pharmacyId: widget.pharmacyId,
          forceRefresh: true,
        ),
      ]);
      final dictionary = results[0] as List<String>;
      final corrections = results[1] as Map<String, String>;
      if (!mounted || myGeneration != _generation) return;

      // Give unresolved fallback rows another shot against the fresh
      // dictionary first ...
      _applyFuzzyCorrectionToFallbackRows(dictionary, corrections);

      // ... then re-price every row (including ones already matched by
      // the main pipeline) against the fresh catalog — a price edited
      // or a new SKU added in the backend should show up immediately,
      // not just on the next scan.
      for (var i = 0; i < _matchedMeds.length; i++) {
        final med = _matchedMeds[i];
        _matchedMeds[i] = _MedicineResolution.resolve(
          current: med,
          name: med.medicineLabel,
        );
      }
      _totalPriceNotifier.value = _computeTotalPrice();

      if (!mounted || myGeneration != _generation) return;
      setState(() => _isRefreshingCatalog = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Catalog refreshed — ${dictionary.length} medicines, '
            '${corrections.length} saved corrections loaded.',
          ),
          backgroundColor: OcrReviewColors.green,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (_) {
      // Same reasoning as the save-failure handler above: show a fixed
      // message, never the raw exception.
      if (!mounted || myGeneration != _generation) return;
      setState(() => _isRefreshingCatalog = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not refresh catalog. Please try again.'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  /// Prefer the value already extracted by the OCR.space+Tesseract
  /// pipeline; fall back to the regex-parsed value only if that's null
  /// OR blank.
  String _pick(String? primary, String fallback) {
    final p = primary?.trim() ?? '';
    if (p.isNotEmpty) return p;
    return fallback;
  }

  @override
  void dispose() {
    _doctorController.dispose();
    _dateController.dispose();
    _patientController.dispose();
    _diagnosisController.dispose();
    _licenseController.dispose();
    _ptController.dispose();
    _s2Controller.dispose();
    _addressController.dispose();
    _oscaIdController.dispose();
    _ageController.dispose();
    _totalPriceNotifier.dispose();
    super.dispose();
  }

  void _onReCapture() => Navigator.of(context).pop();

  void _onViewSavedList() {
    widget.onViewSavedList?.call();
  }

  double _computeTotalPrice() =>
      _matchedMeds.fold<double>(0.0, (sum, m) => sum + m.totalLine);

  /// True when at least one matched medicine has no stock at all
  /// (medicineNotFound) or no stock at the prescribed dosage
  /// (dosageNotStocked). Drives the dedicated "Medicine Not Available"
  /// card — kept separate from needsBrandSelection (ambiguous-but-in-
  /// stock) since that case doesn't represent an actual stock gap.
  bool get _hasUnavailableMedicine =>
      _matchedMeds.any((m) => m.medicineNotFound || m.dosageNotStocked);

  void _onBackToDashboard() {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// Cleans the patient-name text field only. Age and sex are no longer
  /// guessed from this string — they come from the dedicated, validated
  /// _ageController / _gender fields (see _performSave) — but a
  /// pharmacist may still type a combined "Josh, 7, M" into the name box
  /// out of habit, so any trailing age/sex token is stripped here purely
  /// for display, without ever being treated as the source of truth for
  /// age or gender.
  String _cleanPatientName(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return 'Unknown Patient';
    final cleaned = text
        .replaceAll(
          RegExp(r'\b\d{1,3}\s*[\/\-]?\s*[MF]\b', caseSensitive: false),
          '',
        )
        .trim()
        .replaceAll(RegExp(r'[,\s]+$'), '')
        .trim();
    return cleaned.isEmpty ? text : cleaned;
  }

  String _generateOcrCode() {
    final now = DateTime.now();
    final rand = (now.microsecondsSinceEpoch % 100000).toString().padLeft(
      5,
      '0',
    );
    return 'RX-${now.year}-$rand';
  }

  Future<void> _performSave({bool confirmNew = false}) async {
    if (_isSaved || _isSaving) return;

    final doctorName = _doctorController.text.trim();
    final patientName = _patientController.text.trim();
    if (doctorName.isEmpty || patientName.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Doctor and patient name are required before saving.',
            ),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    // Age/sex must be an explicit, validated value from the pharmacist
    // (or a bounds-checked OCR read) before saving — never a silent
    // fallback. This is what stops a document the pipeline couldn't
    // read from turning into a confidently wrong "0 years old · M" on
    // every screen downstream.
    final ageText = _ageController.text.trim();
    final patientAge = int.tryParse(ageText);
    if (ageText.isEmpty ||
        patientAge == null ||
        patientAge < 0 ||
        patientAge > 120) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enter a valid patient age (0–120) before saving.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    if (_gender != 'M' && _gender != 'F') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Select the patient\'s sex before saving.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    // needsBrandSelection means the medicine IS in stock but several SKUs
    // are tied at that dosage — that's a genuine pricing ambiguity only
    // the dispenser can resolve, so it still blocks save (a silent
    // ₱0.00 for something that's actually on the shelf would be wrong).
    //
    // medicineNotFound / dosageNotStocked are deliberately NOT blocking:
    // that medicine truly isn't available at this pharmacy, so ₱0.00 is
    // the correct price for it (nothing is being charged or dispensed
    // for it here). The rest of the prescription — including any
    // available medicines on the same scan — still needs to be saved so
    // the dispenser can dispense what's on hand now, while the
    // unavailable line stays on the record (see
    // _buildMedicineNotAvailableCard) for the patient to get filled
    // elsewhere or once restocked.
    // A manually-added row left without a name can't be saved as a real
    // medicine line — prompt to fill it in or remove it.
    if (_matchedMeds.any((m) => m.medicineLabel.trim().isEmpty)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'One added medicine has no name — enter it or remove the row '
              'before saving.',
            ),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    final unresolvedCount = _matchedMeds
        .where((m) => m.needsBrandSelection)
        .length;
    if (unresolvedCount > 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              unresolvedCount == 1
                  ? 'Resolve pricing for 1 medicine before saving (see warning above).'
                  : 'Resolve pricing for $unresolvedCount medicines before saving (see warnings above).',
            ),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    // A Senior Citizen prescription must carry an OSCA ID — it's the
    // identifier the discount/eligibility record keys off downstream.
    if (_isSenior && _oscaIdController.text.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Enter an OSCA ID for Senior Citizen patients before saving.',
            ),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    setState(() => _isSaving = true);

    final cleanedPatientName = _cleanPatientName(patientName);
    final diagnosis = _diagnosisController.text.trim();
    final licenseNo = _licenseController.text.trim();
    final ptNo = _ptController.text.trim();
    final s2 = _s2Controller.text.trim();
    final patientAddress = _addressController.text.trim();
    final isSenior = _isSenior;
    final oscaId = _oscaIdController.text.trim().isEmpty
        ? null
        : _oscaIdController.text.trim();

    final medicines = _matchedMeds
        .map(
          (m) => MedicineItem(
            name: m.medicineLabel,
            genericName: m.medicineLabel,
            brand: m.brandLabel,
            productId: m.catalogProductId,
            dosage: m.dosageLabel,
            quantity: m.quantity,
            unitPrice: m.unitPrice,
            isEssential: m.isEssential,
            duration: m.duration,
            daysSupply: _daysSupplyFromDuration(m.duration),
          ),
        )
        .toList();

    // Log any names the pharmacist manually corrected — builds up this
    // pharmacy's correction memory so the same OCR misread (same
    // doctors, same handwriting quirks, repeated) gets auto-fixed next
    // time instead of requiring a fresh manual correction again. This
    // is intentionally NOT awaited: logging a correction should never
    // delay saving the actual prescription.
    for (final m in _matchedMeds) {
      if (m.wasManuallyCorrected) {
        CorrectionMemoryService.logCorrection(
          pharmacyId: widget.pharmacyId,
          ocrText: m.originalOcrLabel,
          correctedTo: m.medicineLabel,
        );
      }
    }

    final totalPrice = _matchedMeds.fold<double>(
      0.0,
      (sum, m) => sum + m.totalLine,
    );
    final ocrCode = _generateOcrCode();
    // The prescription record's dateTime is the scan/save timestamp, not
    // the "Date" field above (an editable, OCR-guessed field that only
    // ever carries a date with no time-of-day, and isn't anchored to a
    // "Date:" label on the document — see _parseOcr). Saved Rx cards and
    // the detail screen show this value converted to Philippine time
    // (see common/utils/ph_time.dart), so it needs to be an accurate
    // instant, not a guess.
    final dateTime = DateTime.now();

    final prescription = Prescription(
      patientName: cleanedPatientName,
      patientAge: patientAge,
      patientGender: _gender!,
      isSenior: isSenior,
      oscaId: oscaId,
      doctorName: doctorName,
      licenseNo: licenseNo,
      ptNo: ptNo,
      s2: s2,
      patientAddress: patientAddress.isEmpty ? null : patientAddress,
      diagnosis: diagnosis.isEmpty ? null : diagnosis,
      ocrCode: ocrCode,
      dateTime: dateTime,
      medicines: medicines,
      totalPrice: totalPrice,
      status: QrStatus.pendingQr,
      imageBytes: widget.imageBytes,
    );

    PrescriptionSaveResult? result;
    try {
      result = await widget.onSave?.call(
        prescription,
        ocrCode,
        confirmNew: confirmNew,
      );
    } on PossibleDuplicateException catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        _showPossibleDuplicateDialog(e);
      }
      return;
    } on TimeoutException catch (_) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Cannot reach backend server. Check if the backend is running and accessible.',
            ),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    } catch (_) {
      // Deliberately not interpolating the exception into the SnackBar
      // — a backend error message can carry details (URLs, internal
      // error text) that don't belong in front-of-pharmacist UI. The
      // prescription data itself is still intact in the form; the
      // pharmacist can just retry.
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to save prescription. Please try again.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    if (!mounted) return;

    // Backend matched an existing prescription exactly — the edits just
    // made on this screen are discarded, and we navigate straight to the
    // existing record (with its dispensing history) instead of showing a
    // "saved" success state for what would otherwise be a duplicate. This
    // is deliberately an explicit dialog the dispenser must dismiss, not a
    // fleeting SnackBar — a scan that appears to do nothing (because
    // nothing NEW was created) needs to clearly explain why, or it looks
    // like the scan simply failed to register.
    if (result != null && result.reopened) {
      setState(() => _isSaving = false);
      await _showReopenedDialog(result.prescriptionId);
      return;
    }

    setState(() {
      _isSaving = false;
      _ocrCode = ocrCode;
      _isSaved = true;
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Saved to database'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ),
    );

    // Soft stock warnings never block a save — surface them as a
    // non-blocking follow-up notice after the success banner above.
    if (result != null && result.stockWarnings.isNotEmpty) {
      final warnings = result.stockWarnings.join(' ');
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(warnings),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 4),
          ),
        );
      });
    }
    // Deliberately NOT calling _onViewSavedList() here. Per this
    // screen's contract, a successful save should show the saved
    // banner and flip the bottom button to "View Saved List" — the
    // pharmacist taps that explicitly (see _onSaveAndViewList) to
    // navigate away. Auto-navigating immediately here would skip the
    // confirmation banner and make that second button unreachable.
  }

  /// Shown when the backend finds a highly-similar (but not exact) existing
  /// prescription for this patient — lets the pharmacist either open that
  /// one or explicitly confirm this is a genuinely new prescription.
  void _showPossibleDuplicateDialog(PossibleDuplicateException e) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Possible duplicate prescription'),
        content: Text(e.message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _navigateToExisting(e.existingPrescriptionId);
            },
            child: const Text('View Existing'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _performSave(confirmNew: true);
            },
            child: const Text('Save as New'),
          ),
        ],
      ),
    );
  }

  /// Explains why nothing new was saved: an exact match for this scan
  /// already exists, so the backend reopened it instead of creating a
  /// duplicate. Must be explicitly dismissed (not a timed SnackBar) since
  /// this is the moment a scan can otherwise look like it silently failed.
  Future<void> _showReopenedDialog(String prescriptionId) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Already saved — nothing new created'),
        content: Text(
          'This exact prescription (same patient, doctor, date, and '
          'medicines) was already saved earlier'
          '${prescriptionId.isNotEmpty ? ' as $prescriptionId' : ''}. '
          'None of the changes made on this screen were saved as a new '
          'entry. Opening the existing record and its history now.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    await _navigateToExisting(prescriptionId);
  }

  /// Refreshes the local prescriptions store from the backend and
  /// navigates to the matching entry's detail screen (which already shows
  /// dispensing/refill history), reusing existing store plumbing rather
  /// than adding a separate fetch-by-id path.
  ///
  /// If the entry can't be located even after refreshing (e.g. the store
  /// refresh itself failed), this shows an explicit warning rather than
  /// silently doing nothing — a dispenser who tapped "View Existing" or
  /// just had a scan reopened needs to know the record is safe (saved
  /// under [prescriptionId]) even though this screen couldn't open it.
  Future<void> _navigateToExisting(String prescriptionId) async {
    if (prescriptionId.isEmpty) return;
    if (_isOpeningExisting) return;
    setState(() => _isOpeningExisting = true);
    bool refreshFailed = false;
    try {
      // A fresh, un-cached prescription fetch — the just-saved/duplicate
      // record must actually be present, so a stale cached result isn't
      // acceptable here even within the TTL window. This deliberately uses
      // the navigation-only fetch (not fetchFromBackend): it skips the
      // store-wide adherence fan-out that PrescriptionDetailScreen doesn't
      // use, and stays isolated from the normal fetch's _inFlightFetch /
      // _lastFetchedAt so it can't alter dashboard/Saved Rx refresh timing.
      await SavedPrescriptionsStore.instance.fetchPrescriptionsForNavigation();
    } catch (_) {
      refreshFailed = true;
    }
    if (!mounted) return;
    setState(() => _isOpeningExisting = false);
    final matches = SavedPrescriptionsStore.instance.items.where(
      (entry) => entry.backendId == prescriptionId,
    );
    if (matches.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            refreshFailed
                ? 'Prescription $prescriptionId is saved, but the list '
                      'couldn\'t refresh to open it (check your connection). '
                      'Find it in the Saved Prescriptions list.'
                : 'Prescription $prescriptionId is saved, but couldn\'t be '
                      'opened automatically. Find it in the Saved '
                      'Prescriptions list.',
          ),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PrescriptionDetailScreen(entry: matches.first),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OcrReviewColors.bg,
      appBar: AppBar(
        backgroundColor: OcrReviewColors.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: OcrReviewColors.textPrimary),
        title: const Text(
          'OCR Prescription Scan → Review',
          style: TextStyle(
            color: OcrReviewColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh catalog, prices & corrections from backend',
            icon: _isRefreshingCatalog
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _isRefreshingCatalog ? null : _onRefreshCatalog,
          ),
        ],
      ),
      body: Stack(
        children: [
          ResponsiveCenter.dashboard(
            padding: EdgeInsets.zero,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _buildScannedNotePreview(),
                if (_hasUnavailableMedicine) ...[
                  const SizedBox(height: 12),
                  _buildMedicineNotAvailableCard(),
                ],
                if (_validationWarnings.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildValidationWarnings(),
                ],
                if (_isSaved && _ocrCode != null) ...[
                  const SizedBox(height: 16),
                  _buildSavedBanner(),
                ],
                _buildEditableFieldsSection(),
                const SizedBox(height: 16),
                _buildMedicineListSection(),
                const SizedBox(height: 18),
                _buildBottomButtons(),
              ],
            ),
          ),
          if (_isOpeningExisting)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x66000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSavedBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: OcrReviewColors.greenBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: OcrReviewColors.green.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.check_circle_rounded,
            color: OcrReviewColors.green,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Prescription saved as $_ocrCode',
                  style: const TextStyle(
                    color: OcrReviewColors.green,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Generate a QR code from the Saved Rx list.',
                  style: TextStyle(
                    color: OcrReviewColors.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildValidationWarnings() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7E6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFFD97706).withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(
                Icons.warning_amber_rounded,
                color: Color(0xFFD97706),
                size: 20,
              ),
              SizedBox(width: 8),
              Text(
                'Validation Notice',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                  color: Color(0xFFD97706),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ..._validationWarnings.map(
            (w) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '• $w',
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF92400E),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Dedicated, high-visibility card for the "prescribed medicine/dosage
  /// isn't in stock" state — distinct from the generic amber validation
  /// notice below it, since a stock gap isn't just a field the pharmacist
  /// forgot to fill in: it means this prescription cannot be dispensed
  /// as written and must not be saved or silently substituted. Lists the
  /// affected medicines by name/dosage and gives an explicit way out
  /// (Back to Dashboard) so the dispenser isn't left hunting for an exit
  /// while the row-level pickers below still require their own explicit
  /// confirmation before anything changes.
  Widget _buildMedicineNotAvailableCard() {
    final affected = _matchedMeds
        .where((m) => m.medicineNotFound || m.dosageNotStocked)
        .map(
          (m) => m.dosageLabel.isNotEmpty
              ? '${m.medicineLabel} (${m.dosageLabel})'
              : m.medicineLabel,
        )
        .toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFEE2E2),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFFDC2626).withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.report_rounded, color: Color(0xFFDC2626), size: 20),
              SizedBox(width: 8),
              Text(
                'Not Matched to Catalog',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                  color: Color(0xFFDC2626),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'The medicine or strength below could not be matched to this '
            'pharmacy\'s catalog (this is not a live stock check):',
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF991B1B)),
          ),
          const SizedBox(height: 6),
          ...affected.map(
            (label) => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '• $label',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF991B1B),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Nothing will be substituted automatically. You can still save '
            'and dispense the other medicine(s) on this prescription now — '
            'the unmatched one listed above will stay on the record at '
            '₱0.00 so it\'s clear it wasn\'t priced/dispensed here, and can '
            'be filled elsewhere. If it is actually stocked here under a '
            'different name, pick it from the catalog below — that requires '
            'your explicit confirmation.',
            style: TextStyle(fontSize: 12, color: Color(0xFF991B1B)),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _onBackToDashboard,
              icon: const Icon(Icons.arrow_back, color: Color(0xFFDC2626)),
              label: const Text('Back to Dashboard'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFDC2626),
                side: const BorderSide(color: Color(0xFFDC2626)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 13.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScannedNotePreview() {
    // Use the merged values (structured pipeline result + regex-parsed
    // admin fields) that already populated the editable controllers,
    // rather than reading straight off scanResult — our OCR.space/
    // Tesseract pipeline doesn't extract date/diagnosis/license/PTR/S2/
    // address itself, so those only exist post-merge.
    final displayText =
        'Doctor: ${_doctorController.text.isEmpty ? 'N/A' : _doctorController.text}\n'
        'Patient: ${_patientController.text.isEmpty ? 'N/A' : _patientController.text}\n'
        'Date: ${_dateController.text.isEmpty ? 'N/A' : _dateController.text}\n'
        'Diagnosis: ${_diagnosisController.text.isEmpty ? 'N/A' : _diagnosisController.text}\n'
        'License: ${_licenseController.text.isEmpty ? 'N/A' : _licenseController.text}\n'
        'PTR: ${_ptController.text.isEmpty ? 'N/A' : _ptController.text}\n'
        'S2: ${_s2Controller.text.isEmpty ? 'N/A' : _s2Controller.text}\n'
        'Address: ${_addressController.text.isEmpty ? 'N/A' : _addressController.text}\n'
        'Medicines: ${_matchedMeds.map((m) => m.medicineLabel).join(', ')}';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: OcrReviewColors.scanNote,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: OcrReviewColors.border),
      ),
      child: Stack(
        children: [
          Positioned(
            top: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1B8F3A).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF1B8F3A)),
              ),
              child: const Text(
                'OCR Complete',
                style: TextStyle(
                  color: Color(0xFF1B8F3A),
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Scanned Note',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 14.5,
                    color: OcrReviewColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  displayText.trim(),
                  style: TextStyle(
                    fontSize: 13.5,
                    color: OcrReviewColors.textPrimary.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditableFieldsSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: OcrReviewColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: OcrReviewColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'OCR EXTRACTED — EDITABLE',
            style: TextStyle(
              color: OcrReviewColors.textSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 14),
          Column(
            children: [
              _fieldBox(label: 'Doctor', controller: _doctorController),
              const SizedBox(height: 10),
              _fieldBox(label: 'Date', controller: _dateController),
              const SizedBox(height: 10),
              _fieldBox(label: 'Patient', controller: _patientController),
              const SizedBox(height: 10),
              // Age's compact TextField is intrinsically shorter than Sex,
              // whose chips sit inside a TapTarget(minSize: 44). IntrinsicHeight
              // + stretch lets Sex set the row height and Age match it exactly,
              // rather than guessing a padding/height value.
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _fieldBox(
                        label: 'Age',
                        controller: _ageController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(3),
                        ],
                        // Age is stretched to Sex's height — centre its
                        // label/value in the extra space instead of top-pinning.
                        mainAxisAlignment: MainAxisAlignment.center,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: _genderField()),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _fieldBox(label: 'Diagnosis', controller: _diagnosisController),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _fieldBox(
                      label: 'License No.',
                      controller: _licenseController,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _fieldBox(
                      label: 'PT No.',
                      controller: _ptController,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _fieldBox(label: 'S2', controller: _s2Controller),
              const SizedBox(height: 10),
              _fieldBox(label: 'Address', controller: _addressController),
              const SizedBox(height: 10),
              Row(
                children: [
                  Checkbox(
                    value: _isSenior,
                    onChanged: (val) =>
                        setState(() => _isSenior = val ?? false),
                    activeColor: OcrReviewColors.teal,
                  ),
                  const Text(
                    'Senior Citizen',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14.5,
                    ),
                  ),
                  if (_isSenior) ...[
                    const Spacer(),
                    Expanded(
                      child: TextField(
                        controller: _oscaIdController,
                        style: const TextStyle(
                          fontSize: 14.5,
                          color: OcrReviewColors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                        decoration: const InputDecoration(
                          hintText: 'OSCA ID No.',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _fieldBox({
    required String label,
    required TextEditingController controller,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    // Vertical alignment of the label/field within the box. Defaults to
    // top-aligned so every existing caller is unchanged; only the Age field
    // (stretched to match Sex's height) passes center.
    MainAxisAlignment mainAxisAlignment = MainAxisAlignment.start,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: OcrReviewColors.border),
        color: OcrReviewColors.bg,
      ),
      child: Column(
        mainAxisAlignment: mainAxisAlignment,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 12.5,
              color: OcrReviewColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            keyboardType: keyboardType,
            inputFormatters: inputFormatters,
            style: const TextStyle(
              fontSize: 14.5,
              color: OcrReviewColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }

  /// Sex selector — deliberately a forced pick between exactly 'M' and
  /// 'F' rather than a free-text field or a pre-selected default, so an
  /// unread document can't silently end up saved as "M". _performSave
  /// blocks the save while this is null.
  Widget _genderField() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: OcrReviewColors.border),
        color: OcrReviewColors.bg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Sex',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 12.5,
              color: OcrReviewColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _genderChip('M'),
              const SizedBox(width: 8),
              _genderChip('F'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _genderChip(String value) {
    final selected = _gender == value;
    return Expanded(
      child: TapTarget(
        onTap: () => setState(() => _gender = value),
        semanticLabel: value == 'M' ? 'Male' : 'Female',
        borderRadius: BorderRadius.circular(8),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? OcrReviewColors.teal.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? OcrReviewColors.teal : OcrReviewColors.border,
            ),
          ),
          child: Text(
            value,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
              color: selected
                  ? OcrReviewColors.teal
                  : OcrReviewColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMedicineListSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: OcrReviewColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: OcrReviewColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'AUTO-GENERATED PRICE LIST',
                  style: TextStyle(
                    color: OcrReviewColors.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFDCF3E8),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'MDRP Compliant',
                  style: TextStyle(
                    color: Color(0xFF2E9C6B),
                    fontWeight: FontWeight.w900,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_matchedMeds.isEmpty)
            const Text(
              'No matching medicines recognized yet. Ensure OCR text contains the medicine names.',
              style: TextStyle(
                color: OcrReviewColors.textSecondary,
                fontSize: 12.5,
              ),
            )
          else ...[
            _buildEditableMedicineList(),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _addMedicine,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Medicine'),
              style: TextButton.styleFrom(
                foregroundColor: OcrReviewColors.teal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditableMedicineList() {
    return Column(
      children: [
        for (int i = 0; i < _matchedMeds.length; i++) ...[
          _buildMedicineRow(_matchedMeds[i]),
          if (i != _matchedMeds.length - 1) const Divider(height: 1),
        ],
      ],
    );
  }

  /// One medicine row: a collapsed one-line summary with Edit / Delete,
  /// or — once the pharmacist taps Edit — the existing inline editor
  /// with Done / Delete beneath it. Keyed by the medicine's stable id
  /// so editor state (name/quantity controllers) follows the medicine
  /// across add/delete/reorder rather than the list position.
  Widget _buildMedicineRow(_MatchedMedicine m) {
    final expanded = _expandedMedIds.contains(m.id);

    void applyChange(_MatchedMedicine updated) {
      setState(() {
        final idx = _matchedMeds.indexWhere((e) => e.id == m.id);
        if (idx != -1) _matchedMeds[idx] = updated;
        _totalPriceNotifier.value = _computeTotalPrice();
      });
    }

    if (expanded) {
      return Column(
        key: ValueKey('med_row_${m.id}'),
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _EditableMedicineRow(
            key: ValueKey('med_editor_${m.id}'),
            medicine: m,
            pharmacyId: widget.pharmacyId,
            // Replace the whole row's data (not just quantity) — this is
            // what applies a brand picked from the dropdown, a manually
            // typed name, etc. Mapped back to _matchedMeds by id.
            onChanged: applyChange,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => setState(() => _expandedMedIds.remove(m.id)),
                  child: const Text('Done'),
                ),
                TextButton(
                  onPressed: () => _deleteMedicine(m.id),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFDC2626),
                  ),
                  child: const Text('Delete'),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final needsAttention =
        m.medicineNotFound || m.dosageNotStocked || m.needsBrandSelection;
    final summaryParts = <String>[
      if (m.brandLabel.trim().isNotEmpty) m.brandLabel.trim(),
      if (m.dosageLabel.trim().isNotEmpty) m.dosageLabel.trim(),
      '×${m.quantity}',
      '₱${m.totalLine.toStringAsFixed(2)}',
    ];

    return Padding(
      key: ValueKey('med_row_${m.id}'),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.medicineLabel.trim().isEmpty
                      ? 'New medicine'
                      : m.medicineLabel.trim(),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  summaryParts.join('  ·  '),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                if (needsAttention) ...[
                  const SizedBox(height: 2),
                  Text(
                    m.medicineNotFound
                        ? 'No catalog match — tap Edit'
                        : m.dosageNotStocked
                        ? 'Strength not listed — tap Edit'
                        : 'Select brand — tap Edit',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFD97706),
                    ),
                  ),
                ],
              ],
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _expandedMedIds.add(m.id)),
            child: const Text('Edit'),
          ),
          IconButton(
            onPressed: () => _deleteMedicine(m.id),
            icon: const Icon(Icons.delete_outline, size: 20),
            color: const Color(0xFFDC2626),
            tooltip: 'Delete medicine',
          ),
        ],
      ),
    );
  }

  /// Removes one medicine from the review, after an explicit confirm —
  /// a mis-tap on the trash icon would otherwise silently drop a
  /// prescribed medicine from the record. Local only — no backend call,
  /// no save. _performSave() reads whatever is in _matchedMeds at save
  /// time, so this simply takes effect on the next save.
  Future<void> _deleteMedicine(int id) async {
    final med = _matchedMeds.firstWhere(
      (m) => m.id == id,
      orElse: () => _MatchedMedicine(
        medicineLabel: '',
        dosageLabel: '',
        quantity: 0,
        unitPrice: 0,
      ),
    );
    final label = med.medicineLabel.trim().isEmpty
        ? 'this medicine'
        : '"${med.medicineLabel.trim()}"';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove medicine?'),
        content: Text(
          'Remove $label from this prescription? It will not be saved '
          'or dispensed. You can add it back manually if needed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFDC2626),
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _matchedMeds.removeWhere((m) => m.id == id);
      _expandedMedIds.remove(id);
      _totalPriceNotifier.value = _computeTotalPrice();
    });
  }

  /// Adds a blank medicine the pharmacist fills in by hand — for a drug
  /// OCR missed, or one that simply isn't in the registered catalog.
  /// It is a free-text entry: the pharmacist types the name and price
  /// directly, with no requirement to match a catalog medicine. The
  /// row still offers an optional "pick from catalog" link. Opened
  /// expanded so the pharmacist lands straight in the editor.
  void _addMedicine() {
    final blank = _MatchedMedicine(
      medicineLabel: '',
      dosageLabel: '',
      quantity: 1,
      unitPrice: 0.0,
      unitPriceIsExact: false,
      isManualEntry: true,
      isEssential: true,
    );
    setState(() {
      _matchedMeds.add(blank);
      _expandedMedIds.add(blank.id);
      _totalPriceNotifier.value = _computeTotalPrice();
    });
  }

  Widget _buildBottomButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _onReCapture,
            icon: const Icon(
              Icons.camera_alt_outlined,
              color: OcrReviewColors.teal,
            ),
            label: const Text('Re-capture'),
            style: OutlinedButton.styleFrom(
              foregroundColor: OcrReviewColors.teal,
              side: const BorderSide(color: OcrReviewColors.teal),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              textStyle: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 14.5,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _isSaving
                ? null
                : (_isSaved ? _onSaveAndViewList : _performSave),
            icon: _isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.cloud_upload, color: Colors.white),
            label: Text(
              _isSaving
                  ? 'Saving...'
                  : (_isSaved ? 'View Saved List' : 'Save & Continue'),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: OcrReviewColors.green,
              foregroundColor: Colors.white,
              disabledBackgroundColor: OcrReviewColors.green.withValues(
                alpha: 0.4,
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              textStyle: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 14.5,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _onSaveAndViewList() async {
    if (!_isSaved || _ocrCode == null) return;
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Saved to database'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ),
    );

    _onViewSavedList();
  }

  // ===========================================================================
  // FIXED PARSER. Every line consumed by ANY field here is recorded in
  // _lastConsumedLines (by index) so _buildMatchedMeds can never re-read
  // that same line as a medicine — this fixes age/patient combo lines
  // (e.g. "Juan Cruz 45 M") being picked up as fake medicines. Also
  // detects unlabeled "Dr. Full Name" and "Name Age Gender" lines so
  // doctor/patient are found even without an explicit "Doctor:"/
  // "Patient:" label in the OCR text.
  // ===========================================================================
  _ParsedFields _parseOcr(String text) {
    _lastConsumedLines.clear();

    final normalizedText = text
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n\s*\n'), '\n')
        .trim();

    final lines = normalizedText.split('\n').map((l) => l.trim()).toList();

    final doctorLabelRe = RegExp(
      r'^(dr\.?|doctor|attending\s+physician|prescribing\s+physician|physician)(?![A-Za-z])[:\.\s]*',
      caseSensitive: false,
    );
    final patientLabelRe = RegExp(
      r'^(patient|pangalan|name)(?![A-Za-z])[:\.\s]*',
      caseSensitive: false,
    );
    final diagnosisLabelRe = RegExp(
      r'^(diagnosis|dx|impression|assessment)(?![A-Za-z])[:\.\s]*',
      caseSensitive: false,
    );
    final licenseLabelRe = RegExp(
      r'^(license\s*no\.?|lic\.?\s*no\.?|lic\.?|reg\.?\s*no\.?)(?![A-Za-z])[:\.\s]*',
      caseSensitive: false,
    );
    final ptrLabelRe = RegExp(
      r'^(ptr\s*no\.?|pt\s*no\.?|pt#)(?![A-Za-z])[:\.\s]*',
      caseSensitive: false,
    );
    final s2LabelRe = RegExp(
      r'^(s2|s-2)(?![A-Za-z])[:\.\s]*',
      caseSensitive: false,
    );
    final addressLabelRe = RegExp(
      r'^(address|addr)(?![A-Za-z])[:\.\s]*',
      caseSensitive: false,
    );

    final demographicLabelRe = RegExp(
      r'^(age|gender|sex|wt\.?|weight|ht\.?|height|contact|mobile|phone|tel\.?|signature)(?![A-Za-z])[:\.\s]*',
      caseSensitive: false,
    );

    final patientComboRe = RegExp(
      r'^[A-Za-z][A-Za-z\s\.\-]{2,45}?,?\s*(\d{1,3})\s*,?\s*([MF])\b',
      caseSensitive: false,
    );

    final doctorNameOnlyRe = RegExp(r'^dr\.?\s+[A-Za-z]', caseSensitive: false);

    final topNameRe = RegExp(r'^[A-Z]\.?[a-z]*\s+[A-Z]');

    String doctor = '';
    String patient = '';
    String diagnosis = '';
    String licenseNo = '';
    String ptNo = '';
    String s2 = '';
    String address = '';
    int? age;
    String? gender;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty) continue;

      if (licenseLabelRe.hasMatch(line)) {
        if (licenseNo.isEmpty) {
          licenseNo = line.replaceFirst(licenseLabelRe, '').trim();
        }
        _lastConsumedLines.add(i);
        continue;
      }
      if (ptrLabelRe.hasMatch(line)) {
        if (ptNo.isEmpty) {
          ptNo = line.replaceFirst(ptrLabelRe, '').trim();
        }
        _lastConsumedLines.add(i);
        continue;
      }
      if (s2LabelRe.hasMatch(line)) {
        if (s2.isEmpty) {
          s2 = line.replaceFirst(s2LabelRe, '').trim();
        }
        _lastConsumedLines.add(i);
        continue;
      }
      if (addressLabelRe.hasMatch(line)) {
        if (address.isEmpty) {
          String extracted = line.replaceFirst(addressLabelRe, '').trim();
          extracted = extracted
              .replaceAll(RegExp(r'\bDATE:\s*', caseSensitive: false), '')
              .trim();
          address = extracted;
        }
        _lastConsumedLines.add(i);
        continue;
      }
      if (diagnosisLabelRe.hasMatch(line)) {
        if (diagnosis.isEmpty) {
          diagnosis = line.replaceFirst(diagnosisLabelRe, '').trim();
        }
        _lastConsumedLines.add(i);
        continue;
      }
      if (demographicLabelRe.hasMatch(line)) {
        // Most demographic labels (weight, height, contact, signature)
        // aren't needed here and are simply skipped, as before — but
        // "Age:" / "Sex:" / "Age/Sex:" lines actually carry data the
        // rest of the app needs, so pull a bounds-checked value out of
        // them instead of throwing the line away.
        if (age == null) {
          final ageLabel = RegExp(
            r'^age\s*(?:/\s*sex)?[:\.\s]*',
            caseSensitive: false,
          ).firstMatch(line);
          if (ageLabel != null) {
            final rest = line.substring(ageLabel.end);
            final numMatch = RegExp(r'\d{1,3}').firstMatch(rest);
            if (numMatch != null) {
              final candidate = int.tryParse(numMatch.group(0)!);
              if (candidate != null && candidate >= 0 && candidate <= 120) {
                age = candidate;
              }
            }
            if (gender == null) {
              final gMatch = RegExp(
                r'\b(male|female|[MF])\b',
                caseSensitive: false,
              ).firstMatch(rest);
              if (gMatch != null) {
                gender = gMatch.group(1)!.toUpperCase().startsWith('M')
                    ? 'M'
                    : 'F';
              }
            }
          }
        }
        if (gender == null) {
          final sexLabel = RegExp(
            r'^(sex|gender)[:\.\s]*',
            caseSensitive: false,
          ).firstMatch(line);
          if (sexLabel != null) {
            final rest = line.substring(sexLabel.end);
            final gMatch = RegExp(
              r'\b(male|female|[MF])\b',
              caseSensitive: false,
            ).firstMatch(rest);
            if (gMatch != null) {
              gender = gMatch.group(1)!.toUpperCase().startsWith('M')
                  ? 'M'
                  : 'F';
            }
          }
        }
        _lastConsumedLines.add(i);
        continue;
      }
      if (patientLabelRe.hasMatch(line)) {
        if (patient.isEmpty) {
          String extracted = line.replaceFirst(patientLabelRe, '').trim();
          extracted = extracted
              .replaceAll(RegExp(r'\bAGE:\s*', caseSensitive: false), '')
              .trim();
          // Capture an age/sex pair embedded in the patient-name line
          // itself (e.g. "Patient: Josh, 7, M") before discarding it —
          // this used to be silently thrown away, which is exactly the
          // kind of embedded demographic data an OCR line can carry.
          final embedded = RegExp(
            r'\b(\d{1,3})\s*[\/\-]?\s*([MF])\b',
            caseSensitive: false,
          ).firstMatch(extracted);
          if (embedded != null) {
            final candidate = int.tryParse(embedded.group(1)!);
            if (age == null &&
                candidate != null &&
                candidate >= 0 &&
                candidate <= 120) {
              age = candidate;
            }
            gender ??= embedded.group(2)!.toUpperCase();
          }
          extracted = extracted
              .replaceAll(
                RegExp(r'\b\d{1,3}\s*[\/\-]?\s*[MF]\b', caseSensitive: false),
                '',
              )
              .trim()
              .replaceAll(RegExp(r'[,\s]+$'), '');
          patient = extracted;
        }
        _lastConsumedLines.add(i);
        continue;
      }
      if (patientComboRe.hasMatch(line)) {
        if (patient.isEmpty) {
          final match = patientComboRe.firstMatch(line)!;
          final candidate = int.tryParse(match.group(1) ?? '');
          if (age == null &&
              candidate != null &&
              candidate >= 0 &&
              candidate <= 120) {
            age = candidate;
          }
          gender ??= match.group(2)?.toUpperCase();
          // Keep only the name portion — everything before the matched
          // age/sex — rather than the whole line (which used to leave
          // the raw "7 M" digits sitting inside the patient name).
          final namePart = line
              .substring(0, match.start)
              .trim()
              .replaceAll(RegExp(r'[,\s]+$'), '');
          patient = namePart.isNotEmpty ? namePart : line.trim();
        }
        _lastConsumedLines.add(i);
        continue;
      }
      if (doctorLabelRe.hasMatch(line)) {
        if (doctor.isEmpty) {
          String extracted = line.replaceFirst(doctorLabelRe, '').trim();
          // "Physician's Sig" matches doctorLabelRe on the word
          // "Physician" alone — the apostrophe satisfies the label's
          // negative lookahead but isn't a ":"/"."/whitespace
          // separator, so the trailing [:\.\s]* consumes nothing and
          // "'s Sig" (or, if OCR drops the apostrophe, "s Sig") is left
          // over and would otherwise be taken as the doctor's name.
          // That's the standard Sig-instruction line, not a name —
          // reject it here so `doctor` stays empty and either the
          // fallback candidate search below finds a real name or it
          // honestly falls through to "Unknown Doctor".
          final looksLikeSigRemainder =
              RegExp(r"^'?s\b", caseSensitive: false).hasMatch(extracted) &&
              extracted.toLowerCase().contains('sig');
          if (looksLikeSigRemainder) {
            extracted = '';
          }
          if (extracted.isEmpty && i > 0) {
            final prevLine = lines[i - 1].trim();
            if (prevLine.isNotEmpty && topNameRe.hasMatch(prevLine)) {
              extracted = prevLine;
              _lastConsumedLines.add(i - 1);
            }
          }
          doctor = extracted;
        }
        _lastConsumedLines.add(i);
        continue;
      }
      if (doctorNameOnlyRe.hasMatch(line)) {
        if (doctor.isEmpty) {
          doctor = line.trim();
        }
        _lastConsumedLines.add(i);
        continue;
      }
    }

    if (doctor.isEmpty) {
      final hasDigitsRe = RegExp(r'\d');
      for (var i = 0; i < lines.length && i < 8; i++) {
        final line = lines[i];
        if (line.isEmpty) continue;
        if (_lastConsumedLines.contains(i)) continue;
        if (topNameRe.hasMatch(line) &&
            !patientComboRe.hasMatch(line) &&
            !hasDigitsRe.hasMatch(line)) {
          final candidate = line.trim();
          if (candidate.length > 2 && candidate.length < 60) {
            doctor = candidate;
            _lastConsumedLines.add(i);
            break;
          }
        }
      }
    }

    String date = '';
    final isoDateMatch = RegExp(
      r'(19\d\d|20\d\d)[-/]\d{1,2}[-/]\d{1,2}',
    ).firstMatch(normalizedText);
    if (isoDateMatch != null) {
      date = isoDateMatch.group(0) ?? '';
    } else {
      final shortDateMatch = RegExp(
        r'\b(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})\b',
      ).firstMatch(normalizedText);
      if (shortDateMatch != null) {
        date = shortDateMatch.group(0) ?? '';
      } else {
        final yearMatch = RegExp(
          r'\b(19\d\d|20\d\d)\b',
        ).firstMatch(normalizedText);
        date = yearMatch?.group(0) ?? '';
      }
    }
    date = date.isEmpty
        ? DateTime.now().toIso8601String().split('T').first
        : date;

    diagnosis = diagnosis.isEmpty ? '—' : diagnosis;
    doctor = doctor.isEmpty ? 'Unknown Doctor' : doctor;
    patient = patient.isEmpty ? 'Unknown Patient' : patient;

    return _ParsedFields(
      doctor: doctor,
      date: date,
      patient: patient,
      diagnosis: diagnosis,
      licenseNo: licenseNo,
      ptNo: ptNo,
      s2: s2,
      address: address,
      age: age,
      gender: gender,
    );
  }

  // ===========================================================================
  // FIXED MEDICINE MATCHER — takes the set of line indices already
  // consumed by _parseOcr (patient, doctor, age, gender, license, ptr,
  // s2, address, diagnosis, date-ish lines) and skips them entirely, on
  // top of a label-keyword safety net. This guarantees a line can never
  // be counted as BOTH a field value and a medicine — e.g. an unlabeled
  // "Juan Dela Cruz 45 M" patient line, or "Lic. No. 12345", can never
  // leak into the medicines list.
  // ===========================================================================
  List<_MatchedMedicine> _buildMatchedMeds(
    String ocrText,
    Set<int> consumedLines,
  ) {
    final lines = ocrText.split('\n');
    final matches = <_MatchedMedicine>[];
    final seen = <String>{};

    // Safety net in case this is ever called without a consumed-lines set
    // (e.g. consumedLines is empty): still exclude obvious admin labels.
    final excludeRe = RegExp(
      r'^\s*(license\s*no\.?|lic\.?\s*no\.?|lic\.?|reg\.?\s*no\.?|'
      r'ptr\s*no\.?|pt\s*no\.?|pt#|s2|s-2|'
      r'doctor|dr\.?|patient|pangalan|name|'
      r'age|gender|sex|wt\.?|weight|ht\.?|height|contact|mobile|phone|tel\.?|'
      r'physician|signature|'
      r'diagnosis|dx|impression|assessment|'
      r'address|addr|date)(?![A-Za-z])',
      caseSensitive: false,
    );

    // Brand written in parens, either inline ("Amoxicillin (Himox) 500mg")
    // or on its own line just above the generic name — the common
    // Philippine Rx format. A standalone paren line is never treated as
    // its own medicine, only as the brand for the line after it.
    final brandParenRe = RegExp(r'\(([A-Za-z][A-Za-z0-9\-\s]{1,30})\)');
    bool isStandaloneParenLine(String s) =>
        RegExp(r'^\(([A-Za-z][A-Za-z0-9\-\s]{1,30})\)$').hasMatch(s.trim());

    for (var i = 0; i < lines.length; i++) {
      if (consumedLines.contains(i)) continue;

      // Same Sig:-line handling as the main pipeline (see
      // PrescriptionParserService._extractMedicines) — attach
      // frequency/duration to the most recently matched medicine
      // instead of letting a garbled "Sig:" line get matched as a
      // fake medicine of its own by the regex below.
      if (matches.isNotEmpty && PrescriptionParserService.isSigLine(lines[i])) {
        var lastConsumed = i;
        final segments = <String>[lines[i].trim()];
        for (var j = i + 1; j < lines.length && j <= i + 2; j++) {
          final next = lines[j].trim();
          if (next.isEmpty) break;
          if (excludeRe.hasMatch(next)) break;
          if (isStandaloneParenLine(next)) break;
          segments.add(next);
          lastConsumed = j;
        }
        final sigText = segments.join(' ');
        final freq = PrescriptionParserService.frequencyFrom(sigText);
        final dur = PrescriptionParserService.durationFrom(sigText);
        if (freq.isNotEmpty || dur.isNotEmpty) {
          final prevIndex = matches.length - 1;
          final prev = matches[prevIndex];
          matches[prevIndex] = _MatchedMedicine(
            medicineLabel: prev.medicineLabel,
            dosageLabel: prev.dosageLabel,
            quantity: prev.quantity,
            unitPrice: prev.unitPrice,
            unitPriceIsExact: prev.unitPriceIsExact,
            brandLabel: prev.brandLabel,
            needsBrandSelection: prev.needsBrandSelection,
            medicineNotFound: prev.medicineNotFound,
            dosageNotStocked: prev.dosageNotStocked,
            brandCandidates: prev.brandCandidates,
            isEssential: prev.isEssential,
            duration: _combineSig(freq, dur),
            matchConfidence: prev.matchConfidence,
            originalOcrLabel: prev.originalOcrLabel,
            isFallbackMatch: prev.isFallbackMatch,
          );
        }
        i = lastConsumed;
        continue;
      }

      var trimmed = lines[i].trim();
      if (trimmed.isEmpty || trimmed.length < 3) continue;
      if (isStandaloneParenLine(trimmed)) continue;
      if (excludeRe.hasMatch(trimmed)) continue;
      // Same fuzzy footer/label rejection as the main pipeline — catches
      // OCR misreads of label lines ("PTR No" -> "PIR No") that the
      // exact-string excludeRe above doesn't, so they don't get
      // captured as a ₱0.00 phantom medicine.
      if (!RegExp(r'\d').hasMatch(trimmed) &&
          PrescriptionParserService.isFooterLabelLine(trimmed)) {
        continue;
      }

      String brand = '';
      final inlineBrand = brandParenRe.firstMatch(trimmed);
      if (inlineBrand != null) {
        brand = inlineBrand.group(1)!.trim();
        trimmed = trimmed
            .replaceRange(inlineBrand.start, inlineBrand.end, '')
            .trim()
            .replaceAll(RegExp(r'\s+'), ' ');
      } else if (i > 0 && isStandaloneParenLine(lines[i - 1])) {
        final m = RegExp(
          r'^\(([A-Za-z][A-Za-z0-9\-\s]{1,30})\)$',
        ).firstMatch(lines[i - 1].trim());
        brand = m?.group(1)?.trim() ?? '';
      }

      // Match medicine lines like:
      // "Paracetamol 500mg 10"
      // "Amoxicillin 500mg x 21"
      // "Cetirizine 10mg"
      // "Loratadine tab"
      // "Insulin Glargine # 3"
      final medMatch = RegExp(
        r'^([A-Za-z][A-Za-z0-9\s\.\-]+?)(?:\s+([0-9]+(?:\.[0-9]+)?\s*(?:mg|g|mcg|ml|tab|cap|tabs|caps|mL|MG|G|MCG|ML)?))?(?:\s*[xX×#]\s*|\s+)(\d+)?',
        caseSensitive: false,
      ).firstMatch(trimmed);

      if (medMatch != null) {
        final name = medMatch.group(1)?.trim() ?? '';
        var dosage = medMatch.group(2)?.trim() ?? '';
        final qty = medMatch.group(3)?.trim() ?? '';

        // The drug name/qty line often doesn't carry a strength at all
        // (e.g. "Fesov tab # 30") — the actual dosage sits alone on the
        // NEXT line instead (e.g. "500mg tab"), the same shape as an
        // "Ascorbic Acid # 30 / 500mg tab" block. Without this, dosage
        // stays '' and the brand picker's dosage filter has nothing to
        // filter on, so it silently falls back to showing the full
        // catalog instead of a dosage-scoped list.
        var extraConsumedLine = -1;
        if (dosage.isEmpty && i + 1 < lines.length) {
          final nextLine = lines[i + 1].trim();
          final doseOnlyMatch = RegExp(
            r'^([0-9]+(?:\.[0-9]+)?)\s*(mg|g|mcg|ml)\b',
            caseSensitive: false,
          ).firstMatch(nextLine);
          if (doseOnlyMatch != null &&
              !excludeRe.hasMatch(nextLine) &&
              !consumedLines.contains(i + 1)) {
            dosage = doseOnlyMatch.group(0)!.trim();
            extraConsumedLine = i + 1;
          }
        }

        final key = name.toLowerCase();
        if (name.length > 2 && name.length < 60 && !seen.contains(key)) {
          seen.add(key);
          if (extraConsumedLine != -1) {
            consumedLines.add(extraConsumedLine);
            i = extraConsumedLine; // skip it next loop iteration too
          }
          final priced = PriceLookupService.lookup(
            name,
            dosage: dosage,
            brand: brand,
          );
          matches.add(
            _MatchedMedicine(
              medicineLabel: priced.canonicalName ?? name,
              dosageLabel: dosage,
              quantity: int.tryParse(qty) ?? 1,
              unitPrice: priced.unitPrice,
              unitPriceIsExact: priced.isExactMatch,
              catalogProductId: priced.productId,
              // See _resolvedBrandLabel — same catalog-spelling
              // preference as the main pipeline path above.
              brandLabel: _resolvedBrandLabel(brand, priced),
              needsBrandSelection: priced.needsBrandSelection,
              medicineNotFound: priced.medicineNotFound,
              dosageNotStocked: priced.dosageNotStocked,
              brandCandidates: priced.candidates,
              catalogName: priced.variant?.name,
              isEssential: true,
              duration: '',
              isFallbackMatch: true,
            ),
          );
        }
      }
    }

    return matches;
  }
}

class _EditableMedicineRow extends StatefulWidget {
  final _MatchedMedicine medicine;
  final String pharmacyId;
  final ValueChanged<_MatchedMedicine> onChanged;

  const _EditableMedicineRow({
    super.key,
    required this.medicine,
    required this.pharmacyId,
    required this.onChanged,
  });

  @override
  State<_EditableMedicineRow> createState() => _EditableMedicineRowState();
}

class _EditableMedicineRowState extends State<_EditableMedicineRow> {
  late TextEditingController _nameController;
  late TextEditingController _qtyController;
  // Only used by manually-added (free-text) medicines, whose price the
  // pharmacist sets directly rather than resolving from the catalog.
  late TextEditingController _priceController;
  String? _qtyError;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.medicine.medicineLabel,
    );
    _qtyController = TextEditingController(text: '${widget.medicine.quantity}');
    _priceController = TextEditingController(
      text: widget.medicine.unitPrice > 0
          ? widget.medicine.unitPrice.toStringAsFixed(2)
          : '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _qtyController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  /// Bottom-sheet brand picker, shared by the "already resolved but
  /// might be wrong" tap-to-change path and reusable if the ambiguous
  /// picker above is ever consolidated into this same widget. Kept as
  /// a plain bottom sheet (not a dropdown) since it's opened via tap
  /// from arbitrary scroll position in the medicine list, and a sheet
  /// gives room to show price alongside every candidate even when
  /// there are several.
  void _showBrandPicker(
    BuildContext context,
    List<MedicineVariant> candidates,
    void Function(MedicineVariant) onSelect, {
    bool showPrice = true,
  }) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 12),
          itemCount: candidates.length + 1,
          separatorBuilder: (context, i) => i == 0
              ? const SizedBox.shrink()
              : const Divider(height: 1, indent: 16, endIndent: 16),
          itemBuilder: (context, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  'Choose brand',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Colors.grey.shade900,
                  ),
                ),
              );
            }
            final v = candidates[i - 1];
            return ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              leading: CircleAvatar(
                backgroundColor: OcrReviewColors.teal.withValues(alpha: 0.12),
                foregroundColor: OcrReviewColors.teal,
                child: const Icon(Icons.medication_outlined, size: 18),
              ),
              title: Text(
                v.brandName ?? v.name ?? 'Generic (no brand)',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14.5,
                ),
              ),
              subtitle: v.dosageForm != null && v.dosageForm!.isNotEmpty
                  ? Text(
                      v.dosageForm!,
                      style: TextStyle(color: Colors.grey.shade600),
                    )
                  : null,
              trailing: showPrice
                  ? Text(
                      '₱${(v.unitPrice ?? 0).toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: OcrReviewColors.teal,
                        fontSize: 14,
                      ),
                    )
                  : null,
              onTap: () {
                Navigator.of(sheetContext).pop();
                onSelect(v);
              },
            );
          },
        ),
      ),
    );
  }

  /// Full-catalog search sheet — the fix for medicineNotFound rows,
  /// which previously had NO way to attach a real SKU: the name field
  /// was just plain text (editing it never re-ran matching), and the
  /// "Brand: …" tap target only ever rendered once a brand was already
  /// resolved, so there was nothing on screen to tap at all. This lets
  /// the pharmacist search the pharmacy's actual dictionary directly
  /// and pick the right catalog entry by hand.
  Future<void> _showMedicinePicker(
    BuildContext context,
    void Function(String name, List<MedicineVariant> variants) onSelect, {
    String dosage = '',
  }) async {
    List<String> names;
    try {
      names = await MedicineDictionaryService.getDictionary(
        pharmacyId: widget.pharmacyId,
      );
    } catch (_) {
      names = const [];
    }
    if (!context.mounted) return;
    if (dosage.trim().isNotEmpty) {
      final atDosage = names
          .where((n) => PriceLookupService.hasVariantAtDosage(n, dosage))
          .toList();
      if (atDosage.isNotEmpty) names = atDosage;
    }
    if (names.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not load the pharmacy catalog to search.'),
        ),
      );
      return;
    }
    final query = ValueNotifier<String>('');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (sheetContext, scrollController) => SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: OcrReviewColors.teal.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.medication_outlined,
                            size: 18,
                            color: OcrReviewColors.teal,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Pick correct medicine',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: Colors.grey.shade900,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      autofocus: true,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(
                          Icons.search,
                          size: 20,
                          color: Colors.grey.shade500,
                        ),
                        hintText: 'Search medicine name…',
                        filled: true,
                        fillColor: const Color(0xFFF3F4F6),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                            color: OcrReviewColors.teal,
                            width: 1.5,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                      ),
                      onChanged: (v) => query.value = v.trim().toLowerCase(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ValueListenableBuilder<String>(
                  valueListenable: query,
                  builder: (context, q, _) {
                    final filtered = q.isEmpty
                        ? names
                        : names.where((n) => n.contains(q)).toList();
                    if (filtered.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'No matching medicine in this catalog.',
                            style: TextStyle(color: Colors.grey.shade600),
                          ),
                        ),
                      );
                    }
                    return ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: filtered.length,
                      separatorBuilder: (context, i) =>
                          const Divider(height: 1, indent: 16, endIndent: 16),
                      itemBuilder: (context, i) {
                        final n = filtered[i];
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 2,
                          ),
                          leading: Icon(
                            Icons.medication_outlined,
                            size: 20,
                            color: Colors.grey.shade400,
                          ),
                          title: Text(
                            _titleCase(n),
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            onSelect(
                              n,
                              PriceLookupService.variantsAtDosage(n, dosage),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _titleCase(String s) => s
      .split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  @override
  Widget build(BuildContext context) {
    final nameEdited =
        _nameController.text.trim().toLowerCase() !=
        widget.medicine.medicineLabel.trim().toLowerCase();
    final updated = _MatchedMedicine(
      // Keep this row's stable identity so edits map back to the same
      // _matchedMeds entry regardless of its current list position.
      id: widget.medicine.id,
      medicineLabel: _nameController.text,
      dosageLabel: widget.medicine.dosageLabel,
      // Prescribed quantity starts out as OCR's estimate (frequency ×
      // duration) but is editable via the quantity field below — this
      // sets the actual prescribed amount saved with the prescription.
      // Adjusting how much is dispensed per visit still happens
      // separately on the Dispense screen.
      quantity: widget.medicine.quantity,
      unitPrice: widget.medicine.unitPrice,
      unitPriceIsExact: widget.medicine.unitPriceIsExact,
      brandLabel: widget.medicine.brandLabel,
      needsBrandSelection: widget.medicine.needsBrandSelection,
      medicineNotFound: widget.medicine.medicineNotFound,
      dosageNotStocked: widget.medicine.dosageNotStocked,
      brandCandidates: widget.medicine.brandCandidates,
      // A manual name edit invalidates the previously-resolved catalog
      // string — showing "Amoxicillin (Himox 250/60)" next to text the
      // pharmacist just typed something different into would be
      // actively misleading, not just stale.
      catalogName: nameEdited ? null : widget.medicine.catalogName,
      isEssential: widget.medicine.isEssential,
      duration: widget.medicine.duration,
      matchConfidence: widget.medicine.matchConfidence,
      // Preserve the ORIGINAL ocr label across edits — this must stay
      // pointed at what OCR actually produced, not what's currently
      // typed, or correction-detection would compare a value against
      // itself and never register a correction.
      originalOcrLabel: widget.medicine.originalOcrLabel,
      isFallbackMatch: widget.medicine.isFallbackMatch,
      isManualEntry: widget.medicine.isManualEntry,
    );

    // Pharmacist picked a brand from the picker (or the prescription
    // named one and it's just being confirmed) — resolves the price to
    // that specific SKU and closes out needsBrandSelection.
    void selectBrand(MedicineVariant v) {
      widget.onChanged(
        updated.copyWith(
          unitPrice: v.unitPrice ?? 0.0,
          brandLabel: v.brandName ?? '',
          needsBrandSelection: false,
          medicineNotFound: false,
          dosageNotStocked: false,
          catalogName: v.name,
          catalogProductId: v.id,
        ),
      );
    }

    // Pharmacist searched the catalog and picked the actual medicine
    // (used from the medicineNotFound / dosageNotStocked states, where
    // there's no brandCandidates list to fall back on). A single
    // matching SKU resolves straight to price; several sends it into
    // the same needsBrandSelection dropdown as an auto-match would.
    void pickMedicine(String name, List<MedicineVariant> variants) {
      _nameController.text = name;
      if (variants.length == 1) {
        final v = variants.first;
        widget.onChanged(
          updated.copyWith(
            medicineLabel: name,
            unitPrice: v.unitPrice ?? 0.0,
            brandLabel: v.brandName ?? '',
            needsBrandSelection: false,
            medicineNotFound: false,
            dosageNotStocked: false,
            brandCandidates: variants,
            catalogName: v.name,
            catalogProductId: v.id,
            isFallbackMatch: false,
            // Now linked to a real catalog SKU — no longer a free entry.
            isManualEntry: false,
          ),
        );
      } else {
        widget.onChanged(
          updated.copyWith(
            medicineLabel: name,
            unitPrice: 0.0,
            brandLabel: '',
            needsBrandSelection: variants.isNotEmpty,
            medicineNotFound: variants.isEmpty,
            dosageNotStocked: false,
            brandCandidates: variants,
            catalogName: null,
            catalogProductId: null,
            isFallbackMatch: false,
          ),
        );
      }
    }

    final badge = updated.isEssential
        ? Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: OcrReviewColors.teal.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Essential',
              style: TextStyle(fontSize: 11, color: OcrReviewColors.teal),
            ),
          )
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              'Optional',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          );

    // Brand + dosage, appended right after the editable name so the
    // whole line reads as ONE complete medicine identity — "Amoxicillin
    // (Himox) 500 MG." — instead of the name field followed by a second,
    // separately-rendered line repeating it (previously: this exact
    // string via `catalogName`, or a standalone "Brand: X" line). Built
    // from brandLabel/dosageLabel rather than `catalogName` itself so the
    // generic name typed in the field above is never duplicated —
    // catalogName is exactly "$medicineLabel ($brandLabel) $dosageLabel"
    // when resolved (see MedicineVariant.name), so these two fields alone
    // reconstruct the same brand/dosage suffix without the name prefix.
    // Brand is gated on !needsBrandSelection, matching the prior "Brand:
    // X" line's condition; dosage is shown independently of that, same
    // as before.
    final identityParts = <String>[
      if (updated.brandLabel.trim().isNotEmpty && !updated.needsBrandSelection)
        '(${updated.brandLabel.trim()})',
      if (updated.dosageLabel.trim().isNotEmpty) updated.dosageLabel.trim(),
    ];
    final identitySuffix = identityParts.join(' ');
    // Same tap target/condition the removed catalogName/Brand lines used
    // — reopens the existing brand picker only when there's actually
    // something to switch between.
    final reopenBrandPicker = updated.brandCandidates.length > 1
        ? () => _showBrandPicker(
            context,
            updated.brandCandidates,
            selectBrand,
            showPrice: true,
          )
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Sized to its own text (not stretched full-width) so
                    // the brand/dosage suffix below can sit immediately
                    // after it on the same line, rather than pinned to
                    // the far edge of the row.
                    IntrinsicWidth(
                      child: TextField(
                        controller: _nameController,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          border: InputBorder.none,
                          hintText: updated.isManualEntry
                              ? 'Medicine name (e.g. Paracetamol 500mg)'
                              : null,
                        ),
                        onChanged: (v) {
                          final sanitized = v.trim().length > 60
                              ? v.trim().substring(0, 60)
                              : v;
                          widget.onChanged(
                            updated.copyWith(medicineLabel: sanitized),
                          );
                        },
                      ),
                    ),
                    if (identitySuffix.isNotEmpty)
                      Flexible(
                        child: InkWell(
                          onTap: reopenBrandPicker,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    identitySuffix,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: OcrReviewColors.teal,
                                      decoration:
                                          updated.brandCandidates.length > 1
                                          ? TextDecoration.underline
                                          : null,
                                      decorationColor: OcrReviewColors.teal
                                          .withValues(alpha: 0.5),
                                    ),
                                  ),
                                ),
                                if (updated.brandCandidates.length > 1) ...[
                                  const SizedBox(width: 3),
                                  Icon(
                                    Icons.unfold_more,
                                    size: 16,
                                    color: OcrReviewColors.teal.withValues(
                                      alpha: 0.7,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                if (updated.isManualEntry) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Text(
                        'Unit price  ₱',
                        style: TextStyle(
                          fontSize: 12,
                          color: OcrReviewColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(
                        width: 78,
                        child: TextField(
                          controller: _priceController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.]'),
                            ),
                          ],
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: '0.00',
                            contentPadding: EdgeInsets.symmetric(vertical: 4),
                          ),
                          onChanged: (v) {
                            final parsed = double.tryParse(v.trim());
                            widget.onChanged(
                              updated.copyWith(
                                unitPrice: (parsed != null && parsed >= 0)
                                    ? parsed
                                    : 0.0,
                                unitPriceIsExact: parsed != null && parsed > 0,
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    children: [
                      Text(
                        'Added manually — not from the catalog.',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      InkWell(
                        onTap: () => _showMedicinePicker(
                          context,
                          pickMedicine,
                          dosage: updated.dosageLabel,
                        ),
                        child: const Text(
                          'Pick from catalog instead',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: OcrReviewColors.teal,
                            fontWeight: FontWeight.w700,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (updated.isFallbackMatch) ...[
                  const SizedBox(height: 2),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7E6),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: const Color(0xFFD97706).withValues(alpha: 0.4),
                      ),
                    ),
                    child: const Text(
                      'Low-confidence match — please verify',
                      style: TextStyle(
                        fontSize: 10,
                        color: Color(0xFF92400E),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
                // Several SKUs share this dosage and differ only by
                // brand, and the prescription didn't name one — ask
                // the pharmacist to pick the actual box on the shelf
                // instead of guessing (and instead of a bare ₱0.00).
                if (updated.needsBrandSelection) ...[
                  const SizedBox(height: 4),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _showBrandPicker(
                        context,
                        updated.brandCandidates,
                        selectBrand,
                        showPrice: true,
                      ),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF7E6),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(
                              0xFFD97706,
                            ).withValues(alpha: 0.45),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.medication_liquid_outlined,
                              size: 16,
                              color: Color(0xFF92400E),
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'Select brand…',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: Color(0xFF92400E),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Text(
                              '${updated.brandCandidates.length} option'
                              '${updated.brandCandidates.length == 1 ? '' : 's'}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF92400E),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 18,
                              color: Color(0xFF92400E),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                // Nothing in this pharmacy's catalog matches this
                // medicine name at all — not a different dosage, not a
                // different brand, nothing. Distinct from
                // needsBrandSelection (which means "it IS here, just
                // pick which one") and from dosageNotStocked below (which
                // means "the name is here, just not this strength").
                if (updated.medicineNotFound) ...[
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEE2E2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFFDC2626).withValues(alpha: 0.4),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Couldn\'t match this medicine to the pharmacy '
                          'catalog (by name or brand). Verify the name or '
                          'pick the correct medicine below. This is not a '
                          'stock check.',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF991B1B),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        InkWell(
                          onTap: () => _showMedicinePicker(
                            context,
                            pickMedicine,
                            dosage: updated.dosageLabel,
                          ),
                          child: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 3,
                            children: [
                              Icon(
                                Icons.search,
                                size: 16,
                                color: const Color(0xFF991B1B),
                              ),
                              Text(
                                'Pick from catalog',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: const Color(0xFF991B1B),
                                  fontWeight: FontWeight.w800,
                                  decoration: TextDecoration.underline,
                                  decorationColor: const Color(
                                    0xFF991B1B,
                                  ).withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                // This medicine name IS in the catalog, but nothing on
                // the shelf is close enough to the requested dosage to
                // count as the same SKU — a real stock gap, not just a
                // pricing/matching failure. Lists whatever dosages ARE
                // available (from brandCandidates — see
                // PriceLookupResult.dosageNotStocked) so the pharmacist
                // doesn't have to go check the shelf to find out.
                if (updated.dosageNotStocked) ...[
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEE2E2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFFDC2626).withValues(alpha: 0.4),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          updated.brandCandidates.isEmpty
                              ? 'This strength isn\'t listed in the catalog'
                                    '${updated.dosageLabel.isNotEmpty ? ' (${updated.dosageLabel})' : ''}.'
                              : 'This strength isn\'t listed in the catalog'
                                    '${updated.dosageLabel.isNotEmpty ? ' (${updated.dosageLabel})' : ''}. '
                                    'Listed: '
                                    '${updated.brandCandidates.map((v) => v.dosageForm?.trim()).whereType<String>().where((d) => d.isNotEmpty).toSet().join(', ')}.',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF991B1B),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        InkWell(
                          onTap: () => _showMedicinePicker(
                            context,
                            pickMedicine,
                            dosage: updated.dosageLabel,
                          ),
                          child: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 3,
                            children: [
                              Icon(
                                Icons.search,
                                size: 16,
                                color: const Color(0xFF991B1B),
                              ),
                              Text(
                                'Pick from catalog',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: const Color(0xFF991B1B),
                                  fontWeight: FontWeight.w800,
                                  decoration: TextDecoration.underline,
                                  decorationColor: const Color(
                                    0xFF991B1B,
                                  ).withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (updated.duration.isNotEmpty)
                  Text(
                    'Duration: ${updated.duration}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                const SizedBox(height: 4),
                badge,
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 64,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4F6F6),
                    borderRadius: BorderRadius.circular(8),
                    border: _qtyError != null
                        ? Border.all(color: const Color(0xFFDC2626))
                        : null,
                  ),
                  child: TextField(
                    controller: _qtyController,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: OcrReviewColors.textPrimary,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                      border: InputBorder.none,
                    ),
                    onChanged: (v) {
                      final parsed = int.tryParse(v);
                      setState(() {
                        _qtyError = (parsed == null || parsed < 1)
                            ? 'Min 1'
                            : null;
                      });
                      if (parsed != null && parsed >= 1) {
                        widget.onChanged(updated.copyWith(quantity: parsed));
                      }
                    },
                  ),
                ),
                if (_qtyError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _qtyError!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 9,
                        color: Color(0xFFDC2626),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (updated.medicineNotFound ||
              updated.dosageNotStocked ||
              updated.needsBrandSelection) ...[
            const SizedBox(width: 12),
            Text(
              // NOTE: the review screen does not run a live stock check
              // (that happens backend-side at save/dispense). These
              // labels are about catalog MATCHING, not stock on hand —
              // do not word them as "no stock" / "not stocked".
              updated.medicineNotFound
                  ? 'No catalog match'
                  : updated.dosageNotStocked
                  ? 'Strength not listed'
                  : 'Select brand',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: updated.medicineNotFound || updated.dosageNotStocked
                    ? const Color(0xFFDC2626)
                    : const Color(0xFFD97706),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ParsedFields {
  final String doctor;
  final String date;
  final String patient;
  final String diagnosis;
  final String licenseNo;
  final String ptNo;
  final String s2;
  final String address;

  /// Patient age in years, or null when nothing bounds-checked was
  /// found. Never a guessed default — see _parseOcr's age handling.
  final int? age;

  /// Patient sex, normalized to 'M'/'F', or null when not found.
  final String? gender;

  const _ParsedFields({
    required this.doctor,
    required this.date,
    required this.patient,
    required this.diagnosis,
    this.licenseNo = '',
    this.ptNo = '',
    this.s2 = '',
    this.address = '',
    this.age,
    this.gender,
  });
}

class _MatchedMedicine {
  // Session-local, stable identity. Assigned once when the medicine is
  // created (OCR-detected or manually added) and preserved across every
  // copyWith for the life of the review session. Used only as the
  // Flutter widget key for the medicine row so per-row editing state
  // follows the medicine, not its list position — never sent to the
  // backend.
  static int _idSeq = 0;
  final int id;

  final String medicineLabel;
  final String dosageLabel;
  final int quantity;
  final double unitPrice;
  final bool unitPriceIsExact;
  final String brandLabel;
  final bool needsBrandSelection;
  final bool medicineNotFound;
  final bool dosageNotStocked;
  final List<MedicineVariant> brandCandidates;
  final String? catalogName;

  /// The real `products.id` this row resolved to (brand+dosage or
  /// generic+dosage match), or null when nothing specific was resolved.
  /// Carried through to Save & Continue — see _performSave.
  final int? catalogProductId;
  final bool isEssential;
  final String duration;
  final double matchConfidence;
  final String originalOcrLabel;
  final bool isFallbackMatch;

  /// True for a medicine the pharmacist added by hand (Add Medicine)
  /// rather than one OCR detected. A manual entry is NOT a catalog-match
  /// failure — the pharmacist enters the name and price directly and
  /// that is valid on its own, with no reference to the registered
  /// medicine catalog required. Cleared if the row is later linked to a
  /// catalog SKU via the picker.
  final bool isManualEntry;

  _MatchedMedicine({
    int? id,
    required this.medicineLabel,
    required this.dosageLabel,
    required this.quantity,
    required this.unitPrice,
    this.unitPriceIsExact = true,
    this.brandLabel = '',
    this.needsBrandSelection = false,
    this.medicineNotFound = false,
    this.dosageNotStocked = false,
    this.brandCandidates = const [],
    this.catalogName,
    this.catalogProductId,
    this.isEssential = true,
    this.duration = '',
    this.matchConfidence = 0.0,
    String? originalOcrLabel,
    this.isFallbackMatch = false,
    this.isManualEntry = false,
  }) : id = id ?? ++_idSeq,
       originalOcrLabel = originalOcrLabel ?? medicineLabel;

  static const _unset = Object();

  _MatchedMedicine copyWith({
    String? medicineLabel,
    String? dosageLabel,
    int? quantity,
    double? unitPrice,
    bool? unitPriceIsExact,
    String? brandLabel,
    bool? needsBrandSelection,
    bool? medicineNotFound,
    bool? dosageNotStocked,
    List<MedicineVariant>? brandCandidates,
    Object? catalogName = _unset,
    Object? catalogProductId = _unset,
    bool? isEssential,
    String? duration,
    double? matchConfidence,
    bool? isFallbackMatch,
    bool? isManualEntry,
  }) {
    return _MatchedMedicine(
      // Identity is stable across edits — always carried forward.
      id: id,
      medicineLabel: medicineLabel ?? this.medicineLabel,
      dosageLabel: dosageLabel ?? this.dosageLabel,
      quantity: quantity ?? this.quantity,
      unitPrice: unitPrice ?? this.unitPrice,
      unitPriceIsExact: unitPriceIsExact ?? this.unitPriceIsExact,
      brandLabel: brandLabel ?? this.brandLabel,
      needsBrandSelection: needsBrandSelection ?? this.needsBrandSelection,
      medicineNotFound: medicineNotFound ?? this.medicineNotFound,
      dosageNotStocked: dosageNotStocked ?? this.dosageNotStocked,
      brandCandidates: brandCandidates ?? this.brandCandidates,
      catalogName: identical(catalogName, _unset)
          ? this.catalogName
          : catalogName as String?,
      catalogProductId: identical(catalogProductId, _unset)
          ? this.catalogProductId
          : catalogProductId as int?,
      isEssential: isEssential ?? this.isEssential,
      duration: duration ?? this.duration,
      matchConfidence: matchConfidence ?? this.matchConfidence,
      originalOcrLabel: originalOcrLabel,
      isFallbackMatch: isFallbackMatch ?? this.isFallbackMatch,
      isManualEntry: isManualEntry ?? this.isManualEntry,
    );
  }

  double get totalLine => quantity * unitPrice;

  bool get wasManuallyCorrected =>
      medicineLabel.trim().toLowerCase() !=
      originalOcrLabel.trim().toLowerCase();
}

class _MedicineResolution {
  static _MatchedMedicine resolve({
    required _MatchedMedicine current,
    required String name,
    String? dosage,
    String? brand,
  }) {
    try {
      final priced = PriceLookupService.lookup(
        name,
        dosage: dosage ?? current.dosageLabel,
        brand: brand ?? current.brandLabel,
      );
      return current.copyWith(
        medicineLabel: priced.canonicalName ?? name,
        unitPrice: priced.unitPrice,
        unitPriceIsExact: priced.isExactMatch,
        catalogProductId: priced.productId,
        // See _resolvedBrandLabel — prefers the catalog's own spelling
        // (resolved SKU, or fuzzy-matched against whatever this
        // pharmacy stocks for the name) over the raw override text.
        brandLabel: _resolvedBrandLabel(brand ?? current.brandLabel, priced),
        needsBrandSelection: priced.needsBrandSelection,
        medicineNotFound: priced.medicineNotFound,
        dosageNotStocked: priced.dosageNotStocked,
        brandCandidates: priced.candidates,
        catalogName: priced.variant?.name,
      );
    } catch (_) {
      return current.copyWith(
        medicineLabel: name,
        unitPrice: 0.0,
        medicineNotFound: true,
        needsBrandSelection: false,
        dosageNotStocked: false,
        catalogName: null,
        catalogProductId: null,
      );
    }
  }
}
