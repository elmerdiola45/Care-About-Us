// Regression tests for PrescriptionParserService — specifically the two
// label/line-classification bugs that let a same-line trailing label
// ("Patient: Juda Baylan  Sex: Age: 26" -> patientName polluted with
// "Sex: Age: 26") and an unlabeled address line ("Block 4 Lot 12 Upper
// Bicutan, Taguig") leak into fields they don't belong in. Pure text-in,
// struct-out — no network/DB, no dictionary seeding required since these
// use drug names already in the built-in PNF-EML fallback dictionary.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_management_system/pharmacist/services/prescription_parser_service.dart';

void main() {
  group('patient name label truncation', () {
    test(
      'same-line trailing "Sex:"/"Age:" labels are not swallowed into the name',
      () {
        final result = PrescriptionParserService.parse(
          'Patient: Juda Baylan   Sex: Age: 26\n'
          'Amoxicillin 500mg #21\n',
        );

        expect(result.patientName, 'Juda Baylan');
        expect(result.patientAge, 26);
      },
    );

    test('a name with no trailing label is unaffected', () {
      final result = PrescriptionParserService.parse(
        'Patient: Maria Santos\n'
        'Amoxicillin 500mg #21\n',
      );

      expect(result.patientName, 'Maria Santos');
    });

    test('doctor name sharing the same helper also truncates correctly', () {
      final result = PrescriptionParserService.parse(
        'Patient: Maria Santos\n'
        'Doctor: Jane Cruz   License: 12345\n'
        'Amoxicillin 500mg #21\n',
      );

      expect(result.doctorName, 'Jane Cruz');
    });
  });

  group('address line exclusion from medicines', () {
    test(
      'an unlabeled "Block/Lot" address line is not parsed as a medicine',
      () {
        final result = PrescriptionParserService.parse(
          'Patient: Juan Dela Cruz\n'
          'Block 4 Lot 12 Upper Bicutan, Taguig\n'
          'Amoxicillin 500mg #21\n',
        );

        expect(result.medicines, hasLength(1));
        expect(
          result.medicines.single.name.toLowerCase(),
          contains('amoxicillin'),
        );
        expect(
          result.medicines.any(
            (m) =>
                m.name.toLowerCase().contains('block') ||
                m.name.toLowerCase().contains('bicutan'),
          ),
          isFalse,
        );
      },
    );

    test('a barangay-style address line is also excluded', () {
      final result = PrescriptionParserService.parse(
        'Patient: Juan Dela Cruz\n'
        'Brgy. San Isidro, Taguig City\n'
        'Cetirizine 10mg #14\n',
      );

      expect(result.medicines, hasLength(1));
      expect(
        result.medicines.single.name.toLowerCase(),
        contains('cetirizine'),
      );
    });

    test(
      'a real medicine line is still parsed when no address line is present',
      () {
        final result = PrescriptionParserService.parse(
          'Patient: Juan Dela Cruz\n'
          'Amoxicillin 500mg #21\n'
          'Cetirizine 10mg #14\n',
        );

        expect(result.medicines, hasLength(2));
      },
    );
  });
}
