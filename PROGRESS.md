## Progress

### Completed
- Added `lib/models/prescription.dart` with `QrStatus`, `MedicineItem`, `Prescription`.
- Refactored `lib/saved_prescriptions_store.dart` to store real `Prescription` objects and support status updates.
- Updated `lib/ocr_review_screen.dart` so Save creates a `Prescription` with `QrStatus.pendingQr`.
- Added `lib/qr_detail_screen.dart` (UI scaffold; print placeholder).

### Remaining (still required by spec)
- Match OCR Review UI exactly (scanned note preview, OCR Complete badge, 4 editable fields, MDRP price table, Re-capture + Save Prescription wiring).
- Replace Saved Prescriptions screen action logic (pendingQr generate + status update + navigate; qrGenerated view only).
- Implement real print flow (QR + prescription details) using a print solution.

