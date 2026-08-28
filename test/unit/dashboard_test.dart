import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_management_system/common/models/dashboard_models.dart';

void main() {
  group('DashboardSummary', () {
    test('fromJson parses all fields correctly', () {
      final json = {
        'data': {
          'period': 'today',
          'date_from': '2026-08-02',
          'date_to': '2026-08-02',
          'rx_count': 47,
          'active_alerts': 3,
          'od_flags_logged': 2,
          'avg_adherence': 85.5,
        },
      };

      final summary = DashboardSummary.fromJson(json);

      expect(summary.period, equals('today'));
      expect(summary.rxCount, equals(47));
      expect(summary.activeAlerts, equals(3));
      expect(summary.odFlagsLogged, equals(2));
      expect(summary.avgAdherence, equals(85.5));
    });

    test('fromJson handles missing data key', () {
      final json = {
        'rx_count': 10,
        'active_alerts': 0,
        'od_flags_logged': 1,
      };

      final summary = DashboardSummary.fromJson(json);

      expect(summary.period, equals('today'));
      expect(summary.rxCount, equals(10));
      expect(summary.activeAlerts, equals(0));
      expect(summary.odFlagsLogged, equals(1));
    });

    test('fromJson handles null values', () {
      final json = {
        'data': {
          'period': 'week',
          'date_from': '2026-07-27',
          'date_to': '2026-08-02',
          'rx_count': null,
          'active_alerts': null,
          'od_flags_logged': null,
          'avg_adherence': null,
        },
      };

      final summary = DashboardSummary.fromJson(json);

      expect(summary.period, equals('week'));
      expect(summary.rxCount, equals(0));
      expect(summary.activeAlerts, equals(0));
      expect(summary.odFlagsLogged, equals(0));
      expect(summary.avgAdherence, equals(0.0));
    });

    test('fromJson handles empty data object', () {
      final json = {'data': {}};

      final summary = DashboardSummary.fromJson(json);

      expect(summary.period, equals('today'));
      expect(summary.rxCount, equals(0));
      expect(summary.activeAlerts, equals(0));
      expect(summary.odFlagsLogged, equals(0));
    });

    test('fromJson handles zero values', () {
      final json = {
        'data': {
          'period': 'month',
          'date_from': '2026-08-01',
          'date_to': '2026-08-31',
          'rx_count': 0,
          'active_alerts': 0,
          'od_flags_logged': 0,
          'avg_adherence': 0.0,
        },
      };

      final summary = DashboardSummary.fromJson(json);

      expect(summary.period, equals('month'));
      expect(summary.rxCount, equals(0));
      expect(summary.activeAlerts, equals(0));
      expect(summary.odFlagsLogged, equals(0));
      expect(summary.avgAdherence, equals(0.0));
    });
  });

  group('DashboardSummary edge cases', () {
    test('handles large numbers', () {
      final json = {
        'data': {
          'period': 'today',
          'date_from': '2026-08-02',
          'date_to': '2026-08-02',
          'rx_count': 9999,
          'active_alerts': 999,
          'od_flags_logged': 500,
          'avg_adherence': 99.9,
        },
      };

      final summary = DashboardSummary.fromJson(json);

      expect(summary.rxCount, equals(9999));
      expect(summary.activeAlerts, equals(999));
      expect(summary.odFlagsLogged, equals(500));
      expect(summary.avgAdherence, equals(99.9));
    });
  });

  group('AlertItem', () {
    test('fromJson parses all fields correctly', () {
      final json = {
        'id': 'alert-1',
        'alert_type': 'over_dispense',
        'priority': 'high',
        'rx_number': 'RX-2024-00512',
        'patient_name': 'Ana Reyes',
        'note': 'Over-dispensed: Tramadol 50mg',
        'resolved': false,
        'created_at': '2025-07-05T14:17:00.000Z',
        'severity': 'critical',
      };

      final alert = AlertItem.fromJson(json);

      expect(alert.alertId, equals('alert-1'));
      expect(alert.alertType, equals('over_dispense'));
      expect(alert.priority, equals('high'));
      expect(alert.rxNumber, equals('RX-2024-00512'));
      expect(alert.patientName, equals('Ana Reyes'));
      expect(alert.resolved, isFalse);
      expect(alert.severity, equals('critical'));
    });

    test('fromJson handles resolved alert', () {
      final json = {
        'id': 'alert-2',
        'alert_type': 'early_refill',
        'priority': 'normal',
        'rx_number': 'RX-2024-00498',
        'patient_name': 'Jun dela Cruz',
        'note': 'Refill due today: Metformin',
        'resolved': true,
        'created_at': '2025-07-05T11:30:00.000Z',
        'resolved_at': '2025-07-05T12:00:00.000Z',
      };

      final alert = AlertItem.fromJson(json);

      expect(alert.resolved, isTrue);
      expect(alert.resolvedAt, isNotNull);
    });

    test('fromJson handles missing optional fields', () {
      final json = {
        'id': 'alert-3',
        'alert_type': 'duplicate_dispense',
        'priority': 'normal',
        'note': 'Duplicate dispense detected',
        'resolved': false,
        'created_at': '2025-07-05T09:00:00.000Z',
      };

      final alert = AlertItem.fromJson(json);

      expect(alert.rxNumber, isNull);
      expect(alert.patientName, isNull);
      expect(alert.severity, isNull);
    });

    test('fromJson handles alternative key names', () {
      final json = {
        'alert_id': 'alert-4',
        'alertType': 'over_dispense',
        'priority': 'high',
        'rxNumber': 'RX-2024-00501',
        'patientName': 'Rose Pautista',
        'note': 'Refill due today: Losartan',
        'resolved': false,
        'created_at': '2025-07-05T09:15:00.000Z',
      };

      final alert = AlertItem.fromJson(json);

      expect(alert.alertId, equals('alert-4'));
      expect(alert.rxNumber, equals('RX-2024-00501'));
      expect(alert.patientName, equals('Rose Pautista'));
    });
  });

  group('ActivityLogEntry', () {
    test('fromJson parses all fields correctly', () {
      final json = {
        'id': 'log-1',
        'event_type': 'over_dispense_blocked',
        'description': 'Blocked over-dispensing of Tramadol 50mg',
        'rx_number': 'RX-2024-00512',
        'staff_name': 'Rosa',
        'branch_name': 'Care About Us Pharmacy',
        'created_at': '2025-07-05T14:17:00.000Z',
        'metadata': {'medicine_name': 'Tramadol', 'quantity_dispensed': 3},
      };

      final entry = ActivityLogEntry.fromJson(json);

      expect(entry.logId, equals('log-1'));
      expect(entry.eventType, equals('over_dispense_blocked'));
      expect(entry.description, equals('Blocked over-dispensing of Tramadol 50mg'));
      expect(entry.rxNumber, equals('RX-2024-00512'));
      expect(entry.staffName, equals('Rosa'));
      expect(entry.branchName, equals('Care About Us Pharmacy'));
      expect(entry.metadata, isNotNull);
      expect(entry.metadata!['medicine_name'], equals('Tramadol'));
    });

    test('fromJson handles missing optional fields', () {
      final json = {
        'id': 'log-2',
        'event_type': 'ocr_scan_saved',
        'created_at': '2025-07-05T10:00:00.000Z',
      };

      final entry = ActivityLogEntry.fromJson(json);

      expect(entry.description, isNull);
      expect(entry.rxNumber, isNull);
      expect(entry.staffName, isNull);
      expect(entry.branchName, isNull);
      expect(entry.metadata, isNull);
    });

    test('fromJson handles alternative key names', () {
      final json = {
        'log_id': 'log-3',
        'eventType': 'refill_reminder_sent',
        'description': 'Refill reminder sent for RX RX-2024-00498',
        'rxNumber': 'RX-2024-00498',
        'staffName': 'Rosa',
        'branchName': 'Care About Us Pharmacy',
        'created_at': '2025-07-05T08:00:00.000Z',
      };

      final entry = ActivityLogEntry.fromJson(json);

      expect(entry.logId, equals('log-3'));
      expect(entry.eventType, equals('refill_reminder_sent'));
      expect(entry.description, equals('Refill reminder sent for RX RX-2024-00498'));
      expect(entry.rxNumber, equals('RX-2024-00498'));
      expect(entry.staffName, equals('Rosa'));
      expect(entry.branchName, equals('Care About Us Pharmacy'));
    });
  });

  group('StaffProfile', () {
    test('fromJson parses all fields correctly', () {
      final json = {
        'user': {
          'name': 'Rosa',
          'staff_name': 'Rosa Santos',
          'branch_name': 'Care About Us Pharmacy',
          'shift_start': '8:00 AM',
          'shift_end': '5:00 PM',
        },
      };

      final profile = StaffProfile.fromJson(json);

      expect(profile.name, equals('Rosa'));
      expect(profile.branchName, equals('Care About Us Pharmacy'));
      expect(profile.shiftStart, equals('8:00 AM'));
      expect(profile.shiftEnd, equals('5:00 PM'));
    });

    test('fromJson handles flat structure', () {
      final json = {
        'name': 'Rosa',
        'branch_name': 'Care About Us Pharmacy',
        'shift_start': '9:00 AM',
        'shift_end': '6:00 PM',
      };

      final profile = StaffProfile.fromJson(json);

      expect(profile.name, equals('Rosa'));
      expect(profile.branchName, equals('Care About Us Pharmacy'));
      expect(profile.shiftStart, equals('9:00 AM'));
      expect(profile.shiftEnd, equals('6:00 PM'));
    });

    test('fromJson handles missing shift fields', () {
      final json = {
        'user': {
          'name': 'Rosa',
        },
      };

      final profile = StaffProfile.fromJson(json);

      expect(profile.shiftStart, equals('8:00 AM'));
      expect(profile.shiftEnd, equals('5:00 PM'));
    });
  });

  group('ActivityLogEntry filtering', () {
    test('filters by date correctly', () {
      final entries = [
        ActivityLogEntry(
          logId: '1',
          eventType: 'over_dispense_blocked',
          description: 'Blocked over-dispensing',
          createdAt: DateTime(2025, 7, 5, 14, 0),
        ),
        ActivityLogEntry(
          logId: '2',
          eventType: 'ocr_scan_saved',
          description: 'OCR scan saved',
          createdAt: DateTime(2025, 7, 5, 10, 0),
        ),
        ActivityLogEntry(
          logId: '3',
          eventType: 'home_scan_dispensed',
          description: 'Home scan dispensed',
          createdAt: DateTime(2025, 7, 4, 14, 0),
        ),
      ];

      final todayEntries = entries.where((e) => e.createdAt.day == 5).toList();

      expect(todayEntries.length, equals(2));
      expect(todayEntries[0].eventType, equals('over_dispense_blocked'));
      expect(todayEntries[1].eventType, equals('ocr_scan_saved'));
    });

    test('sorts newest first correctly', () {
      final entries = [
        ActivityLogEntry(
          logId: '1',
          eventType: 'ocr_scan_saved',
          description: 'OCR scan saved',
          createdAt: DateTime(2025, 7, 5, 10, 0),
        ),
        ActivityLogEntry(
          logId: '2',
          eventType: 'over_dispense_blocked',
          description: 'Blocked over-dispensing',
          createdAt: DateTime(2025, 7, 5, 14, 0),
        ),
      ];

      final sorted = entries.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      expect(sorted[0].eventType, equals('over_dispense_blocked'));
      expect(sorted[1].eventType, equals('ocr_scan_saved'));
    });
  });

  group('AlertItem filtering', () {
    test('filters unresolved alerts correctly', () {
      final alerts = [
        AlertItem(
          alertId: '1',
          alertType: 'over_dispense',
          priority: 'high',
          description: 'Over-dispensed',
          resolved: false,
          createdAt: DateTime(2025, 7, 5, 14, 0),
        ),
        AlertItem(
          alertId: '2',
          alertType: 'early_refill',
          priority: 'normal',
          description: 'Refill due',
          resolved: true,
          createdAt: DateTime(2025, 7, 5, 10, 0),
        ),
      ];

      final unresolved = alerts.where((a) => !a.resolved).toList();

      expect(unresolved.length, equals(1));
      expect(unresolved[0].alertId, equals('1'));
    });

    test('filters resolved alerts correctly', () {
      final alerts = [
        AlertItem(
          alertId: '1',
          alertType: 'over_dispense',
          priority: 'high',
          description: 'Over-dispensed',
          resolved: false,
          createdAt: DateTime(2025, 7, 5, 14, 0),
        ),
        AlertItem(
          alertId: '2',
          alertType: 'early_refill',
          priority: 'normal',
          description: 'Refill due',
          resolved: true,
          createdAt: DateTime(2025, 7, 5, 10, 0),
        ),
      ];

      final resolved = alerts.where((a) => a.resolved).toList();

      expect(resolved.length, equals(1));
      expect(resolved[0].alertId, equals('2'));
    });
  });
}
