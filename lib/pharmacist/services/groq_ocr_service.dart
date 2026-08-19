import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

import '../../common/session.dart';

/// Talks to OUR OWN Laravel backend's `/api/ocr/groq-scan` endpoint —
/// this client NEVER calls Groq directly and NEVER holds a Groq API key.
///
/// SECURITY: this is the fix for the exact problem [OcrService] documents
/// at the top of `ocr_service.dart` (a hardcoded `kOcrSpaceApiKey` that
/// anyone can pull out of the compiled app/web bundle). Groq's key lives
/// ONLY in the backend's `.env` (see `GroqOcrController` and
/// `config/services.php` on the Laravel side) and is never sent to, or
/// readable from, this app. The backend also rate-limits this endpoint
/// (see the `throttle` middleware on the route) so a leaked/abused
/// client can't run up the Groq bill on its own.
///
/// TOKEN BUDGET: Groq bills (and rate-limits) roughly by image
/// resolution + output length. Three things keep that small, in order
/// of how much they matter:
///   1. The backend downsizes/recompresses the image before it ever
///      reaches Groq (see `GroqOcrController::prepareImage` — capped at
///      768px / JPEG quality 60), regardless of what the client sends.
///   2. The backend's prompt asks for ONE thing only — a faithful
///      transcription, not medicine names/dosages/structuring — and caps
///      `max_tokens` accordingly. All of the actual "is this a real drug
///      name, what's its dosage, what does this pharmacy charge for it"
///      logic happens afterwards, entirely offline, in
///      [PrescriptionParserService] / [MedicineDictionaryService] /
///      [PriceLookupService] — the same code OCR.space/Tesseract text
///      already goes through. Groq is only ever asked to read
///      handwriting, never to think about it.
///   3. Passing the SAME already-preprocessed (small, binarized) bytes
///      used elsewhere in the pipeline — see [ImagePreprocessorService]
///      — instead of the raw camera photo, means a smaller multipart
///      upload and less work for the backend's own resize step.
class GroqOcrResult {
  final bool success;
  final String rawText;
  final String? error;

  /// True when the failure looks like Groq's rate limit / quota being
  /// hit (the backend maps a 429 from Groq to this) rather than a bad
  /// image — lets the UI show "try again shortly" instead of implying
  /// the photo itself was the problem. Mirrors [OcrResult.isQuotaExceeded].
  final bool isQuotaExceeded;

  const GroqOcrResult({
    required this.success,
    this.rawText = '',
    this.error,
    this.isQuotaExceeded = false,
  });
}

class GroqOcrService {
  // Same backend host as MedicineDictionaryService/CorrectionMemoryService
  // — keep these in sync if you ever change the backend's address (e.g.
  // when moving off `php artisan serve` on localhost to a real host).
  static const String _baseUrl = 'http://127.0.0.1:8000';
  static const String _endpoint = '$_baseUrl/api/ocr/groq-scan';

  /// Sends the (already-preprocessed) image bytes to our backend, which
  /// forwards a resized/recompressed copy to Groq and returns just the
  /// transcribed text. See the class doc above for why this never talks
  /// to Groq directly.
  static Future<GroqOcrResult> extractPrescription(
    Uint8List imageBytes, {
    String filename = 'prescription.jpg',
  }) async {
    try {
      final token = AppSession.instance.token;
      final request = http.MultipartRequest('POST', Uri.parse(_endpoint))
        ..headers['Accept'] = 'application/json'
        ..files.add(
          http.MultipartFile.fromBytes('image', imageBytes, filename: filename),
        );
      if (token != null && token.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $token';
      }

      final streamedResponse = await request.send().timeout(
        // Groq's own inference is fast, but this also covers the
        // backend's resize step + the network round trip — kept in the
        // same ballpark as OcrService's 10s so a stuck Groq call fails
        // over to the OCR.space+Tesseract fallback about as quickly.
        const Duration(seconds: 12),
        onTimeout: () => throw TimeoutException('Groq OCR request timed out.'),
      );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 429) {
        return const GroqOcrResult(
          success: false,
          error: 'Groq OCR rate limit reached. Try again shortly.',
          isQuotaExceeded: true,
        );
      }

      if (response.statusCode != 200) {
        return GroqOcrResult(
          success: false,
          error: 'Groq OCR error (${response.statusCode}): ${response.body}',
        );
      }

      final Map<String, dynamic> data = jsonDecode(response.body);

      if (data['success'] != true) {
        return GroqOcrResult(
          success: false,
          error: data['error']?.toString() ?? 'Unknown Groq OCR error.',
          isQuotaExceeded: data['is_quota_exceeded'] == true,
        );
      }

      final rawText = (data['text'] ?? '').toString().trim();

      if (rawText.isEmpty) {
        return const GroqOcrResult(
          success: false,
          error: 'No text detected in the image.',
        );
      }

      return GroqOcrResult(success: true, rawText: rawText);
    } catch (e) {
      return GroqOcrResult(
        success: false,
        error: 'Network or parsing error: $e',
      );
    }
  }
}
