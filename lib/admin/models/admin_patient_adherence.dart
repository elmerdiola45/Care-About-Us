import 'package:flutter/foundation.dart';
import 'admin_models.dart';

enum AdherenceTier { good, atRisk, critical, overDispensing, fullyDispensed }

AdherenceTier tierForScore(int score) {
  if (score >= 80) return AdherenceTier.good;
  if (score >= 50) return AdherenceTier.atRisk;
  return AdherenceTier.critical;
}

AdherenceTier tierForStatus(String? status, int score) {
  final s = (status ?? '').toLowerCase();
  switch (s) {
    case 'good':
      return AdherenceTier.good;
    case 'at_risk':
    case 'atRisk':
      return AdherenceTier.atRisk;
    case 'partially_dispensed':
    case 'partiallyDispensed':
      return AdherenceTier.atRisk;
    case 'pending':
    case 'no_data':
    case 'critical':
      return AdherenceTier.critical;
    case 'overdispensing':
    case 'over_dispensing':
      return AdherenceTier.overDispensing;
    case 'fully_dispensed':
    case 'fullyDispensed':
      return AdherenceTier.fullyDispensed;
    default:
      return tierForScore(score);
  }
}

int parseAdherenceScore(Map<String, dynamic> json) {
  final status = json['adherence_status']?.toString() ?? json['status']?.toString();
  final statusLower = (status ?? '').toLowerCase();
  if (statusLower == 'fully_dispensed' || statusLower == 'fullydispensed') {
    return 100;
  }
  if (json['is_fully_dispensed'] == true ||
      json['fully_dispensed'] == true ||
      json['is_completed'] == true) {
    return 100;
  }

  final backendScore = json['adherence_percent'] ??
      json['adherencePercent'] ??
      json['adherence_score'] ??
      json['adherenceScore'] ??
      json['score'] ??
      json['adherence_percentage'] ??
      json['adherencePercentage'] ??
      json['percentage'] ??
      json['compliance_score'] ??
      json['complianceScore'] ??
      json['adherence_rate'] ??
      json['adherenceRate'] ??
      json['compliance_rate'] ??
      json['complianceRate'] ??
      json['fill_rate'] ??
      json['fillRate'] ??
      json['medication_adherence'] ??
      json['medicationAdherence'];
  if (backendScore != null) {
    final parsed = switch (backendScore) {
      num() => backendScore.toDouble(),
      String() => double.tryParse(backendScore) ?? 0.0,
      _ => 0.0,
    };
    if (parsed > 0 && parsed <= 1.0) return (parsed * 100).round();
    return parsed.clamp(0, 100).toInt();
  }

  final totals = _medicationTotals(json);
  if (totals.prescribed > 0) {
    final percentage = (totals.dispensed / totals.prescribed) * 100;
    return percentage.round().clamp(0, 100);
  }

  final fuzzyCandidates = <String, dynamic>{};
  for (final entry in json.entries) {
    final key = entry.key.toLowerCase();
    if (key.contains('percent') ||
        key.contains('score') ||
        key.contains('rate') ||
        key.contains('level') ||
        key.contains('fill') ||
        key.contains('dispense') ||
        key.contains('medication') ||
        key.contains('adherence') ||
        key.contains('compliance')) {
      fuzzyCandidates[entry.key] = entry.value;
    }
  }
  for (final entry in fuzzyCandidates.entries) {
    final value = entry.value;
    if (value == null) continue;
    final parsed = switch (value) {
      num() => value.toDouble(),
      String() => double.tryParse(value.toString()) ?? 0.0,
      _ => 0.0,
    };
    if (parsed > 0 && parsed <= 100) {
      debugPrint('parseAdherenceScore fuzzy match: key=${entry.key} value=$parsed');
      return parsed.toInt();
    }
  }

  final allValues = json.values.where((v) => v != null).toList();
  for (final v in allValues) {
    final str = v.toString();
    final match = RegExp(r'(\d+(?:\.\d+)?)\s*%').firstMatch(str);
    if (match != null) {
      final extracted = double.tryParse(match.group(1)!);
      if (extracted != null && extracted > 0 && extracted <= 100) {
        return extracted.round();
      }
    }
  }

  return 0;
}

({int prescribed, int dispensed}) _medicationTotals(Map<String, dynamic> json) {
  final medications = safeList(json['medications'] ?? json['items']);
  int totalPrescribed = 0;
  int totalDispensed = 0;
  for (final m in medications) {
    final mm = m is Map ? m : null;
    if (mm == null) continue;
    totalPrescribed += safeInt(mm['quantity'] ??
        mm['prescribed_quantity'] ??
        mm['prescribedQuantity'] ??
        mm['initial_quantity'] ??
        mm['initialQuantity'] ??
        mm['qty'] ??
        mm['quantity_prescribed'] ??
        mm['quantityPrescribed'] ??
        mm['amount'] ??
        mm['stock'] ??
        mm['total_quantity'] ??
        mm['totalQuantity']);
    totalDispensed += safeInt(mm['disposed_quantity'] ??
        mm['disposedQuantity'] ??
        mm['dispensed_quantity'] ??
        mm['dispensedQuantity'] ??
        mm['quantity_dispensed'] ??
        mm['quantityDispensed'] ??
        mm['qty_dispensed'] ??
        mm['qtyDispensed'] ??
        mm['served'] ??
        mm['quantity_served'] ??
        mm['quantityServed'] ??
        mm['given'] ??
        mm['amount_given'] ??
        mm['amountGiven']);
  }
  return (prescribed: totalPrescribed, dispensed: totalDispensed);
}

