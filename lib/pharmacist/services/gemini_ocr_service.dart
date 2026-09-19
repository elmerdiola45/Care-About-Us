import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../../common/services/app_config.dart';
import '../../common/session.dart';

/// Talks to OUR OWN Laravel backend's `/api/ocr/gemini-scan` endpoint —
/// this client NEVER calls Gemini directly and NEVER holds a Gemini API
/// key. Mirrors [GroqOcrService] exactly, just pointed at a different
/// backend route/controller (add a `GeminiOcrController` on the Laravel
/// side, same shape as `GroqOcrController`, with the key in `.env`).
class GeminiOcrResult {
  final bool success;
  final String rawText;
  final String? error;

  /// True when the failure looks like Gemini's rate limit / quota being
  /// hit (backend should map a 429 from Gemini to this), same meaning as
  /// [GroqOcrResult.isQuotaExceeded] / [OcrResult.isQuotaExceeded].
  final bool isQuotaExceeded;

  const GeminiOcrResult({
    required this.success,
    this.rawText = '',
    this.error,
    this.isQuotaExceeded = false,
  });
}

class GeminiOcrService {
  // Same AppConfig.baseUrl source every other service in this pipeline
  // uses (overridable via --dart-define=API_BASE_URL).
  static String get _endpoint => '${AppConfig.baseUrl}/ocr/gemini-scan';

  /// Sends the (already-preprocessed) image bytes to our backend, which
  /// forwards a resized/recompressed copy to Gemini and returns just the
  /// transcribed text.
  static Future<GeminiOcrResult> extractPrescription(
    Uint8List imageBytes, {
    String filename = 'prescription.jpg',
  }) async {
    try {
      final token = AppSession.instance.token;
      final request = http.MultipartRequest('POST', Uri.parse(_endpoint))
        ..headers['Accept'] = 'application/json'
        ..files.add(
          http.MultipartFile.fromBytes(
            'image',
            imageBytes,
            filename: filename,
            contentType: MediaType('image', 'jpeg'),
          ),
        );
      if (token != null && token.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $token';
      }

      final streamedResponse = await request.send().timeout(
        // Kept in the same ballpark as Groq/OCR.space so a stuck Gemini
        // call fails over to Groq (and then OCR.space) about as quickly.
        const Duration(seconds: 15),
        onTimeout: () =>
            throw TimeoutException('Gemini OCR request timed out.'),
      );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 429) {
        return const GeminiOcrResult(
          success: false,
          error: 'Gemini OCR rate limit reached. Try again shortly.',
          isQuotaExceeded: true,
        );
      }

      if (response.statusCode != 200) {
        return GeminiOcrResult(
          success: false,
          error: 'Gemini OCR error (${response.statusCode}): ${response.body}',
        );
      }

      final Map<String, dynamic> data = jsonDecode(response.body);

      if (data['success'] != true) {
        return GeminiOcrResult(
          success: false,
          error: data['error']?.toString() ?? 'Unknown Gemini OCR error.',
          isQuotaExceeded: data['is_quota_exceeded'] == true,
        );
      }

      final rawText = (data['text'] ?? '').toString().trim();

      if (rawText.isEmpty) {
        return const GeminiOcrResult(
          success: false,
          error: 'No text detected in the image.',
        );
      }

      return GeminiOcrResult(success: true, rawText: rawText);
    } catch (e) {
      return GeminiOcrResult(
        success: false,
        error: 'Network or parsing error: $e',
      );
    }
  }
}
