/// A single medicine line item as shown on the OCR review screen
/// ([OcrResultScreen]) once it has been matched against the pharmacy's
/// dictionary and priced — the display/pricing counterpart to
/// [PrescriptionMedicine] in prescription_scan_result.dart, which
/// carries the raw parser output instead.
class PricedMedicine {
  final String name;
  final String dosage;
  final int quantity;

  /// Unit price for one tablet/capsule/dose, as looked up from the
  /// pharmacy's priced inventory (see MedicineDictionaryService /
  /// PriceLookupService) — 0 if no price could be resolved yet.
  final double pricePerTab;

  const PricedMedicine({
    required this.name,
    required this.dosage,
    required this.quantity,
    this.pricePerTab = 0,
  });

  /// Line total for this medicine (quantity × unit price).
  double get total => quantity * pricePerTab;

  factory PricedMedicine.fromJson(Map<String, dynamic> json) {
    return PricedMedicine(
      name: json['name']?.toString() ?? '',
      dosage: json['dosage']?.toString() ?? '',
      quantity: (json['quantity'] as num?)?.toInt() ?? 0,
      pricePerTab: (json['pricePerTab'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'dosage': dosage,
    'quantity': quantity,
    'pricePerTab': pricePerTab,
  };
}

/// The scanned-and-priced prescription shown on [OcrResultScreen] for
/// pharmacist review before it's saved — the fields a pharmacist can
/// edit (doctor, date, patient, diagnosis) plus the auto-generated,
/// MDRP-style price list built from [medicines].
class ExtractedPrescription {
  final String doctorName;
  final String doctorLicense;
  final String date;
  final String patientName;
  final String diagnosis;
  final List<PricedMedicine> medicines;

  const ExtractedPrescription({
    required this.doctorName,
    required this.doctorLicense,
    required this.date,
    required this.patientName,
    required this.diagnosis,
    this.medicines = const [],
  });

  /// Sum of every line item's [PricedMedicine.total] — the "Total"
  /// figure shown at the bottom of the price list. Not stored
  /// separately so it can never drift out of sync with [medicines].
  double get total =>
      medicines.fold(0.0, (sum, medicine) => sum + medicine.total);

  factory ExtractedPrescription.fromJson(Map<String, dynamic> json) {
    return ExtractedPrescription(
      doctorName: json['doctorName']?.toString() ?? '',
      doctorLicense: json['doctorLicense']?.toString() ?? '',
      date: json['date']?.toString() ?? '',
      patientName: json['patientName']?.toString() ?? '',
      diagnosis: json['diagnosis']?.toString() ?? '',
      medicines: (json['medicines'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(PricedMedicine.fromJson)
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'doctorName': doctorName,
    'doctorLicense': doctorLicense,
    'date': date,
    'patientName': patientName,
    'diagnosis': diagnosis,
    'medicines': medicines.map((m) => m.toJson()).toList(),
  };
}
