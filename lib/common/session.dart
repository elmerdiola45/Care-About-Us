// session.dart
//
// Holds the currently logged-in user so screens can tag created
// prescriptions with the correct pharmacist/dispenser and home pharmacy.
// Also mirrors the session to SharedPreferences so it survives a web page
// refresh or app relaunch — see restore().

import 'package:shared_preferences/shared_preferences.dart';

class AppSession {
  AppSession._();

  static final AppSession instance = AppSession._();

  static const _kUserId = 'session_userId';
  static const _kUserType = 'session_userType';
  static const _kPharmacyId = 'session_pharmacyId';
  static const _kToken = 'session_token';
  static const _kStaffName = 'session_staffName';
  static const _kBranchName = 'session_branchName';
  static const _kShiftStart = 'session_shiftStart';
  static const _kShiftEnd = 'session_shiftEnd';

  String? userId;
  String userType = ''; // 'dispenser' | 'admin'
  String? pharmacyId;
  String? token;
  String? staffName;
  String? branchName;
  String? shiftStart;
  String? shiftEnd;

  void setUser({
    required String id,
    required String type,
    String? pharmacyId,
    String? token,
    String? staffName,
    String? branchName,
    String? shiftStart,
    String? shiftEnd,
  }) {
    userId = id;
    userType = type;
    this.pharmacyId = pharmacyId;
    this.token = token;
    this.staffName = staffName;
    this.branchName = branchName;
    this.shiftStart = shiftStart;
    this.shiftEnd = shiftEnd;
    _persist();
  }

  void clear() {
    userId = null;
    userType = '';
    pharmacyId = null;
    token = null;
    staffName = null;
    branchName = null;
    shiftStart = null;
    shiftEnd = null;
    _clearPersisted();
  }

  /// Reads a previously persisted session back from disk. Returns true only
  /// when a non-empty token and userId were found — a fresh install or a
  /// session that was explicitly cleared correctly reports false without
  /// touching the singleton's fields.
  Future<bool> restore() async {
    final prefs = await SharedPreferences.getInstance();

    final storedToken = prefs.getString(_kToken);
    final storedUserId = prefs.getString(_kUserId);
    if (storedToken == null ||
        storedToken.isEmpty ||
        storedUserId == null ||
        storedUserId.isEmpty) {
      return false;
    }

    userId = storedUserId;
    token = storedToken;
    userType = prefs.getString(_kUserType) ?? '';
    pharmacyId = _emptyToNull(prefs.getString(_kPharmacyId));
    staffName = _emptyToNull(prefs.getString(_kStaffName));
    branchName = _emptyToNull(prefs.getString(_kBranchName));
    shiftStart = _emptyToNull(prefs.getString(_kShiftStart));
    shiftEnd = _emptyToNull(prefs.getString(_kShiftEnd));
    return true;
  }

  String? _emptyToNull(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  // Not awaited by setUser() — it's called synchronously by every existing
  // call site (e.g. login_screen.dart), so persistence is fire-and-forget
  // rather than changing setUser()'s public signature to async.
  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUserId, userId ?? '');
    await prefs.setString(_kUserType, userType);
    await prefs.setString(_kToken, token ?? '');
    await prefs.setString(_kPharmacyId, pharmacyId ?? '');
    await prefs.setString(_kStaffName, staffName ?? '');
    await prefs.setString(_kBranchName, branchName ?? '');
    await prefs.setString(_kShiftStart, shiftStart ?? '');
    await prefs.setString(_kShiftEnd, shiftEnd ?? '');
  }

  Future<void> _clearPersisted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUserId);
    await prefs.remove(_kUserType);
    await prefs.remove(_kToken);
    await prefs.remove(_kPharmacyId);
    await prefs.remove(_kStaffName);
    await prefs.remove(_kBranchName);
    await prefs.remove(_kShiftStart);
    await prefs.remove(_kShiftEnd);
  }
}
