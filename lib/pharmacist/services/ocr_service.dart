import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../common/services/app_config.dart';

/// Talks to OUR OWN Laravel backend's `/api/ocr/ocrspace-scan` endpoint —
/// this client NEVER calls OCR.space directly and NEVER holds an OCR.space
/// API key.
///
/// SECURITY: this used to hardcode `kOcrSpaceApiKey` directly in this file,
/// which meant anyone who inspected the compiled app/web bundle could pull
/// the key out and spend its quota (that key was in fact committed to the
/// repo and is burned). The key now lives ONLY in the backend's `.env` —
/// see `OcrSpaceController` and `config/services.php` on the Laravel side —
/// and is never sent to, or readable from, this app. The backend also
/// rate-limits this endpoint (see the `throttle` middleware on the route)
/// so a leaked/abused client can't run up the OCR.space bill on its own.
/// Mirrors [GroqOcrService], which already followed this pattern.
class OcrResult {
  final String fullText;
  final bool success;
  final String? error;

  /// True when the failure looks like the free-tier request quota or
  /// rate limit being hit, rather than a bad image or a genuine parsing
  /// failure — lets the UI show "try again later" instead of implying
  /// the photo itself was the problem.
  final bool isQuotaExceeded;

  const OcrResult({
    required this.fullText,
    required this.success,
    this.error,
    this.isQuotaExceeded = false,
  });
}

class OcrService {
  // Backend address comes from AppConfig.baseUrl (overridable at build
  // time via --dart-define=API_BASE_URL — see app_config.dart), the same
  // source GroqOcrService/MedicineDictionaryService/CorrectionMemoryService use.
  static String get _endpoint => '${AppConfig.baseUrl}/ocr/ocrspace-scan';

  /// Sends the image bytes to our backend, which forwards them to
  /// OCR.space using the server-side key and returns just the
  /// extracted text.
  ///
  /// [engine] lets the caller pick which OCR.space engine to use — '2'
  /// and '3' are both viable for handwriting and don't always agree on
  /// the same image, which is why [PrescriptionOcrService] may call
  /// this twice with different engines on a weak first result rather
  /// than always committing to just one.
  static Future<OcrResult> extractText(
    List<int> imageBytes, {
    String engine = '3',
  }) async {
    try {
      final request = http.MultipartRequest('POST', Uri.parse(_endpoint))
        ..fields['engine'] = engine
        ..files.add(
          http.MultipartFile.fromBytes(
            'image',
            imageBytes,
            filename:
                'prescription_${DateTime.now().millisecondsSinceEpoch}.jpg',
          ),
        );

      final httpSw = Stopwatch()..start();
      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('OCR.space request timed out.'),
      );
      final response = await http.Response.fromStream(streamedResponse);
      httpSw.stop();
      // TEMP INSTRUMENTATION — HTTP round-trip only (network + Laravel + OCR.space)
      // ignore: avoid_print
      print('[TIMING] OCR.space Engine $engine HTTP round-trip: ${httpSw.elapsedMilliseconds}ms');

      if (response.statusCode == 429) {
        return const OcrResult(
          fullText: '',
          success: false,
          error: 'OCR service rate limit reached. Try again shortly.',
          isQuotaExceeded: true,
        );
      }

      if (response.statusCode != 200) {
        return OcrResult(
          fullText: '',
          success: false,
          error: 'OCR.space error (${response.statusCode}): ${response.body}',
        );
      }

      final Map<String, dynamic> data = jsonDecode(response.body);

      if (data['success'] != true) {
        return OcrResult(
          fullText: '',
          success: false,
          error: data['error']?.toString() ?? 'Unknown OCR.space error.',
          isQuotaExceeded: data['is_quota_exceeded'] == true,
        );
      }

      final fullText = (data['text'] ?? '').toString().trim();

      if (fullText.isEmpty) {
        return const OcrResult(
          fullText: '',
          success: false,
          error: 'No text detected in the image.',
        );
      }

      return OcrResult(fullText: fullText, success: true);
    } catch (e) {
      return OcrResult(
        fullText: '',
        success: false,
        error: 'Network or parsing error: $e',
      );
    }
  }
}
