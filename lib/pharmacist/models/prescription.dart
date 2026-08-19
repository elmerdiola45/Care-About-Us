// prescription.dart
import 'package:flutter/foundation.dart';

enum QrStatus { pendingQr, qrGenerated }

enum DispensingStatus {
  pending,
  partiallyDispensed,
  fullyDispensed,
  overDispensing,
}

@immutable
class MedicineItem {
  final String name;
  final String originalOcrName;
  final String genericName;
  final String brand;
  final String dosage;
  final int quantity;
  final int disposedQuantity;
  final double unitPrice;
  final bool isEssential;
  final String duration;
  final int daysSupply;

  /// Live stock remaining for this medicine at the dispensing pharmacy —
  /// see LaravelPrescriptionItem.availableStock. Null means "not tracked
  /// in inventory," which the dispense screen treats as unconstrained
  /// rather than as zero.
  final int? availableStock;

  const MedicineItem({
    required this.name,
    this.originalOcrName = '',
    this.genericName = '',
    this.brand = '',
    required this.dosage,
    required this.quantity,
    this.disposedQuantity = 0,
    this.unitPrice = 0.0,
    this.isEssential = true,
    this.duration = '',
    this.daysSupply = 0,
    this.availableStock,
  });

  MedicineItem copyWith({
    String? name,
    String? originalOcrName,
    String? genericName,
    String? brand,
    String? dosage,
    int? quantity,
    int? disposedQuantity,
    double? unitPrice,
    bool? isEssential,
    String? duration,
    int? daysSupply,
    int? availableStock,
  }) {
    return MedicineItem(
      name: name ?? this.name,
      originalOcrName: originalOcrName ?? this.originalOcrName,
      genericName: genericName ?? this.genericName,
      brand: brand ?? this.brand,
      dosage: dosage ?? this.dosage,
      quantity: quantity ?? this.quantity,
      disposedQuantity: disposedQuantity ?? this.disposedQuantity,
      unitPrice: unitPrice ?? this.unitPrice,
      isEssential: isEssential ?? this.isEssential,
      duration: duration ?? this.duration,
      daysSupply: daysSupply ?? this.daysSupply,
      availableStock: availableStock ?? this.availableStock,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is MedicineItem &&
        other.name == name &&
        other.brand == brand &&
        other.dosage == dosage &&
        other.quantity == quantity &&
        other.disposedQuantity == disposedQuantity &&
        other.unitPrice == unitPrice &&
        other.isEssential == isEssential &&
        other.duration == duration &&
        other.daysSupply == daysSupply;
  }

  @override
  int get hashCode => Object.hash(
    name,
    brand,
    dosage,
    quantity,
    disposedQuantity,
    unitPrice,
    isEssential,
    duration,
    daysSupply,
  );
}

@immutable
class Prescription {
  final String patientName;
  final int patientAge;
  final String patientGender;
  final bool isSenior;
  final String? oscaId;
  final String doctorName;
  final String licenseNo;
  final String ptNo;
  final String s2;
  final String? patientAddress;
  final String? diagnosis;
  final String ocrCode;
  final String pharmacyId;
  final DateTime dateTime;
  final List<MedicineItem> medicines;
  final double totalPrice;
  final QrStatus status;
  final DispensingStatus dispensingStatus;
  final Uint8List? imageBytes;

  const Prescription({
    required this.patientName,
    required this.patientAge,
    required this.patientGender,
    this.isSenior = false,
    this.oscaId,
    required this.doctorName,
    this.licenseNo = '',
    this.ptNo = '',
    this.s2 = '',
    this.patientAddress,
    this.diagnosis,
    required this.ocrCode,
    this.pharmacyId = '',
    required this.dateTime,
    required this.medicines,
    required this.totalPrice,
    required this.status,
    this.dispensingStatus = DispensingStatus.pending,
    this.imageBytes,
  });

  Prescription copyWith({
    String? patientName,
    int? patientAge,
    String? patientGender,
    bool? isSenior,
    String? oscaId,
    String? doctorName,
    String? licenseNo,
    String? ptNo,
    String? s2,
    String? patientAddress,
    String? diagnosis,
    String? ocrCode,
    String? pharmacyId,
    DateTime? dateTime,
    List<MedicineItem>? medicines,
    double? totalPrice,
    QrStatus? status,
    DispensingStatus? dispensingStatus,
    Uint8List? imageBytes,
  }) {
    return Prescription(
      patientName: patientName ?? this.patientName,
      patientAge: patientAge ?? this.patientAge,
      patientGender: patientGender ?? this.patientGender,
      isSenior: isSenior ?? this.isSenior,
      oscaId: oscaId ?? this.oscaId,
      doctorName: doctorName ?? this.doctorName,
      licenseNo: licenseNo ?? this.licenseNo,
      ptNo: ptNo ?? this.ptNo,
      s2: s2 ?? this.s2,
      patientAddress: patientAddress ?? this.patientAddress,
      diagnosis: diagnosis ?? this.diagnosis,
      ocrCode: ocrCode ?? this.ocrCode,
      pharmacyId: pharmacyId ?? this.pharmacyId,
      dateTime: dateTime ?? this.dateTime,
      medicines: medicines ?? this.medicines,
      totalPrice: totalPrice ?? this.totalPrice,
      status: status ?? this.status,
      dispensingStatus: dispensingStatus ?? this.dispensingStatus,
      imageBytes: imageBytes ?? this.imageBytes,
    );
  }
}
