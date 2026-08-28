import '../models/prescription_scan_result.dart';
import 'price_lookup_service.dart';
import 'medicine_dictionary_service.dart';
import 'drug_abbreviations.dart';
import 'drug_knowledge_base.dart';

/// The "thinker" behind RxTrack now that Gemini is out of the picture.
///
/// OCR.space (like any character-recognition engine) only tells you what
/// characters it saw — it has no concept of "this is a medicine name" or
/// "this is a dosage". Structuring the flat text into patient/doctor/
/// medicine fields used to be Gemini's job. This service reproduces that
/// step entirely on-device, with no network call and no API key:
///
///  1. Split the OCR text into lines.
///  2. Pull out labeled fields (patient/doctor) with regex.
///  3. For each remaining line, look for a dosage (500mg), a quantity
///     (#30, 30 tabs), and a frequency shorthand (OD, BID, PRN, ...).
///  4. Match the leading words of the line against a curated dictionary
///     of common Philippine prescription drug names using fuzzy string
///     matching (Levenshtein distance), so OCR misreads like
///     "Amoxicilin" or "Ce1ecoxib" still resolve to the right drug.
///
/// This is a heuristic, not a trained ML model — there's no labeled
/// prescription dataset to train on here, and a few hundred regex +
/// dictionary rules cover the vast majority of prescription formats for
/// far less complexity and zero external dependency. Extend
/// [DrugKnowledgeBase.knownDrugs] as you encounter drugs it doesn't
/// recognize.
class PrescriptionParserService {
  /// Public wrappers around the Sig-line helpers below, so the OCR
  /// review screen's own regex-fallback matcher (used when the
  /// structured pipeline finds no medicines) can reuse the exact same
  /// fuzzy "Sig"/frequency/duration logic instead of a second,
  /// drifting copy of it.
  static bool isSigLine(String line) => _looksLikeSigLine(line);
  static String frequencyFrom(String text) => _findFrequency(text);
  static String durationFrom(String text) => _findDuration(text);
  static bool isFooterLabelLine(String line) => _looksLikeFooterLabelLine(line);

  /// Public wrapper around the Levenshtein-based drug-name correction
  /// used internally by [_extractMedicines] — lets the OCR review
  /// screen's own fallback matcher (used when the structured pipeline
  /// finds no medicines at all) correct OCR misreads (e.g. "Bioguc" ->
  /// "Biogesic") against the pharmacy's real catalog names the same way
  /// the main pipeline does, instead of handing raw, uncorrected OCR
  /// text straight to PriceLookupService (which only does exact,
  /// case-insensitive matching and will silently miss anything
  /// misspelled).
  static ({String? name, double score}) fuzzyMatchDrugName(
    String candidate,
    List<String> drugDictionary,
  ) => _fuzzyMatchDrug(candidate, drugDictionary);

  /// Public wrapper — same cheap pre-filter [_extractMedicines] uses to
  /// skip the fuzzy-match pass on lines that obviously aren't a name
  /// (pure symbol/digit noise), so the fallback matcher doesn't pay for
  /// fuzzy-matching against 339+ dictionary entries on every line.
  static bool hasEnoughLettersToBeAName(String line) =>
      _hasEnoughLettersToBeAName(line);

  // ---------------------------------------------------------------------
  // Knowledge base
  // ---------------------------------------------------------------------
  //
  // The drug-name dictionary and frequency-shorthand map used to live
  // here inline (a few hundred lines of drug names); they now live in
  // DrugKnowledgeBase (drug_knowledge_base.dart) to keep this file
  // focused on parsing logic. Extend DrugKnowledgeBase.knownDrugs as
  // you encounter drugs it doesn't recognize.

  static const List<String> _knownDrugs = DrugKnowledgeBase.knownDrugs;
  static const Map<String, String> _frequencyMap =
      DrugKnowledgeBase.frequencyMap;

  /// Numeral characters, plus letters OCR/handwriting recognition
  /// commonly confuses with a digit: O/o for 0, l/I/i for 1, Z/z for 2,
  /// S/s for 5, B/b for 8. Without this, a misread like "5OOmg" (capital
  /// O instead of zero) fails the old digits-only pattern entirely and
  /// the dosage gets silently dropped rather than corrected.
  static const String _digitLikeChars = r'0-9oOlIiZzSsBb';

  // Same class of bug as _quantityPattern above: the numeral portion
  // needs its own capturing group so group(1) is the number and group(2)
  // is the unit — previously the numeral wasn't captured at all, so
  // group(1) grabbed the unit word and group(2) didn't exist.
  static final RegExp _dosagePattern = RegExp(
    '([$_digitLikeChars]+(?:\\.[$_digitLikeChars]+)?)'
    '\\s?(mg|mcg|g|ml|iu|%)\\b',
    caseSensitive: false,
  );

  // Both alternatives capture the DIGIT portion (group 1 for "#12", group
  // 2 for "12 tabs") — the unit word itself is non-capturing since it's
  // never the value we actually want. Previously the unit word was what
  // got captured (and #-prefixed quantities captured nothing at all),
  // which both produced garbage output and crashed on a nonexistent
  // group(2) for any #-style match.
  /* static final RegExp _quantityPattern = RegExp(
    '#\\s?([$_digitLikeChars]+)|([$_digitLikeChars]+)\\s?'
    '(?:tabs?|tablets?|caps?|capsules?|pcs?|pieces?|'
    'bottles?|amps?|vials?|sachets?)',
    caseSensitive: false,
  );
*/
  static final RegExp _quantityPattern = RegExp(
    '#\\s?([$_digitLikeChars]+)|(?<![A-Za-z])([$_digitLikeChars]+)\\s?'
    '(?:tabs?|tablets?|caps?|capsules?|pcs?|pieces?|'
    'bottles?|amps?|vials?|sachets?)',
    caseSensitive: false,
  );
  // The physical dosage FORM word (as opposed to the strength captured
  // by [_dosagePattern]) — "Cap" in "Amoxicillin 500mg Cap #21". Kept
  // as its own capture so a row registers strength and form as two
  // separate, comparable fields instead of one of them getting stripped
  // as filler (see _looksLikeDosageOnlyFragment, which discards this
  // same class of word rather than keeping it).
  static final RegExp _dosageFormPattern = RegExp(
    r'\b(tablets?|tabs?|capsules?|caps?|syrups?|suspensions?|susps?|'
    r'sachets?|ampules?|amps?|vials?|drops?|creams?|ointments?|'
    r'patches?|suppositories?|supps?|lozenges?)\b',
    caseSensitive: false,
  );

