// session.dart
//
// Holds the currently logged-in user so screens can tag created
// prescriptions with the correct pharmacist/dispenser and home pharmacy.
// Also mirrors the session to persistent storage so it survives a page
// refresh or app relaunch — see restore(). On web this is per-tab
// (sessionStorage), everywhere else it's SharedPreferences — see
// session_storage.dart.

import 'session_storage.dart';

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
    final storedToken = await storageGet(_kToken);
    final storedUserId = await storageGet(_kUserId);
    if (storedToken == null ||
        storedToken.isEmpty ||
        storedUserId == null ||
        storedUserId.isEmpty) {
      return false;
    }

    userId = storedUserId;
    token = storedToken;
    userType = await storageGet(_kUserType) ?? '';
    pharmacyId = _emptyToNull(await storageGet(_kPharmacyId));
    staffName = _emptyToNull(await storageGet(_kStaffName));
    branchName = _emptyToNull(await storageGet(_kBranchName));
    shiftStart = _emptyToNull(await storageGet(_kShiftStart));
    shiftEnd = _emptyToNull(await storageGet(_kShiftEnd));
    return true;
  }

  String? _emptyToNull(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  // Not awaited by setUser() — it's called synchronously by every existing
  // call site (e.g. login_screen.dart), so persistence is fire-and-forget
  // rather than changing setUser()'s public signature to async.
  Future<void> _persist() async {
    await storageSet(_kUserId, userId ?? '');
    await storageSet(_kUserType, userType);
    await storageSet(_kToken, token ?? '');
    await storageSet(_kPharmacyId, pharmacyId ?? '');
    await storageSet(_kStaffName, staffName ?? '');
    await storageSet(_kBranchName, branchName ?? '');
    await storageSet(_kShiftStart, shiftStart ?? '');
    await storageSet(_kShiftEnd, shiftEnd ?? '');
  }

  Future<void> _clearPersisted() async {
    await storageRemove(_kUserId);
    await storageRemove(_kUserType);
    await storageRemove(_kToken);
    await storageRemove(_kPharmacyId);
    await storageRemove(_kStaffName);
    await storageRemove(_kBranchName);
    await storageRemove(_kShiftStart);
    await storageRemove(_kShiftEnd);
  }
}
