class DashboardSummary {
  final String period;
  final String dateFrom;
  final String dateTo;
  final int rxCount;
  final int activeAlerts;
  final int alertsRaisedInPeriod;
  final int odFlagsLogged;
  final double avgAdherence;
  final int refillsDue;

  DashboardSummary({
    required this.period,
    required this.dateFrom,
    required this.dateTo,
    required this.rxCount,
    required this.activeAlerts,
    this.alertsRaisedInPeriod = 0,
    required this.odFlagsLogged,
    required this.avgAdherence,
    this.refillsDue = 0,
  });

  factory DashboardSummary.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> dataMap;
    final data = json['data'];
    if (data is Map) {
      dataMap = Map<String, dynamic>.from(data);
    } else if (data is Map<dynamic, dynamic>) {
      dataMap = Map<String, dynamic>.from(data);
    } else {
      dataMap = Map<String, dynamic>.from(json);
    }
    return DashboardSummary(
      period: dataMap['period']?.toString() ?? 'today',
      dateFrom: dataMap['date_from']?.toString() ?? '',
      dateTo: dataMap['date_to']?.toString() ?? '',
      rxCount: (dataMap['rx_count'] as num?)?.toInt() ?? (dataMap['rx_today'] as num?)?.toInt() ?? 0,
      activeAlerts: (dataMap['active_alerts'] as num?)?.toInt() ?? 0,
      alertsRaisedInPeriod: (dataMap['alerts_raised_in_period'] as num?)?.toInt() ?? 0,
      odFlagsLogged: (dataMap['od_flags_logged'] as num?)?.toInt() ?? 0,
      avgAdherence: (dataMap['avg_adherence'] as num?)?.toDouble() ?? 0.0,
      refillsDue: (dataMap['refills_due'] as num?)?.toInt() ?? (dataMap['refillDue'] as num?)?.toInt() ?? 0,
    );
  }
}

class AlertItem {
  final String alertId;
  final String alertType;
  final String priority;
  final String? rxNumber;
  final String? patientName;
  final String description;
  final bool resolved;
  final DateTime createdAt;
  final DateTime? resolvedAt;
  final String? severity;

  AlertItem({
    required this.alertId,
    required this.alertType,
    required this.priority,
    this.rxNumber,
    this.patientName,
    required this.description,
    required this.resolved,
    required this.createdAt,
    this.resolvedAt,
    this.severity,
  });

  factory AlertItem.fromJson(Map<String, dynamic> json) {
    return AlertItem(
      alertId: (json['id'] ?? json['alert_id'] ?? '').toString(),
      alertType: (json['alert_type'] ?? json['alertType'] ?? '').toString(),
      priority: (json['priority'] ?? 'normal').toString(),
      rxNumber: json['rx_number']?.toString() ?? json['rxNumber']?.toString(),
      patientName: json['patient_name']?.toString() ?? json['patientName']?.toString(),
      description: (json['note'] ?? json['description'] ?? '').toString(),
      resolved: json['resolved'] is bool ? json['resolved'] as bool : false,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at']?.toString() ?? '') ?? DateTime.now()
          : DateTime.now(),
      resolvedAt: json['resolved_at'] != null
          ? DateTime.tryParse(json['resolved_at']?.toString() ?? '')
          : null,
      severity: json['severity']?.toString(),
    );
  }
}

class ActivityLogEntry {
  final String logId;
  final String eventType;
  final String? description;
  final String? rxNumber;
  final String? staffName;
  final String? branchName;
  final DateTime createdAt;
  final Map<String, dynamic>? metadata;

  ActivityLogEntry({
    required this.logId,
    required this.eventType,
    this.description,
    this.rxNumber,
    this.staffName,
    this.branchName,
    required this.createdAt,
    this.metadata,
  });

  factory ActivityLogEntry.fromJson(Map<String, dynamic> json) {
    return ActivityLogEntry(
      logId: (json['id'] ?? json['log_id'] ?? '').toString(),
      eventType: (json['event_type'] ?? json['eventType'] ?? '').toString(),
      description: json['description']?.toString(),
      rxNumber: json['rx_number']?.toString() ?? json['rxNumber']?.toString(),
      staffName: json['staff_name']?.toString() ?? json['staffName']?.toString(),
      branchName: json['branch_name']?.toString() ?? json['branchName']?.toString(),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at']?.toString() ?? '') ?? DateTime.now()
          : DateTime.now(),
      metadata: json['metadata'] is Map ? Map<String, dynamic>.from(json['metadata'] as Map) : null,
    );
  }
}

class StaffProfile {
  final String name;
  final String branchName;
  final String shiftStart;
  final String shiftEnd;

  StaffProfile({
    required this.name,
    required this.branchName,
    required this.shiftStart,
    required this.shiftEnd,
  });

  factory StaffProfile.fromJson(Map<String, dynamic> json) {
    final user = json['user'] is Map ? Map<String, dynamic>.from(json['user'] as Map) : json;
    return StaffProfile(
      name: user['name']?.toString() ?? user['staff_name']?.toString() ?? '',
      branchName: user['branch_name']?.toString() ?? '',
      shiftStart: user['shift_start']?.toString() ?? '8:00 AM',
      shiftEnd: user['shift_end']?.toString() ?? '5:00 PM',
    );
  }
}

class ActivityReport {
  final DateTime date;
  final int prescriptionsDispensed;
  final int qrScanned;
  final int refillsDue;
  final int overdispensingFlags;
  final double totalSales;

  ActivityReport({
    required this.date,
    this.prescriptionsDispensed = 0,
    this.qrScanned = 0,
    this.refillsDue = 0,
    this.overdispensingFlags = 0,
    this.totalSales = 0,
  });

  factory ActivityReport.fromJson(Map<String, dynamic> json) {
    final dateRaw = json['date']?.toString() ?? json['created_at']?.toString();
    return ActivityReport(
      date: dateRaw != null ? (DateTime.tryParse(dateRaw) ?? DateTime.now()) : DateTime.now(),
      prescriptionsDispensed: (json['prescriptions_dispensed'] as num?)?.toInt() ?? (json['dispensed'] as num?)?.toInt() ?? 0,
      qrScanned: (json['qr_scanned'] as num?)?.toInt() ?? (json['scanned'] as num?)?.toInt() ?? 0,
      refillsDue: (json['refills_due'] as num?)?.toInt() ?? (json['refillDue'] as num?)?.toInt() ?? 0,
      overdispensingFlags: (json['overdispensing_flags'] as num?)?.toInt() ?? (json['od_flags'] as num?)?.toInt() ?? 0,
      totalSales: (json['total_sales'] as num?)?.toDouble() ?? (json['sales'] as num?)?.toDouble() ?? 0.0,
    );
  }
}