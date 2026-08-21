import 'package:flutter/foundation.dart';

enum AlertType { overDispense, earlyRefill, duplicateDispense, crossPharmacyDuplicate, crossPharmacyDispense }

enum AlertPriority { normal, high }

@immutable
class DispenseAlert {
  final String alertId;
  final AlertType alertType;
  final AlertPriority priority;
  final String? rxNumber;
  final String? patientId;
  final String? prescriptionId;
  final String? attemptingPharmacyId;
  final String? originalPharmacyId;
  final String? attemptedBy;
  final String note;
  final bool resolved;
  final DateTime createdAt;
  final DateTime? resolvedAt;

  const DispenseAlert({
    required this.alertId,
    required this.alertType,
    required this.priority,
    this.rxNumber,
    this.patientId,
    this.prescriptionId,
    this.attemptingPharmacyId,
    this.originalPharmacyId,
    this.attemptedBy,
    required this.note,
    required this.resolved,
    required this.createdAt,
    this.resolvedAt,
  });

  factory DispenseAlert.fromJson(Map<String, dynamic> json) {
    return DispenseAlert(
      alertId: json['alert_id']?.toString() ?? json['alertId']?.toString() ?? '',
      alertType: _parseAlertType(json['alert_type']?.toString() ?? json['alertType']?.toString() ?? ''),
      priority: _parsePriority(json['priority']?.toString() ?? 'normal'),
      rxNumber: json['rx_number']?.toString() ?? json['rxNumber']?.toString(),
      patientId: json['patient_id']?.toString() ?? json['patientId']?.toString(),
      prescriptionId: json['prescription_id']?.toString() ?? json['prescriptionId']?.toString(),
      attemptingPharmacyId: json['attempting_pharmacy_id']?.toString() ?? json['attemptingPharmacyId']?.toString(),
      originalPharmacyId: json['original_pharmacy_id']?.toString() ?? json['originalPharmacyId']?.toString(),
      attemptedBy: json['attempted_by']?.toString() ?? json['attemptedBy']?.toString(),
      note: json['note']?.toString() ?? '',
      resolved: json['resolved'] is bool ? json['resolved'] as bool : false,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at']?.toString() ?? '') ?? DateTime.now()
          : DateTime.now(),
      resolvedAt: json['resolved_at'] != null
          ? DateTime.tryParse(json['resolved_at']?.toString() ?? '')
          : null,
    );
  }

  static AlertType _parseAlertType(String value) {
    switch (value.toLowerCase()) {
      case 'over_dispense':
        return AlertType.overDispense;
      case 'early_refill':
        return AlertType.earlyRefill;
      case 'duplicate_dispense':
        return AlertType.duplicateDispense;
      case 'cross_pharmacy_duplicate':
        return AlertType.crossPharmacyDuplicate;
      case 'cross_pharmacy_dispense':
        return AlertType.crossPharmacyDispense;
      default:
        return AlertType.overDispense;
    }
  }

  static AlertPriority _parsePriority(String value) {
    switch (value.toLowerCase()) {
      case 'high':
        return AlertPriority.high;
      default:
        return AlertPriority.normal;
    }
  }

  String get title {
    switch (alertType) {
      case AlertType.overDispense:
        return 'Over-Dispense Alert';
      case AlertType.earlyRefill:
        return 'Early Refill Warning';
      case AlertType.duplicateDispense:
        return 'Duplicate Dispense Alert';
      case AlertType.crossPharmacyDuplicate:
        return 'Cross-Pharmacy Duplicate Alert';
      case AlertType.crossPharmacyDispense:
        return 'Cross-Pharmacy Dispense Request';
    }
  }

  String get description {
    switch (alertType) {
      case AlertType.overDispense:
        return note;
      case AlertType.earlyRefill:
        return note;
      case AlertType.duplicateDispense:
        return 'This prescription has already been fully dispensed.';
      case AlertType.crossPharmacyDuplicate:
        return 'Duplicate dispense attempt from a different pharmacy. Possible fraud risk.';
      case AlertType.crossPharmacyDispense:
        return note;
    }
  }
}