class RefillEvent {
  final DateTime date;
  final bool onTime;
  final int? daysLate;
  final String medicineName;
  final int quantity;
  final bool isFlagged;
  final DateTime? expectedNextFill;

  const RefillEvent({
    required this.date,
    required this.onTime,
    this.daysLate,
    this.medicineName = '',
    this.quantity = 0,
    this.isFlagged = false,
    this.expectedNextFill,
  });

  factory RefillEvent.fromJson(Map<String, dynamic> json) {
    final rawDate = json['date']?.toString() ?? json['filled_at']?.toString() ?? json['dispensed_at']?.toString();
    final onTimeRaw = json['on_time'] ?? json['onTime'];
    final onTime = onTimeRaw is bool
        ? onTimeRaw
        : onTimeRaw?.toString().toLowerCase() == 'true' || onTimeRaw == 1;
    final daysLateRaw = json['days_late'] ?? json['daysLate'];
    final daysLate = daysLateRaw is int ? daysLateRaw : int.tryParse('${daysLateRaw ?? 0}');
    final qtyRaw = json['quantity'] ?? json['quantity_served'];
    final quantity = qtyRaw is int ? qtyRaw : int.tryParse('${qtyRaw ?? 0}') ?? 0;
    final flaggedRaw = json['is_flagged'] ?? json['flagged'];
    final isFlagged = flaggedRaw is bool
        ? flaggedRaw
        : flaggedRaw?.toString().toLowerCase() == 'true' || flaggedRaw == 1;
    final expectedNextFillRaw = json['expected_next_fill']?.toString() ??
        json['expectedNextFill']?.toString();

    return RefillEvent(
      date: rawDate != null ? DateTime.tryParse(rawDate) ?? DateTime.now() : DateTime.now(),
      onTime: onTime,
      daysLate: daysLate,
      medicineName: json['medicine_name']?.toString() ?? json['name']?.toString() ?? json['product_name']?.toString() ?? '',
      quantity: quantity,
      isFlagged: isFlagged,
      expectedNextFill: expectedNextFillRaw != null
          ? DateTime.tryParse(expectedNextFillRaw)
          : null,
    );
  }

  bool get isOverdue => !onTime && (daysLate ?? 0) > 0;

  Map<String, dynamic> toJson() {
    return {
      'date': date.toIso8601String(),
      'on_time': onTime,
      'days_late': daysLate,
      'medicine_name': medicineName,
      'quantity': quantity,
      'is_flagged': isFlagged,
      'expected_next_fill': expectedNextFill?.toIso8601String(),
    };
  }
}

class AdminPatientAdherenceRecord {
  final String patientId;
  final String id;
  final String name;
  final int age;
  final String sex;
  final DateTime lastFill;
  final List<MedicationInfo> medications;
  final int adherenceScore;
  final String? adherenceStatus;
  final String? prescriptionId;
  final String? doctorName;
  final List<RefillEvent> refillHistory;
  bool isLocked;
  String? lockReason;

  AdminPatientAdherenceRecord({
    required this.patientId,
    required this.id,
    required this.name,
    required this.age,
    required this.sex,
    required this.lastFill,
    required this.medications,
    required this.adherenceScore,
    this.adherenceStatus,
    this.prescriptionId,
    this.doctorName,
    required this.refillHistory,
    this.isLocked = false,
    this.lockReason,
  });

  AdherenceTier get tier => tierForStatus(adherenceStatus, adherenceScore);

  bool get hasOverdueRefill => refillHistory.any((e) => e.isOverdue);

  String get initials => name
      .trim()
      .split(RegExp(r'\s+'))
      .map((w) => w.isNotEmpty ? w[0] : '')
      .take(2)
      .join()
      .toUpperCase();
}

class AdminPatientAdherenceStore extends ChangeNotifier {
  AdminPatientAdherenceStore._();
  static final AdminPatientAdherenceStore instance = AdminPatientAdherenceStore._();

  final List<AdminPatientAdherenceRecord> _patients = [];

  List<AdminPatientAdherenceRecord> get patients => List.unmodifiable(_patients);

  void lockPrescription(String patientId, {String reason = 'Over-dispensing detected'}) {
    try {
      final patient = _patients.firstWhere((p) => p.id == patientId);
      patient.isLocked = true;
      patient.lockReason = reason;
      notifyListeners();
    } on StateError {
      return;
    }
  }

  void unlockPrescription(String patientId) {
    try {
      final patient = _patients.firstWhere((p) => p.id == patientId);
      patient.isLocked = false;
      patient.lockReason = null;
      notifyListeners();
    } on StateError {
      return;
    }
  }
}
