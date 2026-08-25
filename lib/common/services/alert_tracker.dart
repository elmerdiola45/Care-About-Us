import 'package:flutter/foundation.dart';
import '../../pharmacist/models/dispense_alert.dart';

/// Tracks the read and unread state of dispensing alerts by their stable unique ID.
///
/// The server's `is_read` value is authoritative. This tracker mirrors the server
/// state locally for UI responsiveness, but never overrides it.
class AlertTracker extends ChangeNotifier {
  AlertTracker._();

  static final AlertTracker instance = AlertTracker._();

  final Set<String> _readAlertIds = {};
  final Set<String> _unreadAlertIds = {};
  final Set<String> _knownAlertIds = {};
  bool _isSeeded = false;

  /// The set of alert IDs that are currently unread.
  Set<String> get unreadAlertIds => Set.unmodifiable(_unreadAlertIds);

  /// The set of alert IDs that have been marked as read.
  Set<String> get readAlertIds => Set.unmodifiable(_readAlertIds);

  /// The current unread alert count (drives the notification badge).
  int get unreadCount => _unreadAlertIds.length;

  /// Whether a specific alert ID has been marked as read.
  bool isRead(String alertId) => _readAlertIds.contains(alertId);

  /// Whether a specific alert ID is currently unread.
  bool isUnread(String alertId) => _unreadAlertIds.contains(alertId);

  /// Processes alerts fetched from the backend (during polling or screen load).
  ///
  /// The server's `is_read` field is authoritative. Local state is updated to
  /// mirror the server without overriding it.
  ///
  /// 1. Identifies newly arrived alert IDs.
  /// 2. Updates read/unread sets based on server `is_read` values.
  /// 3. Cleans up alerts that have been resolved/removed from backend.
  /// 4. Returns the set of newly discovered alert IDs for notifications/snackbars.
  Set<String> processAlerts(List<DispenseAlert> alerts) {
    final currentIds = alerts
        .map((a) => a.alertId)
        .where((id) => id.isNotEmpty)
        .toSet();

    final newIds = _isSeeded
        ? currentIds.difference(_knownAlertIds)
        : <String>{};

    for (final alert in alerts) {
      if (alert.isRead || _readAlertIds.contains(alert.alertId)) {
        _readAlertIds.add(alert.alertId);
        _unreadAlertIds.remove(alert.alertId);
      } else {
        _unreadAlertIds.add(alert.alertId);
      }
    }

    _readAlertIds.retainAll(currentIds);
    _unreadAlertIds.retainAll(currentIds);

    _knownAlertIds
      ..clear()
      ..addAll(currentIds);
    _isSeeded = true;

    notifyListeners();
    return newIds;
  }

  /// Marks ONLY the specified [alertId] as read.
  ///
  /// Removes ONLY this ID from the unread collection and adds it to the read set.
  /// Recalculates the badge and notifies listeners.
  void markAsRead(String alertId) {
    if (alertId.isEmpty) return;
    _readAlertIds.add(alertId);
    final wasUnread = _unreadAlertIds.remove(alertId);
    if (wasUnread) {
      notifyListeners();
    }
  }

  /// Reverts ONLY the specified [alertId] from read back to unread.
  ///
  /// Called when the optimistic server call failed, so the UI state
  /// must reflect the server's actual (still unread) state.
  void unmarkAsRead(String alertId) {
    if (alertId.isEmpty) return;
    if (_readAlertIds.remove(alertId)) {
      _unreadAlertIds.add(alertId);
      notifyListeners();
    }
  }

  /// Resets all in-memory tracking state (e.g. upon user logout).
  void clear() {
    _readAlertIds.clear();
    _unreadAlertIds.clear();
    _knownAlertIds.clear();
    _isSeeded = false;
    notifyListeners();
  }
}
