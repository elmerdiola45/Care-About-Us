import 'package:flutter/foundation.dart';

enum AdherenceTier { good, atRisk, critical, overDispensing, fullyDispensed }

bool _safeBool(dynamic value, [bool fallback = false]) {
  if (value == null) return fallback;
  if (value is bool) return value;
  if (value is int) return value != 0;
  if (value is num) return value.toInt() != 0;
  final str = value.toString().toLowerCase().trim();
  if (str == 'true' || str == '1') return true;
  if (str == 'false' || str == '0') return false;
  return fallback;
}

List<dynamic> _safeList(dynamic value) {
  if (value is List) return List<dynamic>.from(value);
  return const [];
}

int _safeInt(dynamic value, [int fallback = 0]) {
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is num) return value.toInt();
  final str = value.toString().trim();
  if (str.isEmpty) return fallback;
  final d = double.tryParse(str);
  if (d != null) return d.toInt();
  return int.tryParse(str) ?? fallback;
}

int? _toInt(dynamic value) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is num) return value.toInt();
  final str = value.toString().trim();
  if (str.isEmpty) return null;
  final d = double.tryParse(str);
  if (d != null) return d.toInt();
  return int.tryParse(str);
}

int? _toPositiveInt(dynamic value) {
  final result = _toInt(value);
  return result != null && result > 0 ? result : null;
}

int _safePositiveIntFromMap(Map<String, dynamic>? map, List<String> keys, [int fallback = 0]) {
  if (map == null) return fallback;
  for (final key in keys) {
    final value = map[key];
    if (value == null) continue;
    final parsed = _toPositiveInt(value);
    if (parsed != null) return parsed;
  }
  return fallback;
}

int _safeIntFromMap(Map<String, dynamic>? map, List<String> keys, [int fallback = 0]) {
  if (map == null) return fallback;
  for (final key in keys) {
    final value = map[key];
    if (value == null) continue;
    final parsed = _toInt(value);
    if (parsed != null) return parsed;
  }
  return fallback;
}

int _safePositiveIntFromAnyKey(Map<String, dynamic>? map, [int fallback = 0]) {
  if (map == null) return fallback;
  for (final entry in map.entries) {
    final value = entry.value;
    if (value == null) continue;
    if (value is String && value.toString().trim().isEmpty) continue;
    if (value is bool) continue;
    if (value is Map || value is List) continue;
    final parsed = _toPositiveInt(value);
    if (parsed != null) {
      debugPrint('FALLBACK initial key=${entry.key} value=$value parsed=$parsed');
      return parsed;
    }
  }
  return fallback;
}

AdherenceTier tierFor(String? status) {
  switch ((status ?? '').toLowerCase()) {
    case 'good':
      return AdherenceTier.good;
    case 'at_risk':
      return AdherenceTier.atRisk;
    case 'critical':
      return AdherenceTier.critical;
    case 'overdispensing':
    case 'over_dispensing':
      return AdherenceTier.overDispensing;
    case 'fully_dispensed':
      return AdherenceTier.fullyDispensed;
    default:
      return AdherenceTier.good;
  }
}

@immutable
class AdherenceStatus {
  final String status;
  final String reason;
  final DateTime lastCalculatedAt;
  final int score;
  final bool hasData;
  final bool hasHistory;
  final List<String> medicationNames;
  final List<AdherenceHistoryItem> refillHistory;

  const AdherenceStatus({
    required this.status,
    required this.reason,
    required this.lastCalculatedAt,
    this.score = 0,
    this.hasData = true,
    this.hasHistory = false,
    this.medicationNames = const [],
    this.refillHistory = const [],
  });

