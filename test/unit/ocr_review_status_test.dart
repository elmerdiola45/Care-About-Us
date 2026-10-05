// Review-screen verification: every scanned medicine shows what the OCR
// read ("Read as"), is marked verified / check / not matched, and rows
// marked "check" must be confirmed against the photo before saving.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pharmacy_management_system/pharmacist/models/prescription_scan_result.dart';
import 'package:pharmacy_management_system/pharmacist/pages/ocr_review_screen.dart';
import 'package:pharmacy_management_system/pharmacist/services/medicine_dictionary_service.dart';
import 'package:pharmacy_management_system/pharmacist/services/prescription_parser_service.dart';

void _seedCatalog() {
  MedicineVariant v(int id, String name, String dosage, double price) =>
      MedicineVariant(
        id: id,
        name: name,
        brandName: null,
        dosageForm: dosage,
        unitPrice: price,
      );
  MedicineDictionaryService.debugSeedCache(
    variants: {
      'amoxicillin': [v(1, 'AMOXICILLIN 500 MG.', '500 MG.', 8.5)],
      'cetirizine': [v(2, 'CETIRIZINE 10 MG.', '10 MG.', 5.0)],
    },
    generics: {'amoxicillin': 'AMOXICILLIN', 'cetirizine': 'CETIRIZINE'},
  );
}

void main() {
  tearDown(MedicineDictionaryService.invalidateCache);

  group('parser source text and legibility', () {
    test('each medicine carries its OCR line and the AI legibility', () {
      const text = 'Patient: Juan Dela Cruz\n'
          'Amaxicillin 500mg cap #21\n'
          'Sig: 1 cap TID\n'
          'Cetirizine 10mg tab #10';
      final result = PrescriptionParserService.parse(
        text,
        ocrLines: const [
          OcrLine(text: 'Patient: Juan Dela Cruz', legibility: 'clear'),
          OcrLine(text: 'Amaxicillin 500mg cap #21', legibility: 'partial'),
          OcrLine(text: 'Sig: 1 cap TID', legibility: 'clear'),
          OcrLine(text: 'Cetirizine 10mg tab #10', legibility: 'clear'),
        ],
      );

      expect(result.medicines, hasLength(2));
      expect(result.medicines[0].sourceText, 'Amaxicillin 500mg cap #21');
      expect(result.medicines[0].sourceLegibility, 'partial');
      expect(result.medicines[1].sourceLegibility, 'clear');
    });

    test('legibility is left unknown when lines do not line up', () {
      final result = PrescriptionParserService.parse(
        'Amoxicillin 500mg #21',
        ocrLines: const [OcrLine(text: 'something else', legibility: 'clear')],
      );

      expect(result.medicines.single.sourceText, 'Amoxicillin 500mg #21');
      expect(result.medicines.single.sourceLegibility, '');
    });
  });

  testWidgets('check rows show Read as and must be confirmed to save', (
    tester,
  ) async {
    _seedCatalog();
    tester.view.physicalSize = const Size(500, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final photo = Uint8List.fromList(
      img.encodePng(img.Image(width: 40, height: 60)),
    );
    var saveCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: OcrReviewScreen(
          imageBytes: photo,
          pharmacyId: 'PHARM-001',
          scanResult: const PrescriptionScanResult(
            success: true,
            patientName: 'Juan Dela Cruz',
            patientAge: 34,
            patientGender: 'M',
            doctorName: 'Dr. Maria Santos',
            medicines: [
              PrescriptionMedicine(
                name: 'Amoxicillin',
                dosage: '500mg',
                quantity: '21',
                frequency: '3x daily',
                matchConfidence: 0.91,
                sourceText: 'Amaxicillin 500mg cap #21',
                sourceLegibility: 'partial',
              ),
              PrescriptionMedicine(
                name: 'Cetirizine',
                dosage: '10mg',
                quantity: '10',
                frequency: 'once daily',
                matchConfidence: 1.0,
                sourceText: 'Cetirizine 10mg tab #10',
                sourceLegibility: 'clear',
              ),
            ],
          ),
          onSave: (_, _, {bool confirmNew = false}) async {
            saveCalls++;
            throw StateError('stop after the gate');
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('PRESCRIPTION PHOTO'), findsOneWidget);
    expect(find.textContaining('Amaxicillin 500mg cap #21'), findsOneWidget);
    expect(find.text('1 verified'), findsOneWidget);
    expect(find.text('1 to check'), findsOneWidget);
    expect(
      find.text('AI was unsure reading this line — check it against the photo'),
      findsOneWidget,
    );

    // Saving is blocked until the amber row is confirmed.
    await tester.ensureVisible(find.textContaining('Save'));
    await tester.tap(find.textContaining('Save').last);
    await tester.pump();
    expect(saveCalls, 0);
    expect(find.textContaining('against the photo, then tap Confirm'), findsOneWidget);

    await tester.ensureVisible(find.text('Confirm — matches the photo'));
    await tester.tap(find.text('Confirm — matches the photo'));
    await tester.pump();
    expect(find.text('2 verified'), findsOneWidget);
    expect(find.text('0 to check'), findsOneWidget);
    expect(find.text('Confirm — matches the photo'), findsNothing);
  });
}