  /// Normalizes a raw form word ("cap", "Tabs", "SUSP") into a single
  /// canonical label ("Capsule", "Tablet", "Suspension") so the same
  /// physical form written differently across prescriptions still
  /// compares equal.
  static String _normalizeDosageForm(String raw) {
    final key = raw.toLowerCase().trim();
    if (key.startsWith('tab')) return 'Tablet';
    if (key.startsWith('cap')) return 'Capsule';
    if (key.startsWith('susp') || key.startsWith('syrup')) return 'Syrup';
    if (key.startsWith('sach')) return 'Sachet';
    if (key.startsWith('amp')) return 'Ampule';
    if (key.startsWith('vial')) return 'Vial';
    if (key.startsWith('drop')) return 'Drops';
    if (key.startsWith('cream')) return 'Cream';
    if (key.startsWith('oint')) return 'Ointment';
    if (key.startsWith('patch')) return 'Patch';
    if (key.startsWith('supp')) return 'Suppository';
    if (key.startsWith('loz')) return 'Lozenge';
    return raw.trim();
  }

  /// Fixes letter-for-digit OCR/handwriting confusions inside a number
  /// that's already been isolated by [_dosagePattern]/[_quantityPattern]
  /// (i.e. we already know this substring is meant to be numeric —
  /// we're just not sure yet which digit each character represents).
  /// Never call this on a whole line/word — only on text matched by
  /// those patterns, or it'll mangle real words.
  static String _fixDigitConfusions(String numeralLike) {
    return numeralLike
        .replaceAll(RegExp(r'[oO]'), '0')
        .replaceAll(RegExp(r'[ilI]'), '1')
        .replaceAll(RegExp(r'[zZ]'), '2')
        .replaceAll(RegExp(r'[sS]'), '5')
        .replaceAll(RegExp(r'[bB]'), '8');
  }

  static const List<String> _headerKeywords = [
    'rx',
    'prescription',
    'clinic',
    'hospital',
    'address',
    'license',
    'ptr no',
    'signature',
    'physician',
    'diagnosis',
    'date:',
    'age:',
    'sex:',
    'name:',
    'patient:',
    'doctor:',
    'dr.',
    'license no',
  ];

  // ---------------------------------------------------------------------
  // Public entrypoint
  // ---------------------------------------------------------------------

  static PrescriptionScanResult parse(
    String rawText, {
    String engineUsed = 'ocrspace+parser',
    List<String>? drugDictionary,
    Map<String, String>? corrections,
  }) {
    if (rawText.trim().isEmpty) {
      return PrescriptionScanResult(
        success: false,
        error: 'No text detected in the image.',
        engineUsed: engineUsed,
      );
    }

    final lines = rawText
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final patientName = _extractLabeled(lines, [
      'patient name',
      'patient',
      'name of patient',
      'pt name',
    ]);
    final patientAge = _extractAge(lines);
    final patientGender = _extractGender(lines);
    final doctorName = _extractDoctorName(lines);
    final medicines = _extractMedicines(
      lines,
      drugDictionary ?? _knownDrugs,
      corrections ?? const {},
    );
    // ignore: avoid_print
    print(
      '[DEBUG] Dictionary used for this scan: '
      '${drugDictionary == null ? 'PNF-EML fallback' : "pharmacy's own catalog"}, '
      '${(drugDictionary ?? _knownDrugs).length} entries',
    );

    return PrescriptionScanResult(
      success: true,
      patientName: patientName,
      patientAge: patientAge,
      patientGender: patientGender,
      doctorName: doctorName,
      medicines: medicines,
      rawText: rawText,
      engineUsed: engineUsed,
    );
  }

  // ---------------------------------------------------------------------
  // Labeled field extraction
  // ---------------------------------------------------------------------

  static String? _extractLabeled(List<String> lines, List<String> labels) {
    for (final line in lines) {
      final lower = line.toLowerCase();
      for (final label in labels) {
        final idx = lower.indexOf('$label:');
        if (idx != -1) {
          final value = line.substring(idx + label.length + 1).trim();
          if (value.isNotEmpty) return value;
        }
      }
    }
    return null;
  }

  // Sane bounds for a human patient age. Anything outside this range is
  // almost certainly OCR noise (a stray PTR/license digit, a dosage
  // number) rather than a real age, and gets rejected rather than
  // silently accepted — an out-of-range "age" is worse than no age at
  // all, since it would display as if it were trustworthy.
  static const int _minValidAge = 0;
  static const int _maxValidAge = 120;

  /// Extracts patient age in years from the raw OCR lines, or null if
  /// nothing bounds-checked was found. Deliberately never falls back to
  /// a guessed default (e.g. 0) — a missing/unreadable age must stay
  /// null all the way to the UI so it renders as "not recorded" instead
  /// of a confident-looking wrong number.
  ///
  /// Tries, in order of trust:
  ///   1. An explicit "Age:" / "Age/Sex:" labeled line.
  ///   2. A loose "<digits> <M/F>" token (e.g. "45/M", "7 M") within the
  ///      first few lines only — patient demographics are always in the
  ///      header block of a PH prescription pad, so restricting the
  ///      search there avoids accidentally matching a stray number+letter
  ///      combination inside the medicine list further down.
  static int? _extractAge(List<String> lines) {
    for (final line in lines) {
      final label = RegExp(
        r'\bage\s*(?:/\s*sex)?\s*:',
        caseSensitive: false,
      ).firstMatch(line);
      if (label == null) continue;
      final rest = line.substring(label.end);
      final numMatch = RegExp(r'\d{1,3}').firstMatch(rest);
      if (numMatch == null) continue;
      final value = int.tryParse(numMatch.group(0)!);
      if (value != null && value >= _minValidAge && value <= _maxValidAge) {
        return value;
      }
    }

    final headerLines = lines.take(15);
    for (final line in headerLines) {
      final combo = RegExp(
        r'\b(\d{1,3})\s*[\/\-]?\s*[MF]\b',
        caseSensitive: false,
      ).firstMatch(line);
      if (combo == null) continue;
      final value = int.tryParse(combo.group(1)!);
      if (value != null && value >= _minValidAge && value <= _maxValidAge) {
        return value;
      }
    }
    return null;
  }