  factory AdherenceStatus.fromJson(Map<String, dynamic> json) {
    final score = _safeInt(json['adherence_percent'] ?? json['adherencePercent'] ?? json['adherence_score'] ?? json['adherenceScore'] ?? json['adherence_percentage'] ?? json['adherencePercentage'] ?? json['score'] ?? json['percentage'], 0);
    final apiStatus = (json['status']?.toString() ?? json['adherence_status']?.toString() ?? 'no_data').toLowerCase();
    final apiStatusLabel = json['status_label']?.toString() ?? json['statusLabel']?.toString();
    final apiStatusNote = json['status_note']?.toString() ?? json['statusNote']?.toString();
     final apiFullyDispensed = _safeBool(json['fully_dispensed'] ?? json['fullyDispensed']);

    final meds = _safeList(json['medications'] ?? json['items'] ?? json['medication_details'] ?? json['medicine_list'] ?? json['prescription_items'] ?? json['drugs'] ?? json['medicine']);
    final medicationNames = <String>[];
    int totalPrescribed = 0;
    int totalDispensed = 0;
    for (final m in meds) {
      if (m is String) {
        if (m.isNotEmpty && !medicationNames.contains(m)) medicationNames.add(m);
        continue;
      }
      final mm = m is Map ? Map<String, dynamic>.from(m) : null;
      if (mm == null) continue;
      final medName = mm['medicine_name']?.toString() ?? mm['name']?.toString() ?? mm['medicineName']?.toString() ?? mm['product_name']?.toString() ?? mm['productName']?.toString() ?? mm['drug_name']?.toString() ?? mm['drugName']?.toString() ?? mm['drug']?.toString();
      if (medName != null && medName.isNotEmpty && !medicationNames.contains(medName)) {
        medicationNames.add(medName);
      }
      totalPrescribed += _safePositiveIntFromMap(mm, [
        'total_prescribed_quantity',
        'totalPrescribedQuantity',
        'initial_quantity',
        'initialQuantity',
        'quantity',
        'prescribed_quantity',
        'prescribedQuantity',
        'qty',
        'stock',
        'total_quantity',
        'totalQuantity',
        'amount',
        'ordered_quantity',
        'orderedQuantity',
        'requested_quantity',
        'requestedQuantity',
      ]);
      totalDispensed += _safeIntFromMap(mm, [
        'total_dispensed_quantity',
        'totalDispensedQuantity',
        'disposed_quantity',
        'dispensed_quantity',
        'dispensedQuantity',
        'quantity_dispensed',
        'quantityDispensed',
        'qty_dispensed',
        'qtyDispensed',
        'served',
        'quantity_served',
        'quantityServed',
        'given',
        'amount_given',
        'amountGiven',
      ]);
    }

    String effectiveStatus = apiFullyDispensed ? 'fully_dispensed' : apiStatus;
    int effectiveScore = score;
    String effectiveReason = apiStatusLabel ?? apiStatusNote ?? json['reason']?.toString() ?? '';

    if (totalPrescribed > 0) {
      if (totalDispensed > totalPrescribed) {
        effectiveStatus = 'over_dispensing';
        effectiveScore = 100;
        effectiveReason = effectiveReason.isEmpty ? 'Over-dispensing detected.' : effectiveReason;
      } else if (totalDispensed == totalPrescribed) {
        effectiveStatus = 'fully_dispensed';
        effectiveScore = 100;
        effectiveReason = effectiveReason.isEmpty ? 'All prescriptions fully dispensed.' : effectiveReason;
      }
    }

    final hasStatus = json['status'] != null || json['adherence_status'] != null;
    final hasScore = json['adherence_percent'] != null ||
        json['adherencePercent'] != null ||
        json['adherence_score'] != null ||
        json['adherenceScore'] != null ||
        json['adherence_percentage'] != null ||
        json['adherencePercentage'] != null ||
        json['score'] != null ||
        json['percentage'] != null;
    final hasHistory = _safeBool(json['has_history'] ?? json['hasHistory'] ?? json['has_data'] ?? json['hasData'] ?? false);
    final hasReason = effectiveReason.isNotEmpty;
    final hasScoreData = hasStatus || hasScore;
    final effectiveHasHistory = hasHistory || hasReason || hasScoreData;

    final refillHistoryRaw = json['refill_history'] ?? json['refillHistory'] ?? json['dispensing_history'] ?? json['dispensingHistory'] ?? json['dispensing_logs'] ?? json['dispensingLogs'] ?? json['history'] ?? json['records'] ?? json['fill_history'] ?? json['fillHistory'] ?? json['medication_history'] ?? json['medicationHistory'];
    final refillHistorySource = refillHistoryRaw is List
        ? refillHistoryRaw
        : (refillHistoryRaw is Map ? _safeList(refillHistoryRaw['data'] ?? refillHistoryRaw['items'] ?? refillHistoryRaw['records']) : []);

    // Also check for history nested inside individual medication items
    final nestedHistoryItems = <dynamic>[];
    for (final m in meds) {
      if (m is! Map) continue;
      final mm = Map<String, dynamic>.from(m);
      for (final histKey in ['refill_history', 'refillHistory', 'dispensing_history', 'dispensingHistory', 'dispensing_logs', 'dispensingLogs', 'history', 'logs']) {
        final nested = mm[histKey];
        if (nested is List) {
          nestedHistoryItems.addAll(nested);
        } else if (nested is Map) {
          nestedHistoryItems.addAll(_safeList(nested['data'] ?? nested['items'] ?? nested['records']));
        }
      }
    }

    final allHistorySource = [...refillHistorySource, ...nestedHistoryItems];
    final refillHistory = allHistorySource
        .map((e) {
          if (e is Map) return AdherenceHistoryItem.fromJson(Map<String, dynamic>.from(e));
          if (e is AdherenceHistoryItem) return e;
          return null;
        })
        .whereType<AdherenceHistoryItem>()
        .toList();

    return AdherenceStatus(
      status: effectiveStatus,
      reason: effectiveReason,
      lastCalculatedAt: json['last_calculated_at'] != null
          ? DateTime.tryParse(json['last_calculated_at']?.toString() ?? '') ?? DateTime.now()
          : DateTime.now(),
      score: effectiveScore,
      hasData: hasStatus || hasScore,
      hasHistory: effectiveHasHistory,
      medicationNames: medicationNames,
      refillHistory: refillHistory,
    );
  }

