// Regression tests for PrescriptionParserService — specifically the two
// label/line-classification bugs that let a same-line trailing label
// ("Patient: Juda Baylan  Sex: Age: 26" -> patientName polluted with
// "Sex: Age: 26") and an unlabeled address line ("Block 4 Lot 12 Upper
// Bicutan, Taguig") leak into fields they don't belong in. Pure text-in,
// struct-out — no network/DB, no dictionary seeding required since these
// use drug names already in the built-in PNF-EML fallback dictionary.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_management_system/pharmacist/models/prescription_scan_result.dart';
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

  group('phantom medicines from letters read as numbers', () {
    test('"Taguig" is not read as a 1g dosage', () {
      final result = PrescriptionParserService.parse(
        'Address: 12 Upper Bicutan, Taguig City\n'
        'Amoxicillin 500mg #21\n',
      );

      expect(result.medicines, hasLength(1));
      expect(result.medicines.single.name.toLowerCase(), contains('amoxicillin'));
    });

    test('letter-for-digit strengths are still corrected', () {
      final result = PrescriptionParserService.parse('Amoxicillin 5OOmg #21\n');

      expect(result.medicines.single.dosage, '500mg');
    });

    test('a strength glued to the name is still read', () {
      final result = PrescriptionParserService.parse('Amoxicillin500mg #21\n');

      expect(result.medicines.single.dosage, '500mg');
    });
  });

  group('Sig frequency and duration', () {
    PrescriptionMedicine parseOne(String sig) => PrescriptionParserService.parse(
      'Metformin 500mg tab #60\nSig: $sig\n',
    ).medicines.single;

    test('how-often and when are both kept', () {
      expect(parseOne('1 tab 2x a day after meals').frequency,
          '2x daily, after meals');
      expect(parseOne('1 tab OD at bedtime').frequency,
          'once daily, at bedtime');
    });

    test('"every N hrs" is read as a frequency', () {
      expect(parseOne('1 tab every 4 hrs PRN').frequency,
          'every 4 hours, as needed');
    });

    test('duration written as x N days, Nd or weeks', () {
      expect(parseOne('1 tab TID x 7 days').duration, '7 days');
      expect(parseOne('1 tab TID x7d').duration, '7 days');
      expect(parseOne('1 tab BID for 2 weeks').duration, '14 days');
    });
  });

  group('doctor name formats', () {
    test('"Dra." prefix', () {
      expect(
        PrescriptionParserService.parse('Dra. Liza Mendoza\n').doctorName,
        'Dra. Liza Mendoza',
      );
    });

    test('name followed by M.D.', () {
      expect(
        PrescriptionParserService.parse('Jose P. Rizal, M.D.\n').doctorName,
        'Jose P. Rizal',
      );
    });
  });

  group('liquid strengths', () {
    test('mg/5ml with a bottle size uses the catalog style', () {
      final m = PrescriptionParserService.parse(
        'Amoxicillin 250mg/5ml susp 60ml #1 bottle\n',
      ).medicines.single;

      expect(m.dosage, '250/60ml');
    });

    test('mg/5ml without a bottle size keeps the concentration', () {
      final m = PrescriptionParserService.parse(
        'Cetirizine 5mg/5ml syrup #1 bottle\n',
      ).medicines.single;

      expect(m.dosage, '5mg/5ml');
    });
  });

  group('unlabeled Sig lines', () {
    test('a number-led instruction line attaches to the previous drug', () {
      final result = PrescriptionParserService.parse(
        'Amoxicillin 500mg #21\n'
        '1 cap 3x a day x 7 days\n'
        'Cetirizine 10mg #14\n',
      );

      expect(result.medicines, hasLength(2));
      expect(result.medicines.first.frequency, '3x daily');
    });

    test('a "Take ..." instruction line is not a medicine', () {
      final result = PrescriptionParserService.parse(
        'Amoxicillin 500mg #21\n'
        'Take 1 cap 30 mins before breakfast\n',
      );

      expect(result.medicines, hasLength(1));
    });
  });
}