  /// Extracts patient sex as a normalized 'M' or 'F', or null if nothing
  /// was found. Same "null means unknown" contract as [_extractAge] —
  /// this never defaults to 'M' (or anything else) when the document
  /// simply didn't say.
  static String? _extractGender(List<String> lines) {
    for (final line in lines) {
      final label = RegExp(
        r'\b(sex|gender)\s*:',
        caseSensitive: false,
      ).firstMatch(line);
      if (label == null) continue;
      final rest = line.substring(label.end);
      final genderMatch = RegExp(
        r'\b(male|female|[MF])\b',
        caseSensitive: false,
      ).firstMatch(rest);
      if (genderMatch == null) continue;
      final raw = genderMatch.group(1)!.toUpperCase();
      return raw.startsWith('M') ? 'M' : 'F';
    }

    final headerLines = lines.take(15);
    for (final line in headerLines) {
      final combo = RegExp(
        r'\b\d{1,3}\s*[\/\-]?\s*([MF])\b',
        caseSensitive: false,
      ).firstMatch(line);
      if (combo == null) continue;
      return combo.group(1)!.toUpperCase();
    }
    return null;
  }

  static String? _extractDoctorName(List<String> lines) {
    final labeled = _extractLabeled(lines, ['doctor', 'physician']);
    if (labeled != null) return labeled;

    final drPattern = RegExp(
      r'\bDr\.?\s+[A-Z][a-zA-Z.\-]*(?:\s+[A-Z][a-zA-Z.\-]*){0,3}',
    );
    for (final line in lines) {
      final match = drPattern.firstMatch(line);
      if (match != null) return match.group(0)!.trim();
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Medicine line extraction
  // ---------------------------------------------------------------------

  // Safety caps against pathological OCR output (a noisy/low-quality photo
  // can make OCR.space return hundreds or thousands of short garbage
  // "lines"). Without these, every single line — garbage or not — pays
  // the full cost of _fuzzyMatchDrug (3 windows x dictionary size x
  // Levenshtein each), all synchronously on the browser's one JS thread
  // with no yield point in between. On a bad enough photo that's enough
  // work to visibly freeze the tab for a long time with zero console
  // output in between, which looks identical to a hang even though
  // nothing is actually stuck. A real handwritten prescription is never
  // more than a couple dozen lines, so these caps don't affect normal
  // scans at all.
  static const int _maxLinesConsidered = 200;
  static const int _maxMedicinesFound = 40;

  /// Cheap pre-check to reject obvious noise before paying for a full
  /// fuzzy-match pass: a line with fewer than 2 letters in it can't be a
  /// drug name (dosage numbers/units alone don't count), so there's no
  /// point running Levenshtein against the whole dictionary for it.
  static bool _hasEnoughLettersToBeAName(String line) {
    final letterCount = line.replaceAll(RegExp(r'[^A-Za-z]'), '').length;
    return letterCount >= 2;
  }

  // Matches a brand name written in parentheses, either inline with the
  // generic name/dosage ("Amoxicillin (Himox) 500mg") or as its own
  // line right above/below the generic line — the common Philippine
  // Rx format where the doctor writes the brand on its own line, e.g.:
  //   (Himox)
  //   Amoxicillin 500mg Cap #21
  static final RegExp _brandParenRe = RegExp(
    r'\(([A-Za-z][A-Za-z0-9\-\s]{1,30})\)',
  );

  // A line that is ENTIRELY a parenthetical (nothing else on it) is
  // almost certainly a standalone brand line rather than part of the
  // dosage/instruction text, e.g. "(Himox)" on its own line.
  static bool _isStandaloneParenLine(String line) =>
      RegExp(r'^\(([A-Za-z][A-Za-z0-9\-\s]{1,30})\)$').hasMatch(line.trim());

  /// True when [line], after stripping out whatever [_dosagePattern] and
  /// [_quantityPattern] matched plus common dosage-FORM filler words
  /// ("tab", "cap", "sachet", ...), has almost no letters left — i.e.
  /// the line is essentially just a bare dosage/quantity/form fragment
  /// ("#30 500mg tab") rather than a real drug name that happens to
  /// carry its own strength ("Paracetamol 500mg #10"). This is the
  /// key signal [_maybeMergeNameOnlyLine] uses to decide whether the
  /// FOLLOWING line is safe to fold into an orphaned name-only line
  /// above it, or whether it's actually a complete, independent
  /// medicine line of its own that must NOT be swallowed.
  static bool _looksLikeDosageOnlyFragment(String line) {
    if (!_dosagePattern.hasMatch(line) && !_quantityPattern.hasMatch(line)) {
      return false;
    }
    var stripped = line;
    for (final m in _dosagePattern.allMatches(line).toList().reversed) {
      stripped = stripped.replaceRange(m.start, m.end, ' ');
    }
    for (final m in _quantityPattern.allMatches(stripped).toList().reversed) {
      stripped = stripped.replaceRange(m.start, m.end, ' ');
    }
    stripped = stripped.toLowerCase().replaceAll(
      RegExp(
        r'\b(tabs?|tablets?|caps?|capsules?|pcs?|pieces?|'
        r'bottles?|amps?|vials?|sachets?)\b',
      ),
      ' ',
    );
    final letters = stripped.replaceAll(RegExp(r'[^A-Za-z]'), '');
    return letters.length < 4;
  }

  /// Attempts to fold a name-only line ("Ascorbic Acid") together with
  /// a dosage/quantity-only continuation line right below it
  /// ("#30 500mg tab") — the split-across-two-lines layout some Rx
  /// pads use. Deliberately narrow: it requires the CURRENT line to
  /// look like a short, plausible drug name (a handful of words,
  /// enough letters), and the NEXT line to look like almost nothing
  /// BUT a dosage/quantity fragment ([_looksLikeDosageOnlyFragment]).
  /// That second check is what keeps this from mis-firing on a
  /// completely unrelated pair like a diagnosis/complaint line
  /// ("Fever and cough") immediately followed by a genuinely separate,
  /// already-complete drug line ("Paracetamol 500mg #10") — that next
  /// line has "Paracetamol" left over after stripping its dosage, so
  /// it fails [_looksLikeDosageOnlyFragment] and is correctly left
  /// alone to be parsed as its own medicine on the next loop pass,
  /// rather than being swallowed into the diagnosis line above it.
  static String? _maybeMergeNameOnlyLine(
    String line,
    List<String> lines,
    int i,
  ) {
    // Only a line that already has its own dosage (strength) is truly
    // "complete" and ineligible to merge — a quantity marker ("# 30")
    // alone is NOT enough to rule this out. Rx pads commonly split a
    // medicine as "Name # 30" on one line with "500mg tab" on the
    // next; bailing out here on quantity alone used to mean that split
    // was never recognized, AND (since this function is also reused as
    // the Sig-lookahead's "is the next line actually a new drug?"
    // check) a preceding "Sig:" line would wrongly swallow a
    // name+quantity line like this as more dosing instructions instead
    // of stopping before it — silently dropping the whole medicine.
    if (_dosagePattern.hasMatch(line)) {
      return null;
    }
    if (!_hasEnoughLettersToBeAName(line)) return null;
    if (line.split(RegExp(r'\s+')).length > 5) return null;
    if (i + 1 >= lines.length) return null;

    final next = lines[i + 1].trim();
    if (next.isEmpty) return null;
    if (_looksLikeHeaderLine(next)) return null;
    if (_looksLikeSigLine(next)) return null;
    if (_isStandaloneParenLine(next)) return null;
    if (!_looksLikeDosageOnlyFragment(next)) return null;

    return '$line $next';
  }

  static List<PrescriptionMedicine> _extractMedicines(
    List<String> lines,
    List<String> drugDictionary,
    Map<String, String> corrections,
  ) {
    final medicines = <PrescriptionMedicine>[];

    for (var i = 0; i < lines.length && i < _maxLinesConsidered; i++) {
      if (medicines.length >= _maxMedicinesFound) break;

      final rawLine = lines[i];
      // A standalone "(Brand)" line is consumed as part of the NEXT
      // medicine line's brand, never as its own medicine — skip it here.
      if (_isStandaloneParenLine(rawLine)) continue;

      // A "Sig:" line (the dosing instruction — "1 cap 3x a day for 7
      // days") sits on its OWN line right below the drug it belongs
      // to, per the standard Rx pad layout — it is never itself a
      // medicine line. Handwriting OCR mangles "Sig" often ("sier",
      // "big", "s1g", ...) and frequently wraps onto a second line
      // ("... for" / "seven days"), so this: (a) fuzzy-matches the
      // line's first token against "sig" rather than requiring an
      // exact string, (b) pulls in up to 2 following lines as
      // continuation text before extracting frequency/duration, and
      // (c) attaches the result to the MOST RECENTLY parsed medicine
      // — never a floating, orphaned field. Without this, everything
      // after "Sig:" was silently dropped, however cleanly it was
      // scanned.
      if (medicines.isNotEmpty && _looksLikeSigLine(rawLine)) {
        var lastConsumed = i;
        final segments = <String>[rawLine];
        for (var j = i + 1; j < lines.length && j <= i + 2; j++) {
          final next = lines[j].trim();
          if (next.isEmpty) break;
          if (_looksLikeHeaderLine(next)) break;
          if (_isStandaloneParenLine(next)) break;
          if (_dosagePattern.hasMatch(next)) break;
          // A short Sig line ("Sig: A.D.") directly above the NEXT
          // drug's own name-only line ("Ascorbic Acid", with its
          // "#30 500mg tab" split onto the line after THAT) looks
          // identical to genuine wrapped Sig text at this point —
          // neither has a dosage/quantity marker of its own yet. Left
          // unchecked, this loop swallows that next drug's name as
          // if it were more dosing instructions, and its orphaned
          // dosage-only line then has no name left to attach to and
          // silently drops the whole medicine (see
          // _maybeMergeNameOnlyLine's doc comment for the split-line
          // format this recognizes). Stop here instead — the SAME
          // check the main loop uses to decide "is this the first
          // half of a split medicine line" also tells us whether the
          // line we're about to swallow actually belongs to the
          // NEXT drug, not this Sig.
          if (_maybeMergeNameOnlyLine(next, lines, j) != null) break;
          final probeName = next
              .replaceAll(_quantityPattern, ' ')
              .replaceAll(_dosagePattern, ' ')
              .trim();
          if (_hasEnoughLettersToBeAName(probeName) &&
              _fuzzyMatchDrug(probeName, drugDictionary).score >= 0.75) {
            break;
          }
          segments.add(next);
          lastConsumed = j;
        }

        final sigText = segments.join(' ');
        final sigFrequency = _findFrequency(sigText);
        final sigDuration = _findDuration(sigText);
        if (sigFrequency.isNotEmpty || sigDuration.isNotEmpty) {
          final prev = medicines.removeLast();
          medicines.add(
            PrescriptionMedicine(
              name: prev.name,
              dosage: prev.dosage,
              quantity: prev.quantity,
              frequency: sigFrequency.isNotEmpty
                  ? sigFrequency
                  : prev.frequency,
              brand: prev.brand,
              duration: sigDuration.isNotEmpty ? sigDuration : prev.duration,
              matchConfidence: prev.matchConfidence,
            ),
          );
        }
        i = lastConsumed;
        continue;
      }

      var line = rawLine.replaceFirst(RegExp(r'^[\d]+[.)\-]\s*'), '').trim();
      if (line.isEmpty || _looksLikeHeaderLine(line)) continue;

      // The Rx (℞) symbol commonly sits on the SAME line as the first
      // drug rather than on its own line ("Rx Feso4 tab #30") — unlike
      // a standalone "Rx" line, which _looksLikeHeaderLine already
      // drops via the header-keyword list. Left unstripped here, "Rx "
      // pollutes the 1-/2-word fuzzy-match windows below (comparing
      // "rx feso" against the dictionary instead of just "feso"),
      // which was silently losing real drugs that have no explicit mg
      // dosage on the line (plain "#30 tabs" iron/vitamin lines, common
      // handwriting shorthand) — strip it before any parsing below.
      line = line
          .replaceFirst(
            RegExp(r'^(rx|℞|r/)\.?\s*[:\-]?\s*', caseSensitive: false),
            '',
          )
          .trim();
      if (line.isEmpty) continue;

      // Preserve the index of THIS medicine's own line before any
      // lookahead merge below shifts `i` — the "brand written on the
      // line above" check further down needs to keep looking at the
      // line directly above the drug's NAME, not above whatever line
      // `i` ends up on after a merge.
      final nameLineIndex = i;

      // Some Rx pads split a single medicine across two lines: the
      // drug name alone on one line, with its dosage/quantity/form on
      // the very next line ("Ascorbic Acid" / "#30 500mg tab"). Taken
      // alone, the name-only line has no dosage and no quantity, and a
      // real generic name (e.g. "Ascorbic Acid") won't necessarily be
      // a confident fuzzy-match against the dictionary either — so
      // without this it fails the "is this a medicine line" check
      // below and silently disappears. The line after it then ALSO
      // disappears: stripped of its digits it has no letters left to
      // be a name of its own, so it fails the same check. Net result:
      // the whole medicine vanishes with no trace.
      //
      // [_maybeMergeNameOnlyLine] is deliberately conservative about
      // WHEN to do this — see its doc comment for why a naive "next
      // line has a dosage" check is unsafe (it would swallow an
      // unrelated, already-complete drug line on the next iteration
      // into a preceding diagnosis/complaint line).
      final merged = _maybeMergeNameOnlyLine(line, lines, i);
      if (merged != null) {
        line = merged;
        i++;
      }

      // Brand written inline with the generic name, e.g.
      // "Amoxicillin (Himox) 500mg" — pull it out before name/dosage
      // parsing so it doesn't pollute the fuzzy-match candidate.
      String brand = '';
      final inlineBrandMatch = _brandParenRe.firstMatch(line);
      if (inlineBrandMatch != null) {
        brand = inlineBrandMatch.group(1)!.trim();
        line = line
            .replaceRange(inlineBrandMatch.start, inlineBrandMatch.end, '')
            .trim();
        line = line.replaceAll(RegExp(r'\s+'), ' ');
      } else if (nameLineIndex > 0 &&
          _isStandaloneParenLine(lines[nameLineIndex - 1])) {
        // Brand written on its own line just above this one.
        final m = RegExp(
          r'^\(([A-Za-z][A-Za-z0-9\-\s]{1,30})\)$',
        ).firstMatch(lines[nameLineIndex - 1].trim());
        brand = m?.group(1)?.trim() ?? '';
      }

      final dosageMatch = _dosagePattern.firstMatch(line);
      final quantityMatch = _quantityPattern.firstMatch(line);
      final frequency = _findFrequency(line);
      final dosageFormMatch = _dosageFormPattern.firstMatch(line);
      final dosageForm = dosageFormMatch != null
          ? _normalizeDosageForm(dosageFormMatch.group(1)!)
          : '';

      final nameCandidate = dosageMatch != null
          ? line.substring(0, dosageMatch.start).trim()
          : line;

      // Check institutional correction memory FIRST, before the generic
      // dictionary fuzzy-match — a pharmacist has already manually
      // verified this exact OCR misread once before for this pharmacy,
      // so it's more trustworthy than a fresh fuzzy-match guess. See
      // CorrectionMemoryService for what populates this map.
      final correctionHit = corrections[nameCandidate.trim().toLowerCase()];

      // Skip the expensive fuzzy-match pass entirely for lines that are
      // obviously not a drug name (too few letters — pure symbol/digit
      // noise) and don't already have a correction-memory hit. This is
      // the main defense against noise-heavy OCR output being slow.
      ({String? name, double score}) match;
      if (correctionHit != null) {
        match = (name: correctionHit, score: 1.0);
      } else if (_hasEnoughLettersToBeAName(nameCandidate)) {
        match = _fuzzyMatchDrug(nameCandidate, drugDictionary);
      } else {
        match = (name: null, score: 0.0);
      }
      // ignore: avoid_print
      print(
        '[DEBUG] Name fuzzy match: candidate="$nameCandidate" '
        'bestScore=${match.score.toStringAsFixed(3)} '
        'result=${match.name ?? "(no match — below threshold, or dictionary had nothing close)"}',
      );

      // Only treat this as a medicine line if it has a dosage, a
      // quantity marker, or matches a known drug closely enough —
      // otherwise it's likely a diagnosis, instruction, or letterhead
      // line, and we skip it rather than invent a medicine that isn't
      // there.
      //
      // A quantity marker ("#30", "30 tabs") is deliberately treated
      // as sufficient ON ITS OWN, even with no mg dosage and no
      // confident dictionary match — short chemical-formula names like
      // "FeSO4" fuzzy-match poorly (see _fuzzyMatchDrug), and this used
      // to just `continue` past the whole line in that case. That drops
      // a prescribed drug from the scan with no trace and no warning,
      // which is a patient-safety problem for a dispensing app: a
      // low-confidence guess that's visibly flagged is safe, a drug
      // that silently vanishes is not. Falling through instead lets it
      // become a PrescriptionMedicine with matchConfidence 0.0, which
      // PriceLookupService/the review screen already know how to
      // surface as a "not in this pharmacy's medicine list" warning —
      // visible and correctable instead of missing.
      if (dosageMatch == null && match.name == null && quantityMatch == null) {
        continue;
      }

      // Which of (nameCandidate, brand-text) is actually the GENERIC and
      // which is actually the BRAND can't be determined from position
      // alone — real prescriptions go both ways: "Amoxicillin (Himox)
      // 500mg" (generic first) and "Biogesic 500mg (Paracetamol)" (brand
      // first) are both real patterns seen on scans. What DOES tell us
      // which is which is what each piece of text actually resolves to
      // in this pharmacy's own catalog: a generic-type dictionary entry
      // always has generic_name equal to its own name; a brand-type
      // entry's generic_name points to something else entirely (see
      // MedicineDictionaryService.genericNameFor). Checking that lets
      // this self-correct regardless of which order a given doctor
      // wrote it in, rather than only ever handling one convention.
      String? primaryGeneric;
      var primaryIsBrandType = false;
      if (match.name != null) {
        primaryGeneric = MedicineDictionaryService.genericNameFor(match.name!);
        if (primaryGeneric != null &&
            primaryGeneric.trim().toLowerCase() !=
                match.name!.trim().toLowerCase()) {
          primaryIsBrandType = true;
        }
      }

      // Fuzzy-match the parenthetical/secondary text against the full
      // dictionary too (not just the primary match's own brand list —
      // we don't know yet whether primary is the generic or the brand,
      // so this can't be scoped down to variantsFor(name) until AFTER
      // the roles below are decided).
      ({String? name, double score}) brandMatch = (name: null, score: 1.0);
      String? secondaryGeneric;
      var secondaryIsBrandType = false;
      if (brand.trim().isNotEmpty && _hasEnoughLettersToBeAName(brand)) {
        brandMatch = _fuzzyMatchDrug(brand, drugDictionary);
        // ignore: avoid_print
        print(
          '[DEBUG] Brand fuzzy match: candidate="$brand" '
          'bestScore=${brandMatch.score.toStringAsFixed(3)} '
          'result=${brandMatch.name ?? "(no match — below threshold, or dictionary had nothing close)"}',
        );
        if (brandMatch.name != null) {
          secondaryGeneric = MedicineDictionaryService.genericNameFor(
            brandMatch.name!,
          );
          if (secondaryGeneric != null &&
              secondaryGeneric.trim().toLowerCase() !=
                  brandMatch.name!.trim().toLowerCase()) {
            secondaryIsBrandType = true;
          }
        }
      }

      // True when the generic text matched nothing but the brand text
      // resolved to a real brand-type catalog entry — see the branch
      // below. Hoisted so matchConfidence can reflect the brand match
      // instead of scoring this as an unmatched 0.0 line.
      final resolvedViaBrand = match.name == null &&
          secondaryIsBrandType &&
          (secondaryGeneric?.trim().isNotEmpty ?? false);

      String name;
      if (primaryIsBrandType && !secondaryIsBrandType) {
        // INVERTED: the main line's text resolved to a BRAND-type
        // catalog entry (e.g. "Biogesic"), not a generic — swap. The
        // true generic (from genericNameFor) becomes the primary name;
        // what was originally matched as "name" becomes the brand.
        name = primaryGeneric ?? _cleanName(nameCandidate);
        brand = match.name!;
      } else if (resolvedViaBrand) {
        // The generic-name text matched NOTHING in the catalog, but the
        // brand text resolved to a real BRAND-type entry — the OCR-read
        // generic is almost certainly a misread ("Amoxicilin"). The
        // catalog is the source of truth: take the brand's real
        // underlying generic as the name, keep the matched brand. The
        // review screen's brand+dosage lookup then confirms the exact
        // DB row (and its product id / price).
        name = secondaryGeneric!.trim();
        brand = brandMatch.name!;
      } else {
        // NORMAL convention, or an ambiguous combination (both sides
        // resolved to the same type, or one/both didn't match at all)
        // — safe default is main line = generic, secondary = brand,
        // same as the established convention.
        name = match.name ?? _cleanName(nameCandidate);
        if (brandMatch.name != null) {
          brand = brandMatch.name!;
        }
        // else: keep the raw OCR brand text as-is (unmatched, low
        // confidence) rather than inventing or blanking it.
      }
      if (name.isEmpty) continue;

      String dosage = dosageMatch != null
          ? '${_fixDigitConfusions(dosageMatch.group(1)!)}'
                '${dosageMatch.group(2)!.toLowerCase()}'
          : '';

      // Cross-check the dosage against this medicine's known variants
      // (fuzzy-distance: snaps to the numerically nearest same-unit
      // strength this pharmacy actually stocks, not just a single
      // digit swap — e.g. "580mg" -> "500 MG"). This is a DIFFERENT
      // failure mode than the letter-lookalike confusions
      // [_fixDigitConfusions] already fixes above: a digit misread as
      // a DIFFERENT digit (8 for 0) produces a still-numeric, still-
      // plausible-looking value that only a real-inventory check can
      // catch. Reuses [PriceLookupService.resolveDosageLabel] rather
      // than a second copy of the same nearest-match logic, since
      // pricing already needed this exact comparison. Only runs once a
      // confident generic-name match exists — snapping a dosage against
      // the WRONG medicine's variants would be worse than leaving it
      // alone.
      var dosageWasSnapped = false;
      if (dosage.isNotEmpty && match.name != null) {
        final resolved = PriceLookupService.resolveDosageLabel(name, dosage);
        if (!resolved.isExact) {
          // Reformat the dictionary's label ("500 MG") into this
          // parser's own display convention ("500mg") rather than
          // introducing a second dosage format on the review screen.
          final relabel = RegExp(
            r'^(\d+(?:\.\d+)?)\s*(mg|mcg|g|ml|iu|%)$',
            caseSensitive: false,
          ).firstMatch(resolved.dosage.trim());
          dosage = relabel != null
              ? '${relabel.group(1)}${relabel.group(2)!.toLowerCase()}'
              : resolved.dosage;
          dosageWasSnapped = true;
        }
      }

      // A snapped (non-exact) dosage is a guess, however well-informed
      // — flagged with a fixed confidence penalty rather than 1.0, so
      // it's visible on review and factors into the overall
      // matchConfidence below rather than looking as trustworthy as an
      // exact match.
      const dosageSnapConfidence = 0.75;

      final parsedMedicine = PrescriptionMedicine(
        name: name,
        dosage: dosage,
        quantity: quantityMatch != null
            ? _fixDigitConfusions(
                quantityMatch.group(1) ?? quantityMatch.group(2) ?? '',
              )
            : '',
        frequency: frequency,
        brand: brand,
        dosageForm: dosageForm,
        // Only meaningful when a dictionary match actually happened —
        // a medicine kept purely because it had a dosage (no name
        // match at all) is treated as zero confidence, since there's
        // nothing here to have actually matched against.
        // When there IS a name match, take the LOWEST of name-match,
        // brand-match, and (if snapped) dosage-match confidence, so a
        // confident generic-name match doesn't mask an unverified
        // brand or a guessed dosage correction.
        matchConfidence: (match.name == null && !resolvedViaBrand)
            ? 0.0
            : [
                if (match.name != null) match.score,
                brandMatch.score,
                if (dosageWasSnapped) dosageSnapConfidence,
              ].reduce((a, b) => a < b ? a : b),
      );
      // ignore: avoid_print
      print(
        '[DEBUG] Parsed medicine: name=${parsedMedicine.name} '
        'brand=${parsedMedicine.brand.isEmpty ? '(none)' : parsedMedicine.brand} '
        'dosage=${parsedMedicine.dosage.isEmpty ? '(none)' : parsedMedicine.dosage} '
        'dosageForm=${parsedMedicine.dosageForm.isEmpty ? '(none)' : parsedMedicine.dosageForm} '
        'quantity=${parsedMedicine.quantity.isEmpty ? '(none)' : parsedMedicine.quantity} '
        'matchConfidence=${parsedMedicine.matchConfidence.toStringAsFixed(2)}',
      );
      medicines.add(parsedMedicine);
    }

    return medicines;
  }

  static bool _looksLikeHeaderLine(String line) {
    final lower = line.toLowerCase();
    final hasDigits = RegExp(r'\d').hasMatch(lower);
    if (hasDigits) return false;
    if (_headerKeywords.any((k) => lower.startsWith(k))) return true;
    // Fuzzy fallback for footer/label lines whose leading word OCR
    // mangled just enough to dodge the exact-prefix check above (e.g.
    // "PTR No" -> "PIR No", a single letter swap) — same idea as
    // _looksLikeSigLine. Without this, a mangled label line with no
    // digits on it (the value is on the NEXT line, per the standard
    // form layout) gets treated as a bare drug name and priced at
    // ₱0.00 as a phantom line item.
    return _looksLikeFooterLabelLine(line);
  }

  /// Roots of common Rx-pad footer/header labels, checked against just
  /// the line's first token via Levenshtein similarity — catches OCR
  /// misreads like "PTR" -> "PIR", "Lic." -> "Lac.", "Physician's" ->
  /// "Physicia's" that a literal `startsWith` can't.
  static const List<String> _footerLabelRoots = [
    'ptr',
    'lic',
    'license',
    's2',
    'physician',
    'signature',
    'address',
    'name',
    'age',
    'sex',
    'date',
    'patient',
    'doctor',
    'dr',
    'diagnosis',
  ];

  static bool _looksLikeFooterLabelLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return false;
    final firstToken = trimmed
        .split(RegExp(r'[\s:.]+'))
        .firstWhere((t) => t.isNotEmpty, orElse: () => '');
    if (firstToken.length < 2) return false;
    final lower = firstToken.toLowerCase();
    for (final root in _footerLabelRoots) {
      // Short roots (ptr, lic, s2, dr) need a stricter similarity bar —
      // a single-character difference swings the ratio much further on
      // a 2-3 letter word, so the threshold has to be tighter to avoid
      // catching an unrelated short drug name/abbreviation.
      final threshold = root.length <= 3 ? 0.65 : 0.6;
      if (_similarity(lower, root) >= threshold) return true;
    }
    return false;
  }

  /* static String _findFrequency(String line) {
    final lower = line.toLowerCase();
    for (final entry in _frequencyMap.entries) {
      final pattern = RegExp(r'\b' + RegExp.escape(entry.key) + r'\b');
      if (pattern.hasMatch(lower)) return entry.value;
    }
    // Loose form doctors actually write on the Sig line — "3x a day",
    // "3x aday" (no space), "3 x daily" — not covered by the exact-key
    // map above since the digit varies.
    final xTimesMatch = RegExp(r'(\d)\s*x\s*a?\s*day').firstMatch(lower);
    if (xTimesMatch != null) {
      final n = xTimesMatch.group(1);
      return '${n}x daily';
    }
    return '';
  }
  */

  static String _findFrequency(String line) {
    final lower = line.toLowerCase();

    String base = '';
    for (final entry in _frequencyMap.entries) {
      final pattern = RegExp(r'\b' + RegExp.escape(entry.key) + r'\b');
      if (pattern.hasMatch(lower)) {
        base = entry.value;
        break;
      }
    }
    if (base.isEmpty) {
      final xTimesMatch = RegExp(r'(\d)\s*x\s*a?\s*day').firstMatch(lower);
      if (xTimesMatch != null) {
        base = '${xTimesMatch.group(1)}x daily';
      }
    }
    if (base.isEmpty) {
      final qHourMatch = RegExp(r'\bq\s*(\d+)\s*h\b').firstMatch(lower);
      if (qHourMatch != null) {
        final n = qHourMatch.group(1);
        base = 'every $n hour${n == '1' ? '' : 's'}';
      }
    }

    final asNeeded = _findAsNeeded(lower);

    if (base.isNotEmpty && asNeeded) return '$base, as needed';
    if (base.isNotEmpty) return base;
    if (asNeeded) return 'as needed';
    return '';
  }

  static bool _findAsNeeded(String lower) {
    if (RegExp(r'\bas\s+needed\b').hasMatch(lower)) return true;
    if (RegExp(r'\bprn\b').hasMatch(lower)) return true;
    return false;
  }

  /// True if [line]'s first token is close enough to "sig" (allowing
  /// for handwriting-OCR mangling like "sier", "big", "s1g") that this
  /// is almost certainly the dosing-instruction line, not a drug name
  /// or anything else. Kept intentionally narrow (2-5 letters, no
  /// digits) so it doesn't swallow unrelated short lines.
  static bool _looksLikeSigLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return false;
    final firstToken = trimmed
        .split(RegExp(r'[\s:.]+'))
        .firstWhere((t) => t.isNotEmpty, orElse: () => '');
    if (firstToken.length < 2 || firstToken.length > 5) return false;
    if (RegExp(r'\d').hasMatch(firstToken)) return false;
    return _similarity(firstToken.toLowerCase(), 'sig') >= 0.5;
  }