  AdherenceStatus copyWith({
    String? status,
    String? reason,
    DateTime? lastCalculatedAt,
    int? score,
    bool? hasData,
    bool? hasHistory,
    List<String>? medicationNames,
    List<AdherenceHistoryItem>? refillHistory,
  }) {
    return AdherenceStatus(
      status: status ?? this.status,
      reason: reason ?? this.reason,
      lastCalculatedAt: lastCalculatedAt ?? this.lastCalculatedAt,
      score: score ?? this.score,
      hasData: hasData ?? this.hasData,
      hasHistory: hasHistory ?? this.hasHistory,
      medicationNames: medicationNames ?? this.medicationNames,
      refillHistory: refillHistory ?? this.refillHistory,
    );
  }

  AdherenceTier get tier => hasData ? tierFor(status) : AdherenceTier.good;

  static AdherenceStatus noData() {
    return AdherenceStatus(
      status: 'good',
      reason: 'No dispensing history yet.',
      lastCalculatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      score: 0,
      hasData: false,
      hasHistory: false,
    );
  }
}

@immutable
class AdherenceHistoryItem {
  final String logId;
  final String prescriptionId;
  final String medicineName;
  final int quantityServed;
  final DateTime dispensedAt;
  final String pharmacyId;
  final String dispenserId;
  final int daysSupply;
  final DateTime? expectedNextFill;
  final String? flag;
  final int initialQuantity;
  final int dispensedQuantity;
  final int remainingQuantity;
  final bool fullyDispensed;

