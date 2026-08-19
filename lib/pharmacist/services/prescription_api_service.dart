import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../common/session.dart';
import '../models/prescription.dart';

/// Result of a successful (2xx) [PrescriptionApiService.save] call.
///
/// [reopened] is true when the backend matched an existing prescription
/// exactly (same scan resubmitted, or same patient+doctor+date+medicines)
/// and returned that record as-is instead of creating a new one — the
/// caller should discard whatever was just edited and navigate to the
/// existing prescription instead of showing a "saved" success state.
class PrescriptionSaveResult {
  final bool reopened;
  final String prescriptionId;
  final List<String> stockWarnings;

  const PrescriptionSaveResult({
    required this.reopened,
    required this.prescriptionId,
    this.stockWarnings = const [],
  });
}

/// Thrown when the backend finds a highly-similar (but not exact) existing
/// prescription for the same patient and wants explicit confirmation
/// before creating a new one — see PrescriptionController::findPossibleDuplicate.
/// Callers should offer the pharmacist a choice: view the existing
/// prescription, or retry [PrescriptionApiService.save] with
/// `confirmNew: true` to save as a genuinely new prescription anyway.
class PossibleDuplicateException implements Exception {
  final String message;
  final String existingPrescriptionId;

  const PossibleDuplicateException(this.message, this.existingPrescriptionId);

  @override
  String toString() => message;
}

/// Actually persists a completed [Prescription] to the Laravel backend.
///
/// Before this existed, [OCRScanScreen]'s `onSave` callback was never
/// wired to anything in `main.dart` — it defaulted to null, so
/// `widget.onSave?.call(...)` in the review screen silently did
/// nothing. The "Prescription saved as RX-XXXX" success message and
/// generated QR code were purely local UI state; nothing — not the
/// scanned image, not the medicines, not the patient/doctor fields —
/// ever reached the database. This service, wired into `main.dart` via
/// `OCRScanScreen(onSave: PrescriptionApiService.save)`, is what
/// actually makes that call.
///
/// Sends a multipart/form-data POST (not JSON) specifically because the
/// scanned prescription photo has to go in the SAME request as an
/// uploaded file — Laravel's `image` validation rule and
/// `$request->file('image')` on the other end expect exactly this.
/// Medicine line items are sent using bracket-array field names
/// (`medicines[0][name]`, `medicines[0][dosage]`, ...), which Laravel
/// parses into a proper array server-side the same way it would from a
/// JSON body — no backend change needed for that part.
class PrescriptionApiService {
  static const String _baseUrl = 'http://127.0.0.1:8000';

  static Future<PrescriptionSaveResult> save(
    Prescription prescription,
    String ocrCode, {
    bool confirmNew = false,
  }) async {
    final uri = Uri.parse('$_baseUrl/api/prescriptions');
    final request = http.MultipartRequest('POST', uri);

    request.headers['Accept'] = 'application/json';
    final token = AppSession.instance.token;
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }

    request.fields['ocr_code'] = ocrCode;
    request.fields['patient_name'] = prescription.patientName;
    request.fields['patient_age'] = '${prescription.patientAge}';
    request.fields['patient_gender'] = prescription.patientGender;
    request.fields['doctor_name'] = prescription.doctorName;
    request.fields['is_senior'] = prescription.isSenior ? '1' : '0';
    request.fields['date_time'] = prescription.dateTime.toIso8601String();
    request.fields['total_price'] = '${prescription.totalPrice}';
    if (confirmNew) {
      request.fields['confirm_new'] = 'true';
    }

    // Optional fields — only sent when present, so an empty string
    // doesn't overwrite a previously-saved value on a resend/update.
    if (prescription.oscaId != null && prescription.oscaId!.isNotEmpty) {
      request.fields['osca_id'] = prescription.oscaId!;
    }
    if (prescription.licenseNo.isNotEmpty) {
      request.fields['license_no'] = prescription.licenseNo;
    }
    if (prescription.ptNo.isNotEmpty) {
      request.fields['pt_no'] = prescription.ptNo;
    }
    if (prescription.s2.isNotEmpty) {
      request.fields['s2'] = prescription.s2;
    }
    if (prescription.patientAddress != null &&
        prescription.patientAddress!.isNotEmpty) {
      request.fields['patient_address'] = prescription.patientAddress!;
    }
    if (prescription.diagnosis != null && prescription.diagnosis!.isNotEmpty) {
      request.fields['diagnosis'] = prescription.diagnosis!;
    }

    for (var i = 0; i < prescription.medicines.length; i++) {
      final m = prescription.medicines[i];
      request.fields['medicines[$i][name]'] = m.name;
      request.fields['medicines[$i][dosage]'] = m.dosage;
      request.fields['medicines[$i][quantity]'] = '${m.quantity}';
      request.fields['medicines[$i][unit_price]'] = '${m.unitPrice}';
      request.fields['medicines[$i][days_supply]'] =
          '${m.daysSupply > 0 ? m.daysSupply : 1}';
      if (m.brand.isNotEmpty) {
        request.fields['medicines[$i][brand_name]'] = m.brand;
      }
      if (m.duration.isNotEmpty) {
        request.fields['medicines[$i][duration]'] = m.duration;
      }
    }

    if (prescription.imageBytes != null &&
        prescription.imageBytes!.isNotEmpty) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'image',
          prescription.imageBytes!,
          filename: 'rx_$ocrCode.jpg',
        ),
      );
    }

    final streamedResponse = await request.send().timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException(
        'Timed out saving prescription — is the backend running?',
      ),
    );
    final response = await http.Response.fromStream(streamedResponse);

    Map<String, dynamic> body = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        body = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // Not JSON — fall through to the generic error below for non-2xx,
      // or an empty body for a 2xx that somehow isn't JSON.
    }

    if (response.statusCode == 409 && body['possible_duplicate'] == true) {
      final existing = body['existing'];
      final existingId = existing is Map
          ? (existing['prescription_id']?.toString() ?? '')
          : '';
      throw PossibleDuplicateException(
        body['message']?.toString() ??
            'A similar prescription for this patient already exists.',
        existingId,
      );
    }

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception(
        'Failed to save prescription: HTTP ${response.statusCode} '
        '${response.body}',
      );
    }

    final stockWarnings = body['stock_warnings'];

    return PrescriptionSaveResult(
      reopened: body['reopened'] == true,
      prescriptionId: body['prescription_id']?.toString() ?? '',
      stockWarnings: stockWarnings is List
          ? stockWarnings.map((e) => e.toString()).toList()
          : const [],
    );
  }
}
