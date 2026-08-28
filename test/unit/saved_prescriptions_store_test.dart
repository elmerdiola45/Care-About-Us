import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmacy_management_system/pharmacist/data/saved_prescriptions_store.dart';
import 'package:pharmacy_management_system/pharmacist/models/prescription.dart';

void main() {
  group('SavedPrescriptionsStore', () {
    test('ocrCode-only matching does not collide on null backendId', () {
      final entryA = PrescriptionEntry(
        ocrCode: 'OCR-A-${DateTime.now().millisecondsSinceEpoch}',
        imageBytes: Uint8List(0),
        rawExtractedText: '',
        prescription: Prescription(
          patientName: 'A',
          patientAge: 30,
          patientGender: 'M',
          doctorName: 'Dr. A',
          licenseNo: '',
          ptNo: '',
          s2: '',
          ocrCode: 'OCR-A-${DateTime.now().millisecondsSinceEpoch}',
          dateTime: DateTime.now(),
          medicines: [],
          totalPrice: 0,
          status: QrStatus.pendingQr,
          dispensingStatus: DispensingStatus.pending,
        ),
        backendId: null,
      );

      final entryB = PrescriptionEntry(
        ocrCode: 'OCR-B-${DateTime.now().millisecondsSinceEpoch}',
        imageBytes: Uint8List(0),
        rawExtractedText: '',
        prescription: Prescription(
          patientName: 'B',
          patientAge: 40,
          patientGender: 'F',
          doctorName: 'Dr. B',
          licenseNo: '',
          ptNo: '',
          s2: '',
          ocrCode: 'OCR-B-${DateTime.now().millisecondsSinceEpoch}',
          dateTime: DateTime.now(),
          medicines: [],
          totalPrice: 0,
          status: QrStatus.pendingQr,
          dispensingStatus: DispensingStatus.pending,
        ),
        backendId: null,
      );

      SavedPrescriptionsStore.instance.insertWithoutSync(entryA);
      SavedPrescriptionsStore.instance.insertWithoutSync(entryB);

      final ocrB = entryB.ocrCode;
      final found = SavedPrescriptionsStore.instance.items.firstWhere(
        (e) => e.ocrCode == ocrB,
      );
      expect(found.prescription.patientName, equals('B'));
    });

    test('effectiveDispensingStatus falls back to medicine quantities when pending', () {
      final prescription = Prescription(
        patientName: 'Test',
        patientAge: 30,
        patientGender: 'M',
        doctorName: 'Dr. Test',
        licenseNo: '',
        ptNo: '',
        s2: '',
        ocrCode: 'OCR-TEST-${DateTime.now().millisecondsSinceEpoch}',
        dateTime: DateTime.now(),
        medicines: [
          MedicineItem(
            name: 'Med1',
            dosage: '500mg',
            quantity: 10,
            disposedQuantity: 10,
          ),
          MedicineItem(
            name: 'Med2',
            dosage: '250mg',
            quantity: 5,
            disposedQuantity: 0,
          ),
        ],
        totalPrice: 100,
        status: QrStatus.pendingQr,
        dispensingStatus: DispensingStatus.pending,
      );

      expect(
        SavedPrescriptionsStore.effectiveDispensingStatus(prescription),
        equals(DispensingStatus.partiallyDispensed),
      );
    });

    test('effectiveDispensingStatus uses stored status when not pending', () {
      final prescription = Prescription(
        patientName: 'Test',
        patientAge: 30,
        patientGender: 'M',
        doctorName: 'Dr. Test',
        licenseNo: '',
        ptNo: '',
        s2: '',
        ocrCode: 'OCR-TEST-${DateTime.now().millisecondsSinceEpoch}',
        dateTime: DateTime.now(),
        medicines: [
          MedicineItem(
            name: 'Med1',
            dosage: '500mg',
            quantity: 10,
            disposedQuantity: 10,
          ),
        ],
        totalPrice: 100,
        status: QrStatus.qrGenerated,
        dispensingStatus: DispensingStatus.fullyDispensed,
      );

      expect(
        SavedPrescriptionsStore.effectiveDispensingStatus(prescription),
        equals(DispensingStatus.fullyDispensed),
      );
    });

    test('computeDispensingStatus produces fullyDispensed when all medicines met', () {
      final medicines = [
        MedicineItem(name: 'Med1', dosage: '500mg', quantity: 10, disposedQuantity: 10),
        MedicineItem(name: 'Med2', dosage: '250mg', quantity: 5, disposedQuantity: 5),
      ];

      expect(
        SavedPrescriptionsStore.computeDispensingStatus(medicines),
        equals(DispensingStatus.fullyDispensed),
      );
    });

    test('computeDispensingStatus produces partiallyDispensed when some medicines met', () {
      final medicines = [
        MedicineItem(name: 'Med1', dosage: '500mg', quantity: 10, disposedQuantity: 7),
        MedicineItem(name: 'Med2', dosage: '250mg', quantity: 5, disposedQuantity: 0),
      ];

      expect(
        SavedPrescriptionsStore.computeDispensingStatus(medicines),
        equals(DispensingStatus.partiallyDispensed),
      );
    });

    test('computeDispensingStatus produces overDispensing when exceeded', () {
      final medicines = [
        MedicineItem(name: 'Med1', dosage: '500mg', quantity: 10, disposedQuantity: 12),
      ];

      expect(
        SavedPrescriptionsStore.computeDispensingStatus(medicines),
        equals(DispensingStatus.overDispensing),
      );
    });

    test('replaceOrInsert updates existing entry by ocrCode', () {
      final ocr = 'OCR-REPLACE-${DateTime.now().millisecondsSinceEpoch}';
      final entry1 = PrescriptionEntry(
        ocrCode: ocr,
        imageBytes: Uint8List(0),
        rawExtractedText: '',
        prescription: Prescription(
          patientName: 'Original',
          patientAge: 30,
          patientGender: 'M',
          doctorName: 'Dr. A',
          licenseNo: '',
          ptNo: '',
          s2: '',
          ocrCode: ocr,
          dateTime: DateTime.now(),
          medicines: [],
          totalPrice: 0,
          status: QrStatus.pendingQr,
          dispensingStatus: DispensingStatus.pending,
        ),
        backendId: null,
      );

      final entry2 = PrescriptionEntry(
        ocrCode: ocr,
        imageBytes: Uint8List(0),
        rawExtractedText: '',
        prescription: Prescription(
          patientName: 'Updated',
          patientAge: 30,
          patientGender: 'M',
          doctorName: 'Dr. B',
          licenseNo: '',
          ptNo: '',
          s2: '',
          ocrCode: ocr,
          dateTime: DateTime.now(),
          medicines: [],
          totalPrice: 0,
          status: QrStatus.qrGenerated,
          dispensingStatus: DispensingStatus.partiallyDispensed,
        ),
        backendId: 'BACKEND-1',
      );

      SavedPrescriptionsStore.instance.insertWithoutSync(entry1);
      SavedPrescriptionsStore.instance.replaceOrInsert(entry2);

      final found = SavedPrescriptionsStore.instance.items.firstWhere((e) => e.ocrCode == ocr);
      expect(found.prescription.patientName, equals('Updated'));
      expect(found.backendId, equals('BACKEND-1'));
    });

    test('post-dispense store refresh returns updated medicines and status', () {
      final ocr = 'OCR-DISPENSE-${DateTime.now().millisecondsSinceEpoch}';
      final original = PrescriptionEntry(
        ocrCode: ocr,
        imageBytes: Uint8List(0),
        rawExtractedText: '',
        prescription: Prescription(
          patientName: 'Patient',
          patientAge: 30,
          patientGender: 'M',
          doctorName: 'Dr. A',
          licenseNo: '',
          ptNo: '',
          s2: '',
          ocrCode: ocr,
          dateTime: DateTime.now(),
          medicines: [
            MedicineItem(
              name: 'Med1',
              dosage: '500mg',
              quantity: 10,
              disposedQuantity: 0,
            ),
          ],
          totalPrice: 100,
          status: QrStatus.pendingQr,
          dispensingStatus: DispensingStatus.pending,
        ),
        backendId: null,
      );

      SavedPrescriptionsStore.instance.insertWithoutSync(original);

      final updated = PrescriptionEntry(
        ocrCode: ocr,
        imageBytes: Uint8List(0),
        rawExtractedText: '',
        prescription: Prescription(
          patientName: 'Patient',
          patientAge: 30,
          patientGender: 'M',
          doctorName: 'Dr. A',
          licenseNo: '',
          ptNo: '',
          s2: '',
          ocrCode: ocr,
          dateTime: DateTime.now(),
          medicines: [
            MedicineItem(
              name: 'Med1',
              dosage: '500mg',
              quantity: 10,
              disposedQuantity: 10,
            ),
          ],
          totalPrice: 100,
          status: QrStatus.qrGenerated,
          dispensingStatus: DispensingStatus.fullyDispensed,
        ),
        backendId: 'BACKEND-1',
      );

      SavedPrescriptionsStore.instance.replaceOrInsert(updated);

      final found = SavedPrescriptionsStore.instance.items.firstWhere((e) => e.ocrCode == ocr);
      expect(found.prescription.dispensingStatus, equals(DispensingStatus.fullyDispensed));
      expect(found.prescription.medicines.first.disposedQuantity, equals(10));
      expect(found.backendId, equals('BACKEND-1'));
      expect(
        SavedPrescriptionsStore.effectiveDispensingStatus(found.prescription),
        equals(DispensingStatus.fullyDispensed),
      );
    });
  });
}