  const AdherenceHistoryItem({
    required this.logId,
    required this.prescriptionId,
    required this.medicineName,
    required this.quantityServed,
    required this.dispensedAt,
    required this.pharmacyId,
    required this.dispenserId,
    required this.daysSupply,
    this.expectedNextFill,
    this.flag,
    this.initialQuantity = 0,
    this.dispensedQuantity = 0,
    this.remainingQuantity = 0,
    this.fullyDispensed = false,
  });

  factory AdherenceHistoryItem.fromJson(Map<String, dynamic> json) {
    final initial = _safePositiveIntFromMap(json, [
      'total_prescribed_quantity',
      'totalPrescribedQuantity',
      'initial_quantity',
      'initialQuantity',
      'quantity',
      'prescribed_quantity',
      'prescribedQuantity',
      'qty',
      'stock',
      'total_quantity',
      'totalQuantity',
      'amount',
      'ordered_quantity',
      'orderedQuantity',
      'requested_quantity',
      'requestedQuantity',
    ]);
    final dispensed = _safeIntFromMap(json, [
      'total_dispensed_quantity',
      'totalDispensedQuantity',
      'disposed_quantity',
      'dispensed_quantity',
      'dispensedQuantity',
      'quantity_dispensed',
      'quantityDispensed',
      'qty_dispensed',
      'qtyDispensed',
      'served',
      'quantity_served',
      'quantityServed',
      'given',
      'amount_given',
      'amountGiven',
    ]);
    final remaining = _safeIntFromMap(json, [
      'remaining_quantity',
      'remainingQuantity',
      'remaining_qty',
      'remainingQty',
    ]);
    final fallbackInitial = initial == 0 ? _safePositiveIntFromAnyKey(json) : 0;
    final computedRemaining = (initial > 0 ? initial : fallbackInitial) > 0 ? ((initial > 0 ? initial : fallbackInitial) - dispensed).clamp(0, initial > 0 ? initial : fallbackInitial) : remaining;
    final fullyDispensed = json['fully_dispensed'] == true || json['fullyDispensed'] == true ||
        ((initial > 0 ? initial : fallbackInitial) > 0 && computedRemaining <= 0 && dispensed > 0);

    return AdherenceHistoryItem(
      logId: json['log_id']?.toString() ?? json['logId']?.toString() ?? '',
      prescriptionId: json['prescription_id']?.toString() ?? json['prescriptionId']?.toString() ?? '',
      medicineName: json['medicine_name']?.toString() ?? json['name']?.toString() ?? json['product_name']?.toString() ?? json['medicineName']?.toString() ?? json['drug_name']?.toString() ?? json['drugName']?.toString() ?? json['productName']?.toString() ?? '',
      quantityServed: int.tryParse('${json['quantity_served'] ?? json['quantityServed'] ?? json['served'] ?? json['dispensed_quantity'] ?? json['dispensedQuantity'] ?? json['quantity'] ?? json['qty'] ?? json['dispensed'] ?? 0}') ?? 0,
      dispensedAt: (() {
        final rawDate = json['dispensed_at']?.toString() ??
            json['filled_at']?.toString() ??
            json['date']?.toString();
        return rawDate != null ? DateTime.tryParse(rawDate) ?? DateTime.now() : DateTime.now();
      })(),
      pharmacyId: json['pharmacy_id']?.toString() ?? json['pharmacyId']?.toString() ?? '',
      dispenserId: json['dispenser_id']?.toString() ?? json['dispenserId']?.toString() ?? '',
      daysSupply: int.tryParse('${json['days_supply'] ?? json['daysSupply'] ?? 0}') ?? 0,
      expectedNextFill: (() {
        final raw = json['expected_next_fill']?.toString() ?? json['expectedNextFill']?.toString();
        return raw != null ? DateTime.tryParse(raw) : null;
      })(),
      flag: json['flag']?.toString() ?? json['is_flagged']?.toString() ?? json['flagged']?.toString(),
      initialQuantity: initial,
      dispensedQuantity: dispensed,
      remainingQuantity: computedRemaining,
      fullyDispensed: fullyDispensed,
    );
  }
}
