import 'package:flutter/foundation.dart';
import '../models/admin_patient_adherence.dart'
    show AdherenceTier, tierForStatus, RefillEvent;

enum StaffStatus { active, onLeave, inactive }

T safeEnumValue<T extends Enum>(Iterable<T> values, dynamic raw, T fallback) {
  if (raw is T) return raw;
  final str = raw?.toString();
  if (str == null) return fallback;
  return values.firstWhere((v) => v.name == str, orElse: () => fallback);
}

int safeInt(dynamic value, [int fallback = 0]) {
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

int safePositiveInt(dynamic value, [int fallback = 0]) {
  final result = safeInt(value, 0);
  return result > 0 ? result : fallback;
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

int safePositiveIntFromMap(
  Map<String, dynamic>? map,
  List<String> keys, [
  int fallback = 0,
]) {
  if (map == null) return fallback;
  for (final key in keys) {
    final value = map[key];
    if (value == null) continue;
    final parsed = _toPositiveInt(value);
    if (parsed != null) return parsed;
  }
  return fallback;
}

int safeIntFromMap(
  Map<String, dynamic>? map,
  List<String> keys, [
  int fallback = 0,
]) {
  if (map == null) return fallback;
  for (final key in keys) {
    final value = map[key];
    if (value == null) continue;
    final parsed = _toInt(value);
    if (parsed != null) return parsed;
  }
  return fallback;
}

int safePositiveIntFromAnyKey(Map<String, dynamic>? map, [int fallback = 0]) {
  if (map == null) return fallback;
  for (final entry in map.entries) {
    final value = entry.value;
    if (value == null) continue;
    if (value is String && value.toString().trim().isEmpty) continue;
    if (value is bool) continue;
    if (value is Map || value is List) continue;
    final parsed = _toPositiveInt(value);
    if (parsed != null) {
      debugPrint(
        'FALLBACK initial key=${entry.key} value=$value parsed=$parsed',
      );
      return parsed;
    }
  }
  return fallback;
}

bool safeBool(dynamic value, [bool fallback = false]) {
  if (value == null) return fallback;
  if (value is bool) return value;
  if (value is int) return value != 0;
  if (value is num) return value.toInt() != 0;
  final str = value.toString().toLowerCase().trim();
  if (str == 'true' || str == '1') return true;
  if (str == 'false' || str == '0') return false;
  return fallback;
}

Map<String, dynamic>? safeMap(dynamic value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

double safeDouble(dynamic value, [double fallback = 0.0]) {
  if (value == null) return fallback;
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is num) return value.toDouble();
  final parsed = double.tryParse(value.toString());
  return parsed ?? fallback;
}

List<dynamic> safeList(dynamic value) {
  if (value is List) return List<dynamic>.from(value);
  return const [];
}

class StaffAccount {
  final String id;
  final String name;
  final String role;
  final String email;
  final String lastActive;
  final StaffStatus status;

  const StaffAccount({
    required this.id,
    required this.name,
    required this.role,
    this.email = '',
    this.lastActive = 'Never',
    this.status = StaffStatus.active,
  });

  factory StaffAccount.fromJson(Map<String, dynamic> json) {
    final rawStatus = json['status']?.toString();
    final status = rawStatus != null && rawStatus.isNotEmpty
        ? safeEnumValue(
            StaffStatus.values,
            rawStatus,
            _fallbackFromActive(json['is_active']),
          )
        : _fallbackFromActive(json['is_active']);

    final firstName = json['first_name']?.toString() ?? '';
    final lastName = json['last_name']?.toString() ?? '';
    final name = json['name']?.toString() ?? '$firstName $lastName'.trim();

    final rawLastActive =
        json['last_active']?.toString() ??
        json['last_login_at']?.toString() ??
        '';

    return StaffAccount(
      id: json['id']?.toString() ?? '',
      name: name.isNotEmpty ? name : 'Unknown',
      role:
          json['role']?.toString() ?? json['user_type']?.toString() ?? 'staff',
      email: json['email']?.toString() ?? '',
      lastActive: _formatLastActive(rawLastActive),
      status: status,
    );
  }

  static StaffStatus _fallbackFromActive(dynamic isActve) {
    return safeBool(isActve, true) ? StaffStatus.active : StaffStatus.inactive;
  }

  static String _formatLastActive(String raw) {
    if (raw.isEmpty) return 'Never';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24 &&
        local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
      final m = local.minute.toString().padLeft(2, '0');
      final ap = local.hour < 12 ? 'AM' : 'PM';
      return 'Today, $h:$m $ap';
    }
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${local.month}/${local.day}/${local.year}';
  }

  StaffAccount copyWith({
    String? id,
    String? name,
    String? role,
    String? email,
    String? lastActive,
    StaffStatus? status,
  }) {
    return StaffAccount(
      id: id ?? this.id,
      name: name ?? this.name,
      role: role ?? this.role,
      email: email ?? this.email,
      lastActive: lastActive ?? this.lastActive,
      status: status ?? this.status,
    );
  }

  String get initials => name
      .trim()
      .split(RegExp(r'\s+'))
      .map((w) => w.isNotEmpty ? w[0] : '')
      .take(2)
      .join()
      .toUpperCase();

  String get roleLabel {
    switch (role.toLowerCase()) {
      case 'admin':
        return 'Admin';
      case 'pharmacist':
      case 'pharmacist-in-charge':
        return 'Pharmacist-in-Charge';
      case 'dispenser':
      case 'pharmacy_assistant':
      case 'pharmacy-assistant':
        return 'Pharmacy Assistant';
      default:
        return role.isNotEmpty
            ? '${role[0].toUpperCase()}${role.substring(1)}'
            : 'Staff';
    }
  }
}

enum ReportFormat { pdf, csv }

class ReportItem {
  final String title;
  final String subtitle;
  final ReportFormat format;

  const ReportItem({
    required this.title,
    required this.subtitle,
    required this.format,
  });
}

enum ReportType { dispensing, seniorCitizenDiscount }

class DispensingReportRow {
  final String dateDispensed;
  final String rxNumber;
  final String physicianName;
  final String patientName;
  final String genericName;
  final String brandName;
  final String lotNo;
  final String expiryDate;
  final int quantityServed;
  final String remarks;

  const DispensingReportRow({
    required this.dateDispensed,
    required this.rxNumber,
    required this.physicianName,
    required this.patientName,
    required this.genericName,
    required this.brandName,
    required this.lotNo,
    required this.expiryDate,
    required this.quantityServed,
    required this.remarks,
  });

  factory DispensingReportRow.fromJson(Map<String, dynamic> json) {
    return DispensingReportRow(
      dateDispensed: json['date_dispensed']?.toString() ?? '',
      rxNumber:
          json['rx_number']?.toString() ?? json['rx_no']?.toString() ?? '',
      physicianName:
          json['physician_name']?.toString() ??
          json['physician']?.toString() ??
          '',
      patientName: json['patient_name']?.toString() ?? '',
      genericName: json['generic_name']?.toString() ?? '',
      brandName: json['brand_name']?.toString() ?? '',
      lotNo: json['lot_no']?.toString() ?? '',
      expiryDate: json['expiry_date']?.toString() ?? '',
      quantityServed: safeInt(json['quantity_served']),
      remarks: json['remarks']?.toString() ?? '',
    );
  }
}

class SeniorCitizenReportRow {
  final String date;
  final String seniorCitizenName;
  final String oscaId;
  final String drugName;
  final double grossCost;
  final double discountPercent;
  final double netCost;
  final String orNumber;

  const SeniorCitizenReportRow({
    required this.date,
    required this.seniorCitizenName,
    required this.oscaId,
    required this.drugName,
    required this.grossCost,
    required this.discountPercent,
    required this.netCost,
    required this.orNumber,
  });

  factory SeniorCitizenReportRow.fromJson(Map<String, dynamic> json) {
    return SeniorCitizenReportRow(
      date: json['date']?.toString() ?? '',
      seniorCitizenName:
          json['senior_citizen_name']?.toString() ??
          json['senior_name']?.toString() ??
          '',
      oscaId: json['osca_id']?.toString() ?? '',
      drugName: json['drug_name']?.toString() ?? '',
      grossCost: safeDouble(json['gross_cost']),
      discountPercent: safeDouble(
        json['discount_percentage'] ?? json['discount_percent'],
      ),
      netCost: safeDouble(json['net_cost']),
      orNumber: json['or_number']?.toString() ?? '',
    );
  }
}

enum ScanRecordStatus { pending, dispensed, blocked, saved }

enum ScanRecordType { qr, ocr }

class ScanRecordEntry {
  final ScanRecordStatus status;
  final ScanRecordType type;
  final String refNumber;
  final String patientName;
  final String description;
  final String staff;
  final String time;
  final bool isFlagged;
  final String? prescriptionId;

  const ScanRecordEntry({
    required this.status,
    required this.type,
    required this.refNumber,
    required this.patientName,
    required this.description,
    required this.staff,
    required this.time,
    this.isFlagged = false,
    this.prescriptionId,
  });
}

class ScanRecordsResponse {
  final int qrCount;
  final int ocrCount;
  final List<ScanRecordEntry> records;

  const ScanRecordsResponse({
    required this.qrCount,
    required this.ocrCount,
    required this.records,
  });
}

class ExceedDetailItem {
  final String medicine;
  final int requested;
  final int otherPending;
  final int remaining;

  ExceedDetailItem({
    required this.medicine,
    required this.requested,
    required this.otherPending,
    required this.remaining,
  });
}

class MedicineItem {
  final String name;
  final int quantity;

  MedicineItem({required this.name, required this.quantity});
}

// 'rejected' is legacy/unused by the current flow — there is no
// reject/decline action. A pending request is either approved (becomes
// 'dispensed') or flagged as a risk ('flagged', still approvable later).
enum RequestStatus { pending, approved, rejected, dispensed, flagged }

class CrossPharmacyRequestResponse {
  final String requestId;
  final String requestingPharmacyName;
  final String requestingPharmacyLocation;
  // FDA / LTO licence number the requesting pharmacy self-declared. Empty
  // when the backend row predates this field or none was captured.
  final String requestingPharmacyLicense;
  final String rxNumber;
  final String patientName;
  final List<MedicineItem> medicines;
  final String requestingStaffName;
  String? rejectionReason;
  RequestStatus status;
  String? dispensingStatus;
  String? dispensedBy;
  String? dispensedAt;
  final bool wouldExceedRemaining;
  final List<ExceedDetailItem> exceedDetails;
  final bool fullyDispensed;

  CrossPharmacyRequestResponse({
    required this.requestId,
    required this.requestingPharmacyName,
    required this.requestingPharmacyLocation,
    this.requestingPharmacyLicense = '',
    required this.rxNumber,
    required this.patientName,
    required this.medicines,
    required this.requestingStaffName,
    this.rejectionReason,
    required this.status,
    this.dispensingStatus,
    this.dispensedBy,
    this.dispensedAt,
    this.wouldExceedRemaining = false,
    this.exceedDetails = const [],
    this.fullyDispensed = false,
  });
}

enum ScanType { qr, ocr }

class RecordLogEntry {
  final ScanType type;
  final String patientName;
  final String refCode;
  final String time;
  final DateTime dateTime;
  final String detail;
  final String staffName;
  final bool isFlagged;

  const RecordLogEntry({
    required this.type,
    required this.patientName,
    required this.refCode,
    required this.time,
    required this.dateTime,
    required this.detail,
    required this.staffName,
    this.isFlagged = false,
  });
}

class DispensingTrendPoint {
  final String day;
  final int count;
  final double value;

  const DispensingTrendPoint({
    required this.day,
    required this.count,
    required this.value,
  });
}

class MedicationInfo {
  final String name;
  final String dosage;
  final int initialQuantity;
  final int dispensedQuantity;
  final int remainingQuantity;
  final bool fullyDispensed;

  const MedicationInfo({
    required this.name,
    this.dosage = '',
    this.initialQuantity = 0,
    this.dispensedQuantity = 0,
    this.remainingQuantity = 0,
    this.fullyDispensed = false,
  });

  factory MedicationInfo.fromJson(Map<String, dynamic> json) {
    final initial = safePositiveIntFromMap(json, [
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
    final dispensed = safeIntFromMap(json, [
      'total_dispensed_quantity',
      'totalDispensedQuantity',
      'disposed_quantity',
      'disposedQuantity',
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
    final remaining = safeIntFromMap(json, [
      'remaining_quantity',
      'remainingQuantity',
      'remaining_qty',
      'remainingQty',
    ]);
    final fallbackInitial = initial == 0 ? safePositiveIntFromAnyKey(json) : 0;
    final computedRemaining = (initial > 0 ? initial : fallbackInitial) > 0
        ? ((initial > 0 ? initial : fallbackInitial) - dispensed).clamp(
            0,
            initial > 0 ? initial : fallbackInitial,
          )
        : remaining;
    final fullyDispensed =
        safeBool(json['fully_dispensed'] ?? json['fullyDispensed']) ||
        ((initial > 0 ? initial : fallbackInitial) > 0 &&
            computedRemaining <= 0 &&
            dispensed > 0);

    return MedicationInfo(
      name: json['name']?.toString() ?? json['medicine_name']?.toString() ?? '',
      dosage: json['dosage']?.toString() ?? '',
      initialQuantity: initial > 0 ? initial : fallbackInitial,
      dispensedQuantity: dispensed,
      remainingQuantity: computedRemaining,
      fullyDispensed: fullyDispensed,
    );
  }

  MedicationInfo copyWith({
    String? name,
    String? dosage,
    int? initialQuantity,
    int? dispensedQuantity,
    int? remainingQuantity,
    bool? fullyDispensed,
  }) {
    return MedicationInfo(
      name: name ?? this.name,
      dosage: dosage ?? this.dosage,
      initialQuantity: initialQuantity ?? this.initialQuantity,
      dispensedQuantity: dispensedQuantity ?? this.dispensedQuantity,
      remainingQuantity: remainingQuantity ?? this.remainingQuantity,
      fullyDispensed: fullyDispensed ?? this.fullyDispensed,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'dosage': dosage,
      'initial_quantity': initialQuantity,
      'disposed_quantity': dispensedQuantity,
      'remaining_quantity': remainingQuantity,
      'fully_dispensed': fullyDispensed,
    };
  }
}

class PatientDetailResponse {
  final String patientId;
  final String name;
  final String genderAge;
  final int? age;
  final String? sex;
  final int? adherencePercent;
  final AdherenceTier adherenceLevel;
  final String? adherenceReason;
  final bool hasHistory;
  final List<MedicationInfo> medications;
  final List<RefillEvent> refillHistory;
  final bool isLocked;
  final String? lockReason;
  final String? prescriptionId;

  const PatientDetailResponse({
    required this.patientId,
    required this.name,
    required this.genderAge,
    this.age,
    this.sex,
    this.adherencePercent,
    this.adherenceLevel = AdherenceTier.good,
    this.adherenceReason,
    this.hasHistory = false,
    this.medications = const [],
    this.refillHistory = const [],
    this.isLocked = false,
    this.lockReason,
    this.prescriptionId,
  });

  factory PatientDetailResponse.fromJson(Map<String, dynamic> json) {
    final data = safeMap(json['data'] ?? json) ?? json;
    debugPrint('PATIENT DETAIL raw medications=${data['medications']}');
    debugPrint('PATIENT DETAIL raw items=${data['items']}');

    final rawName =
        data['name']?.toString() ??
        '${data['first_name'] ?? ''} ${data['last_name'] ?? ''}'.trim();
    final rawAge = data['age'] ?? data['patient_age'] ?? data['age_years'];
    final age = rawAge == null ? null : safeInt(rawAge);
    final sex = (data['sex'] ?? data['gender'] ?? '').toString().isEmpty
        ? null
        : (data['sex'] ?? data['gender']).toString();
    final rawGenderAge =
        data['gender_age']?.toString() ?? data['genderAge']?.toString();

    final score = safeInt(
      data['adherence_percent'] ??
          data['adherencePercent'] ??
          data['score'] ??
          data['adherence_score'] ??
          data['percentage'],
      0,
    );
    final apiStatus =
        (data['status']?.toString() ??
                data['adherence_status']?.toString() ??
                'no_data')
            .toLowerCase();
    final apiStatusLabel =
        data['status_label']?.toString() ?? data['statusLabel']?.toString();
    final apiStatusNote =
        data['status_note']?.toString() ?? data['statusNote']?.toString();
    final apiFullyDispensed = safeBool(
      data['fully_dispensed'] ?? data['fullyDispensed'],
    );

    AdherenceTier effectiveTier;
    if (apiStatus == 'overdispensing' || apiStatus == 'over_dispensing') {
      effectiveTier = AdherenceTier.overDispensing;
    } else if (apiStatus == 'fully_dispensed' || apiFullyDispensed) {
      effectiveTier = AdherenceTier.fullyDispensed;
    } else if (apiStatus == 'at_risk') {
      effectiveTier = AdherenceTier.atRisk;
    } else if (apiStatus == 'critical') {
      effectiveTier = AdherenceTier.critical;
    } else if (apiStatus == 'good') {
      effectiveTier = AdherenceTier.good;
    } else {
      effectiveTier = tierForStatus(apiStatus, score);
    }

    final medicationsSource = safeList(data['medications'] ?? data['items']);
    final medications = medicationsSource.map((e) {
      if (e is MedicationInfo) return e;
      final map = safeMap(e) ?? {};
      final initial = safePositiveIntFromMap(map, [
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
      final dispensed = safeIntFromMap(map, [
        'total_dispensed_quantity',
        'totalDispensedQuantity',
        'disposed_quantity',
        'disposedQuantity',
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
      final remaining = safeIntFromMap(map, [
        'remaining_quantity',
        'remainingQuantity',
        'remaining_qty',
        'remainingQty',
      ]);
      final computedRemaining = initial > 0
          ? (initial - dispensed).clamp(0, initial)
          : remaining;
      final fullyDispensed =
          safeBool(map['fully_dispensed'] ?? map['fullyDispensed']) ||
          (initial > 0 && computedRemaining <= 0 && dispensed > 0);
      return MedicationInfo(
        name: map['name']?.toString() ?? map['medicine_name']?.toString() ?? '',
        dosage: map['dosage']?.toString() ?? '',
        initialQuantity: initial,
        dispensedQuantity: dispensed,
        remainingQuantity: computedRemaining,
        fullyDispensed: fullyDispensed,
      );
    }).toList();

    final refillHistorySource = safeList(
      data['refill_history'] ??
          data['refillHistory'] ??
          data['dispensing_logs'] ??
          data['dispensingLogs'],
    );
    final refillHistory = refillHistorySource.map((e) {
      if (e is RefillEvent) return e;
      final map = safeMap(e) ?? {};
      return RefillEvent.fromJson(map);
    }).toList();

    final locked = safeBool(data['is_locked'] ?? data['locked']);
    final effectiveReason =
        apiStatusLabel ??
        apiStatusNote ??
        data['reason']?.toString() ??
        (apiFullyDispensed ? 'All medications fully dispensed.' : null);
    final hasHistory = safeBool(
      data['has_history'] ??
          data['hasHistory'] ??
          data['has_data'] ??
          data['hasData'],
    );
    final hasMedications = medications.isNotEmpty;
    final hasRefillHistory = refillHistory.isNotEmpty;
    final effectiveHasHistory =
        hasHistory || hasMedications || hasRefillHistory;

    return PatientDetailResponse(
      patientId: (data['patient_id'] ?? data['id'] ?? '').toString(),
      name: rawName.isNotEmpty ? rawName : 'Unknown Patient',
      genderAge: rawGenderAge ?? _buildGenderAge(age, sex),
      age: age,
      sex: sex,
      adherencePercent: score,
      adherenceLevel: effectiveTier,
      adherenceReason: effectiveReason,
      hasHistory: effectiveHasHistory,
      medications: medications,
      refillHistory: refillHistory,
      isLocked: locked,
      lockReason:
          data['lock_reason']?.toString() ?? data['lockReason']?.toString(),
      prescriptionId:
          data['prescription_id']?.toString() ??
          data['prescriptionId']?.toString(),
    );
  }

  static String _buildGenderAge(int? age, String? sex) {
    final ageStr = age != null && age > 0 ? age.toString() : '';
    final sexStr = (sex ?? '').trim();
    if (ageStr.isEmpty && sexStr.isEmpty) return '';
    return '$ageStr$sexStr';
  }

  PatientDetailResponse copyWith({
    String? patientId,
    String? name,
    String? genderAge,
    int? age,
    String? sex,
    int? adherencePercent,
    AdherenceTier? adherenceLevel,
    String? adherenceReason,
    bool? hasHistory,
    List<MedicationInfo>? medications,
    List<RefillEvent>? refillHistory,
    bool? isLocked,
    String? lockReason,
    String? prescriptionId,
  }) {
    return PatientDetailResponse(
      patientId: patientId ?? this.patientId,
      name: name ?? this.name,
      genderAge: genderAge ?? this.genderAge,
      age: age ?? this.age,
      sex: sex ?? this.sex,
      adherencePercent: adherencePercent ?? this.adherencePercent,
      adherenceLevel: adherenceLevel ?? this.adherenceLevel,
      adherenceReason: adherenceReason ?? this.adherenceReason,
      hasHistory: hasHistory ?? this.hasHistory,
      medications: medications ?? this.medications,
      refillHistory: refillHistory ?? this.refillHistory,
      isLocked: isLocked ?? this.isLocked,
      lockReason: lockReason ?? this.lockReason,
      prescriptionId: prescriptionId ?? this.prescriptionId,
    );
  }
}
