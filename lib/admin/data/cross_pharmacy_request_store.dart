import 'package:flutter/foundation.dart';

class CrossPharmacyRequest {
  final String id;
  final String rxNumber;
  final String patientName;
  final String requestingPharmacyName;
  final String requestingPharmacyLocation;
  final String requestingStaffName;
  final List<MapEntry<String, int>> medicines;
  final DateTime submittedAt;

  const CrossPharmacyRequest({
    required this.id,
    required this.rxNumber,
    required this.patientName,
    required this.requestingPharmacyName,
    required this.requestingPharmacyLocation,
    required this.requestingStaffName,
    required this.medicines,
    required this.submittedAt,
  });
}

class CrossPharmacyRequestStore extends ChangeNotifier {
  CrossPharmacyRequestStore._();
  static final CrossPharmacyRequestStore instance = CrossPharmacyRequestStore._();

  final List<CrossPharmacyRequest> _pending = [];

  List<CrossPharmacyRequest> get pending => List.unmodifiable(_pending);

  void submit(CrossPharmacyRequest request) {
    _pending.insert(0, request);
    notifyListeners();
  }

  void approve(String id) {
    _pending.removeWhere((r) => r.id == id);
    notifyListeners();
  }

  void reject(String id) {
    _pending.removeWhere((r) => r.id == id);
    notifyListeners();
  }
}
