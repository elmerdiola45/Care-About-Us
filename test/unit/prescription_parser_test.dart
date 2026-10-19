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
          'twice daily, after meals');
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

  group('patterns from real prescription photos', () {
    test('"S ..." and "give ..." lines are Sig text, not medicines', () {
      final result = PrescriptionParserService.parse(
        'Cetirizine 10 mg tab #10\n'
        'S 1 tab 1x a day at bedtime\n'
        'Procaterol 5mcg/1ml\n'
        'give 4ml twice a day x 7days\n',
      );

      expect(result.medicines, hasLength(2));
      expect(result.medicines.first.frequency, 'once daily, at bedtime');
      expect(result.medicines.last.duration, '7 days');
    });

    test('brand and quantity on the next lines attach to the drug', () {
      final result = PrescriptionParserService.parse(
        '1 Telmisartan 40mg\n'
        'tabs # 10\n'
        '1 tab daily\n'
        'Co Amoxiclav 625\n'
        '(Augmentin 625)\n'
        '#14\n',
      );

      expect(result.medicines, hasLength(2));
      expect(result.medicines[0].quantity, '10');
      expect(result.medicines[0].frequency, 'once daily');
      expect(result.medicines[1].brand, 'Augmentin');
      expect(result.medicines[1].quantity, '14');
    });

    test('morning-noon-night schedule', () {
      final result = PrescriptionParserService.parse(
        'Ambroxol 30mg tab # 21\nSig: 1 tablet 3x a day\n1-1-1\n'
        'Losartan 50mg #30\nS 1 - 0 - 1\n',
      );

      expect(result.medicines[1].frequency, 'twice daily');
    });

    test('a Sig line does not swallow a misspelled next drug', () {
      final result = PrescriptionParserService.parse(
        'Cetirizine 10 mg tab #10\n'
        'S 1 tab 1x a day at bedtime\n'
        '3 Guiafenasin + PPA + Paracetamol\n'
        '(Mucoruss) cap # 20\n',
      );

      expect(result.medicines, hasLength(2));
      // Kept as the combination product it is, not reduced to one part.
      expect(result.medicines.last.name, startsWith('Guaifenesin + '));
      expect(result.medicines.last.name, endsWith(' + Paracetamol'));
      expect(result.medicines.last.quantity, '20');
    });

    test('doctor names with particles and RN, MD', () {
      expect(
        PrescriptionParserService.parse(
          'Maria Clara de la Cruz, MD\n',
        ).doctorName,
        'Maria Clara de la Cruz',
      );
      expect(
        PrescriptionParserService.parse(
          'JUAN PAOLO J. SANTOS, RN, MD\n',
        ).doctorName,
        'JUAN PAOLO J. SANTOS',
      );
    });

    test('the doctor line added by the backend wins over a scribble', () {
      // The backend appends "Doctor: ..." from the name it found anywhere
      // on the page (letterhead, stamp, under the signature).
      expect(
        PrescriptionParserService.parse(
          'Patient: Juan Dela Cruz\n'
          'Amoxicillin 500mg #21\n'
          'Doctor [illegible]\n'
          'Lic. No 12345\n'
          'Doctor: JUAN P. SANTOS\n',
        ).doctorName,
        'JUAN P. SANTOS',
      );
    });

    test("\"Patient's Name:\" label", () {
      expect(
        PrescriptionParserService.parse(
          "Patient's Name: Juan Dela Cruz\nAmoxicillin 500mg #21\n",
        ).patientName,
        'Juan Dela Cruz',
      );
    });
  });

  group('more real layouts', () {
    test('Tagalog time-of-day words before the drug', () {
      final result = PrescriptionParserService.parse(
        'gabi (1) Atorvastatin 40mg tab #60 -10\n'
        '1 tab OD\n'
        'umaga tanghali gabi (1) x Betahistine 16mg tab #30\n',
      );
      expect(result.medicines.map((m) => m.name), [
        'Atorvastatin',
        'Betahistine',
      ]);
      expect(result.medicines.first.quantity, '60');
      expect(result.medicines.last.frequency, '3x daily');
    });

    test('quantity after a dash, but never from a 1-0-1 schedule', () {
      final result = PrescriptionParserService.parse(
        'Sambong tab - 60\nSig. 1 tab daily\nLosartan 50mg\n1 - 0 - 1\n',
      );
      expect(result.medicines.first.quantity, '60');
      expect(result.medicines, hasLength(2));
    });

    test('a line the AI tagged "other" is not a medicine', () {
      final result = PrescriptionParserService.parse(
        'Levocetirizine 5mg #10\nCo-Allergy\n',
        ocrLines: const [
          OcrLine(text: 'Levocetirizine 5mg #10', section: 'medicine'),
          OcrLine(text: 'Co-Allergy', section: 'other'),
        ],
      );
      expect(result.medicines, hasLength(1));
    });

    test('an instruction line with a "#" is Sig plus quantity', () {
      final result = PrescriptionParserService.parse(
        'Losartan 100mg Tab\n1x1 day #30\nAmlodipine 10mg tab\n1x1 day #30\n',
        ocrLines: const [
          OcrLine(text: 'Losartan 100mg Tab', section: 'medicine'),
          OcrLine(text: '1x1 day #30', section: 'instruction'),
          OcrLine(text: 'Amlodipine 10mg tab', section: 'medicine'),
          OcrLine(text: '1x1 day #30', section: 'instruction'),
        ],
      );
      expect(result.medicines.map((m) => m.name), ['Losartan', 'Amlodipine']);
      expect(result.medicines.map((m) => m.quantity), ['30', '30']);
    });

    test('a Sig line stops at a line the AI tagged as a medicine', () {
      final result = PrescriptionParserService.parse(
        'Sambong tab - 60\nSig. 1 tab daily.\nDiosmin + H - 30\n',
        ocrLines: const [
          OcrLine(text: 'Sambong tab - 60', section: 'medicine'),
          OcrLine(text: 'Sig. 1 tab daily.', section: 'instruction'),
          OcrLine(text: 'Diosmin + H - 30', section: 'medicine'),
        ],
      );
      expect(result.medicines, hasLength(2));
      expect(result.medicines.last.quantity, '30');
    });
  });

  group('quantity', () {
    PrescriptionMedicine one(String text) =>
        PrescriptionParserService.parse(text).medicines.single;

    test('a "#" quantity wins over the dose on the same line', () {
      expect(one('Losartan 50mg 1 tab OD #30\n').quantity, '30');
    });

    test('Roman numerals and parenthesized counts', () {
      expect(one('Amoxicillin 500mg cap #XXI\n').quantity, '21');
      expect(one('Cetirizine 10mg tab # (10)\n').quantity, '10');
      expect(one('Ambroxol 30mg tab Qty: 15\n').quantity, '15');
    });

    test('License/PTR "No." lines are not quantities', () {
      final result = PrescriptionParserService.parse(
        'Amoxicillin 500mg #21\nLic. No. 0123456\nPTR No. 7654321\n',
      );
      expect(result.medicines, hasLength(1));
    });

    test('a dose before a frequency is not a quantity', () {
      final m = one('Losartan 50mg 1 tab twice a day\n');
      expect(m.quantity, '');
      expect(m.quantityEstimated, isTrue);
    });

    test('a written quantity is not marked as estimated', () {
      expect(one('Amoxicillin 500mg #21\n').quantityEstimated, isFalse);
    });

    test('missing quantity is estimated from the Sig', () {
      final cefuroxime = one(
        'Cefuroxime 500mg #\nSig 1 tab every 12hrs / 7days\n',
      );
      expect(cefuroxime.quantity, '14');
      expect(cefuroxime.quantityBasis, contains('1 tab × 2/day × 7 days'));

      expect(
        one('Montelukast 5mg tab\ntake 1 tablet once a day x 14days\n').quantity,
        '14',
      );
      expect(
        one('Escitalopram 10mg tab\nSig. take 1/2 tab once a day x 30 days\n')
            .quantity,
        '15',
      );
    });

    test('a syrup is counted in bottles', () {
      final m = one(
        'Amoxicillin 250mg/5ml susp 60ml\nSig: 5ml 3x a day x 7 days\n',
      );
      expect(m.quantity, '2'); // 105 ml in 60 ml bottles
      expect(m.quantityBasis, contains('105 ml'));
    });

    test('a syrup without a bottle size defaults to 1 and says so', () {
      final m = one(
        'Cetirizine 5mg/5ml syrup\nSig: 2.5ml once a day x 7 days\n',
      );
      expect(m.quantity, '1');
      expect(m.quantityBasis, contains('bottle size not written'));
    });

    test('no quantity and no Sig to estimate from', () {
      final m = one('Losartan 50mg\n');
      expect(m.quantity, '');
      expect(m.quantityBasis, contains('not written'));
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
