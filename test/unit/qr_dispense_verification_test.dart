// Guards against the offline QR-dispensing bypass: unverified / demo
// prescription data must never be marked as backend-verified, and must
// carry no backendId (the dispense screen refuses to record a fill
// without one).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_management_system/pharmacist/pages/functional_qr_scanner_screen.dart';

void main() {
  test('demo() prescription is NOT verified and has no backendId', () {
    final p = ScannedPrescription.demo('anything');
    expect(p.isVerifiedQrData, isFalse);
    expect(p.backendId, isNull);
  });

  test('fromQr() local-JSON payload is NOT verified and has no backendId', () {
    final raw = jsonEncode({
      'rxNo': 'RX-2026-00123',
      'patientName': 'Test Patient',
      'medicines': [
        {'name': 'Amoxicillin', 'dosage': '500mg', 'quantity': 21},
      ],
    });
    final p = ScannedPrescription.fromQr(raw);
    expect(p.rxNo, 'RX-2026-00123'); // it did parse the payload
    expect(p.isVerifiedQrData, isFalse);
    expect(p.backendId, isNull);
  });

  test('fromQr() on an unrecognized (non-JSON) QR falls back to demo, '
      'still unverified', () {
    final p = ScannedPrescription.fromQr('https://example.test/verify/abc');
    expect(p.isVerifiedQrData, isFalse);
    expect(p.backendId, isNull);
  });
}
