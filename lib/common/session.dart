// session.dart
//
// Holds the currently logged-in user so screens can tag created
// prescriptions with the correct pharmacist/dispenser and home pharmacy.

class AppSession {
  AppSession._();

  static final AppSession instance = AppSession._();

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
  }
}