  /// Number words 1-30 that duration phrases ("for seven days") use,
  /// mapped for the fuzzy lookup in [_bestNumberWord] below — OCR on
  /// handwriting misreads these just as often as it misreads digits
  /// (e.g. "seven" -> "suen").
  static const Map<String, int> _numberWords = {
    'one': 1,
    'two': 2,
    'three': 3,
    'four': 4,
    'five': 5,
    'six': 6,
    'seven': 7,
    'eight': 8,
    'nine': 9,
    'ten': 10,
    'eleven': 11,
    'twelve': 12,
    'thirteen': 13,
    'fourteen': 14,
    'fifteen': 15,
    'twenty': 20,
    'thirty': 30,
  };

  /// Extracts a treatment duration like "7 days" from Sig text.
  /// Handles digit form directly ("for 7 days") and number-word form
  /// with fuzzy tolerance on BOTH "for" and the number word, since
  /// handwriting OCR frequently mangles both ("fair suen day" for
  /// "for seven days") and duration is usually the last, most
  /// squeezed-in part of the Sig line.
  static String _findDuration(String sigText) {
    final lower = sigText.toLowerCase();

    final digitMatch = RegExp(r'for\s+(\d+)\s*days?').firstMatch(lower);
    if (digitMatch != null) {
      final n = digitMatch.group(1)!;
      return '$n day${n == '1' ? '' : 's'}';
    }

    final tokens = lower.split(RegExp(r'\s+'));
    for (var i = 0; i < tokens.length; i++) {
      if (_similarity(tokens[i], 'for') < 0.5) continue;
      for (var j = i + 1; j < tokens.length && j <= i + 3; j++) {
        final isDayWord =
            _similarity(tokens[j], 'day') >= 0.55 ||
            _similarity(tokens[j], 'days') >= 0.55;
        if (!isDayWord || j == i + 1) continue;
        final number = _bestNumberWord(tokens[j - 1]);
        if (number != null) {
          return '$number day${number == 1 ? '' : 's'}';
        }
      }
    }
    return '';
  }

