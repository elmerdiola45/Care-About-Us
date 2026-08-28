// Cross-pharmacy view-only for a fully dispensed prescription:
// the backend returns HTTP 200 with valid=false + fully_dispensed=true and
// the full item list. That must parse as a *valid-for-viewing* state
// (fullyDispensed == true) carrying the dispensed quantities — NOT as a
// generic invalid/expired token.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_management_system/common/services/laravel_api_service.dart';

void main() {
  test('fully_dispensed verify payload parses as fullyDispensed with item quantities', () {
    final json = <String, dynamic>{
      'token': 'secret-token',
      'valid': false,
      'fully_dispensed': true,
      'message': 'This prescription has already been fully dispensed.',
      'prescription_id': 'RX-2026-00042',
      'data': {
        'ocr_code': 'RX-2026-00042',
        'patient_name': 'Jane Cruz',
        'doctor_name': 'Dr. Reyes',
        'medicines': [],
      },
      'prescription_items': [
        {
          'item_id': 'ITM-1',
          'medicine_name': 'Amoxicillin 500mg',
          'prescribed_quantity': 21,
          'dispensed_quantity': 21,
          'remaining_quantity': 0,
          'unit_price': 5.0,
        },
      ],
    };

    final p = LaravelVerifiedPrescription.fromJson(json);

    expect(p.valid, isFalse);
    expect(p.fullyDispensed, isTrue);
    expect(p.remainingItems, hasLength(1));
    expect(p.remainingItems.first.dispensedQuantity, 21);
    expect(p.remainingItems.first.prescribedQuantity, 21);
    expect(p.remainingItems.first.remainingQuantity, 0);
  });

  test('genuine invalid token stays invalid and not fullyDispensed', () {
    final p = LaravelVerifiedPrescription.fromJson(<String, dynamic>{
      'token': 't',
      'valid': false,
      'message': 'QR code has been revoked',
      'data': null,
    });

    expect(p.valid, isFalse);
    expect(p.fullyDispensed, isFalse);
  });
}
