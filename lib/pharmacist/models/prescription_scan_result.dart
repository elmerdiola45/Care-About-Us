/// A single medicine line item extracted from a prescription.
class PrescriptionMedicine {
  final String name;
  final String dosage;
  final String quantity;
  final String frequency;

  /// Brand name if the prescription itself named one (e.g. "(Himox)"
  /// written above or beside the generic name) — empty if the doctor
  /// only wrote the generic name, which is the common case. When
  /// present, the review screen auto-fills it and the price lookup
  /// uses it directly instead of asking the pharmacist to pick a
  /// brand among several same-dosage SKUs.
  final String brand;

  /// Physical dosage FORM — "Capsule", "Tablet", "Syrup", etc. — as
  /// opposed to [dosage], which is the strength ("500mg"). Parsed
  /// separately from a filler word next to the strength/quantity (see
  /// PrescriptionParserService._dosageFormPattern) so the two pieces of
  /// information ("500mg" vs "Capsule") don't collapse into one string
  /// and can each be compared against the pharmacy's catalog on their
  /// own — e.g. two SKUs can share a strength but differ by form.
  /// Empty if the line didn't carry a recognizable form word.
  final String dosageForm;

  /// Duration of treatment ("7 days", "2 weeks"), parsed from the
  /// Sig: line beneath the drug it belongs to — see
  /// PrescriptionParserService._extractMedicines. Empty if no Sig
  /// line was found/matched for this medicine.
  final String duration;

  /// How confident the local fuzzy-match against the pharmacy's drug
  /// dictionary was that [name] is correct, 0.0-1.0. Drives the
  /// low-confidence UI treatment for this row (e.g. the "verify" flag
  /// in the review screen) — a low score means the name is more likely
  /// an OCR misread than a genuine match.
  final double matchConfidence;

  /// The OCR line(s) this medicine was parsed from, exactly as read —
  /// shown on the review screen as "Read as" so the pharmacist can
  /// compare what the AI read with what was matched.
  final String sourceText;

  /// The vision model's own legibility rating for [sourceText] ('clear',
  /// 'partial', 'unclear'), worst of its lines; empty when unknown (e.g.
  /// OCR.space results, which carry no per-line rating).
  final String sourceLegibility;

  /// The Sig/instruction text attached to this medicine, as read.
  final String sigText;

  /// Empty when [quantity] was written on the prescription. Otherwise a
  /// short explanation of where it came from — an estimate from the Sig
  /// ("1 tab × 2/day × 7 days = 14") or that it wasn't written at all —
  /// so the review screen can ask the pharmacist to confirm it.
  final String quantityBasis;

  bool get quantityEstimated => quantityBasis.isNotEmpty;

  const PrescriptionMedicine({
    required this.name,
    required this.dosage,
    required this.quantity,
    required this.frequency,
    this.brand = '',
    this.dosageForm = '',
    this.duration = '',
    this.matchConfidence = 0.0,
    this.sourceText = '',
    this.sourceLegibility = '',
    this.sigText = '',
    this.quantityBasis = '',
  });

  PrescriptionMedicine copyWith({
    String? quantity,
    String? frequency,
    String? brand,
    String? duration,
    String? sourceText,
    String? sourceLegibility,
    String? sigText,
    String? quantityBasis,
  }) => PrescriptionMedicine(
    name: name,
    dosage: dosage,
    quantity: quantity ?? this.quantity,
    frequency: frequency ?? this.frequency,
    brand: brand ?? this.brand,
    dosageForm: dosageForm,
    duration: duration ?? this.duration,
    matchConfidence: matchConfidence,
    sourceText: sourceText ?? this.sourceText,
    sourceLegibility: sourceLegibility ?? this.sourceLegibility,
    sigText: sigText ?? this.sigText,
    quantityBasis: quantityBasis ?? this.quantityBasis,
  );

  factory PrescriptionMedicine.fromJson(Map<String, dynamic> json) {
    return PrescriptionMedicine(
      name: json['name']?.toString() ?? '',
      dosage: json['dosage']?.toString() ?? '',
      quantity: json['quantity']?.toString() ?? '',
      frequency: json['frequency']?.toString() ?? '',
      brand: json['brand']?.toString() ?? '',
      dosageForm:
          json['dosageForm']?.toString() ??
          json['dosage_form']?.toString() ??
          '',
      duration: json['duration']?.toString() ?? '',
      matchConfidence: (json['matchConfidence'] as num?)?.toDouble() ?? 0.0,
      sourceText: json['sourceText']?.toString() ?? '',
      sourceLegibility: json['sourceLegibility']?.toString() ?? '',
      sigText: json['sigText']?.toString() ?? '',
      quantityBasis: json['quantityBasis']?.toString() ?? '',
    );
  }
}

/// One handwritten line as transcribed by the vision model (Gemini/Groq),
/// with the model's own judgement of what the line is and how sure it
/// was of reading it. [legibility] is 'clear', 'partial' or 'unclear'.
class OcrLine {
  final String text;
  final String section;
  final String legibility;

  const OcrLine({
    required this.text,
    this.section = 'other',
    this.legibility = 'partial',
  });

  bool get isUncertain => legibility != 'clear';

  factory OcrLine.fromJson(Map<String, dynamic> json) => OcrLine(
    text: json['text']?.toString() ?? '',
    section: json['section']?.toString() ?? 'other',
    legibility: json['legibility']?.toString() ?? 'partial',
  );

  /// Parses the backend's `lines` array; anything malformed is skipped,
  /// and a missing/non-list value yields an empty list.
  static List<OcrLine> listFrom(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => OcrLine.fromJson(Map<String, dynamic>.from(e)))
        .where((l) => l.text.trim().isNotEmpty)
        .toList();
  }
}

/// The end-to-end result of scanning a prescription photo: raw OCR text
/// plus whatever structured fields the parser was able to pull out of it.
class PrescriptionScanResult {
  final bool success;
  final String? patientName;

  /// Patient age in years, 0-120, or null when no trustworthy age could
  /// be read from the document. Never a guessed/default value — see
  /// PrescriptionParserService._extractAge, which only ever returns a
  /// value it actually found and bounds-checked, so a null here means
  /// exactly what it says: not recorded, not "assume zero".
  final int? patientAge;

  /// Patient sex as a normalized 'M' or 'F', or null when not found.
  /// Same "null means unknown, never guessed" contract as [patientAge].
  final String? patientGender;
  final String? doctorName;
  final List<PrescriptionMedicine> medicines;
  final String rawText;

  /// Per-line transcription with section/legibility, when the engine
  /// provides it (Gemini/Groq). Empty for OCR.space results.
  final List<OcrLine> ocrLines;
  final String? error;

  /// Which engine produced this result — useful for debugging/QA.
  /// e.g. 'ocrspace+parser' (normal path) or 'ocrspace' (OCR failed before
  /// parsing ever ran).
  final String engineUsed;

  /// True when [error] looks like the free-tier OCR.space quota/rate
  /// limit being hit rather than a bad photo — the scan screen uses
  /// this to show "try again later" instead of "retake the photo".
  final bool isQuotaExceeded;

  const PrescriptionScanResult({
    required this.success,
    this.patientName,
    this.patientAge,
    this.patientGender,
    this.doctorName,
    this.medicines = const [],
    this.rawText = '',
    this.ocrLines = const [],
    this.error,
    this.engineUsed = 'ocrspace',
    this.isQuotaExceeded = false,
  });
}