  /// Fuzzy-matches [candidate] against the small [_numberWords]
  /// dictionary the same way [_fuzzyMatchDrug] matches drug names —
  /// same tool, much smaller vocabulary, so a looser bar is fine here
  /// without meaningfully risking a false positive.
  static int? _bestNumberWord(String candidate) {
    int? best;
    double bestScore = 0.0;
    for (final entry in _numberWords.entries) {
      final score = _similarity(candidate, entry.key);
      if (score > bestScore) {
        bestScore = score;
        best = entry.value;
      }
    }
    return bestScore >= 0.55 ? best : null;
  }

  static String _cleanName(String raw) {
    var s = raw.replaceAll(RegExp(r'[^A-Za-z\s\-]'), ' ').trim();
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    if (s.isEmpty) return '';
    return s.split(' ').map(_capitalize).join(' ');
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  // ---------------------------------------------------------------------
  // Fuzzy drug-name matching (Levenshtein distance)
  // ---------------------------------------------------------------------

  static ({String? name, double score}) _fuzzyMatchDrug(
    String candidate,
    List<String> drugDictionary,
  ) {
    final cleaned = candidate
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z\s\-]'), ' ')
        .trim();
    if (cleaned.isEmpty) return (name: null, score: 0.0);

    final words = cleaned.split(RegExp(r'\s+'));

    String? best;
    double bestScore = 0.0;

    // SPEED-FIRST (post-audit): a score this high means we've already
    // found a match close enough that no other dictionary entry could
    // plausibly beat it — stop scanning immediately instead of finishing
    // the rest of the dictionary and the remaining window sizes "just in
    // case". This is the single biggest lever on this loop: the common
    // case (an OCR line whose leading word already closely matches a
    // real drug name) now short-circuits after finding it instead of
    // paying for the full 3-window x dictionary-size sweep every time.
    const earlyExitScore = 0.97;

    // PASS 1 — normal fuzzy comparison against the active dictionary
    // (this pharmacy's real catalog, or the offline fallback list),
    // exactly the same as correcting any other OCR misread (e.g.
    // "Bioguc" -> "Biogesic"). This runs BEFORE the abbreviation check
    // below on purpose: if the raw text already scores well against
    // something the pharmacy actually stocks, that real match should
    // win — an abbreviation guess has no business overriding it.
    //
    // Medicine names are rarely more than 3 words, and always appear at
    // the start of the line — try 1-, 2-, and 3-word leading windows.
    outer:
    for (
      int windowSize = 1;
      windowSize <= 3 && windowSize <= words.length;
      windowSize++
    ) {
      final window = words.take(windowSize).join(' ');
      for (final drug in drugDictionary) {
        // Cheap pre-filter before paying for a full Levenshtein pass:
        // if the lengths differ by more than ~45%, edit distance can't
        // possibly clear the similarity threshold below anyway, so
        // there's no point computing it. Matters more now than when
        // this was first written — the PNF-EML fallback dictionary is
        // 339 entries (vs. the original ~16-entry list), so skipping
        // obviously-mismatched lengths meaningfully cuts wasted work
        // specifically on the fallback path where the dictionary is
        // largest.
        final lengthDiff = (window.length - drug.length).abs();
        final longerLen = window.length > drug.length
            ? window.length
            : drug.length;
        if (longerLen > 0 && lengthDiff / longerLen > 0.45) continue;

        final score = _similarity(window, drug);
        if (score > bestScore) {
          bestScore = score;
          best = drug;
          if (bestScore >= earlyExitScore) break outer;
        }
      }
    }

    if (best != null) {
      // Short strings need a higher bar — a couple of wrong characters
      // swing the similarity ratio much further on short words.
      //
      // The >5-char bar was 0.72 until it was deliberately lowered to
      // 0.60 here: "Bioguc" (raw OCR) vs. "Biogesic" (real catalog name)
      // scores exactly 0.625 — Levenshtein distance 3 over max length 8,
      // i.e. missing "es" from the middle of the word, a real handwriting
      // misread. At 0.72 that was rejected outright and "Bioguc" was kept
      // as raw, unmatched text — no dictionary correction, no price, no
      // dosage-variant cross-check, nothing. 0.60 catches this specific
      // case with a small margin.
      //
      // The <=5-char bar was 0.82 until it was lowered to 0.78 for the
      // same reason, on the same principle: any fuzzy match should show
      // the catalog's actual spelling, not the raw OCR guess. "Himox" (a
      // real, common brand in this catalog) failed correction TWICE from
      // two different single-letter Groq misreads before this: "Itiniox"
      // and "Timox" (Levenshtein distance 1 — a cursive H read as a T —
      // similarity exactly 0.80). 0.78 catches a single-substitution miss
      // on a 5-letter word like this without opening the door much wider
      // than that.
      //
      // Tradeoff, explicit: both of these are deliberately looser bars
      // chosen to prioritize catching real misreads over rejecting every
      // false-positive edge case — a global fuzzy-match threshold can't
      // distinguish "risky-but-correct" from "risky-and-wrong" without
      // scoring against dictionary CONTEXT (e.g. a nearby dosage/brand
      // that corroborates the guess), which this function doesn't do.
      // Short words are the riskier place to loosen specifically, since
      // more unrelated short words sit close together in edit-distance
      // space than long ones — if an unrelated short OCR fragment starts
      // snapping to the wrong short brand/drug name after this change,
      // that's the first place to look. The fix at that point is smarter
      // corroboration (dosage/brand cross-check), not nudging this number
      // back up, which would just reintroduce cases like this one.
      final threshold = best.length <= 5 ? 0.78 : 0.60;
      if (bestScore >= threshold) {
        return (
          name: best.split(' ').map(_capitalize).join(' '),
          score: bestScore,
        );
      }
    }

    // PASS 2 — FALLBACK ONLY: nothing in the active dictionary matched
    // closely enough on its own, so — and only now — check whether the
    // leading window is a KNOWN abbreviation (see DrugAbbreviations),
    // same 1-3 word windows as above, so "Feso4 Tab #30" / "Fesov Tab"
    // still resolves even though "tab"/"#30" trail behind it on the
    // line. Running this only as a fallback (rather than before the
    // pass above) means a real, already-recognized catalog name always
    // wins over an abbreviation guess — this only fires once we're sure
    // the raw text ISN'T already something the pharmacy stocks under
    // its own name, which is what actually makes it safe to treat as
    // an abbreviation rather than a coincidental short match.
    for (
      int windowSize = 1;
      windowSize <= 3 && windowSize <= words.length;
      windowSize++
    ) {
      final window = words.take(windowSize).join(' ');
      final target = DrugAbbreviations.resolve(window, drugDictionary);
      if (target != null) {
        return (name: target.split(' ').map(_capitalize).join(' '), score: 1.0);
      }
    }

    return (name: null, score: bestScore);
  }

  static double _similarity(String a, String b) {
    final maxLen = a.length > b.length ? a.length : b.length;
    if (maxLen == 0) return 1.0;
    return 1 - (_levenshtein(a, b) / maxLen);
  }

  /// Classic iterative Levenshtein edit distance (two-row DP), O(n*m).
  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    var v0 = List<int>.generate(b.length + 1, (i) => i);
    var v1 = List<int>.filled(b.length + 1, 0);

    for (int i = 0; i < a.length; i++) {
      v1[0] = i + 1;
      for (int j = 0; j < b.length; j++) {
        final cost = a[i] == b[j] ? 0 : 1;
        final deletion = v0[j + 1] + 1;
        final insertion = v1[j] + 1;
        final substitution = v0[j] + cost;
        v1[j + 1] = [
          deletion,
          insertion,
          substitution,
        ].reduce((x, y) => x < y ? x : y);
      }
      final tmp = v0;
      v0 = v1;
      v1 = tmp;
    }
    return v0[b.length];
  }
}
