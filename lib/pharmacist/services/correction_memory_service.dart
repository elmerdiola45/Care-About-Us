import 'dart:convert';
import 'package:http/http.dart' as http;

import '../../common/session.dart';

/// Institutional memory of pharmacist corrections to OCR-misread
/// medicine names, scoped per pharmacy.
///
/// This is NOT the OCR engine "learning" — OCR.space is a hosted
/// black-box API and can't be retrained, and Tesseract retraining is a
/// heavyweight offline process, not something that happens from normal
/// scanning. What this actually does: every time a pharmacist corrects
/// a misread name in the review screen, that correction gets
/// remembered. The same handful of doctors write for the same
/// pharmacy repeatedly, so the same handwriting quirks produce the
/// same OCR mistakes repeatedly — this lets the APP get better at a
/// specific pharmacy's specific doctors over time, even though the
/// underlying OCR engines never change at all.
///
/// Ceiling, to be explicit about it: this only helps on a mistake
/// it's already seen corrected once. It's a targeted patch layer on
/// top of the existing dictionary fuzzy-match, not a path to
/// general-purpose accuracy gains on entirely new misreads.
class CorrectionMemoryService {
  static const String _baseUrl = 'http://127.0.0.1:8000';

  static Map<String, String>? _cache; // lowercased ocr text -> corrected name
  static DateTime? _cachedAt;
  static const _cacheTtl = Duration(minutes: 30);

  /// Returns this pharmacy's correction map: OCR misread (lowercased)
  /// -> the name a pharmacist corrected it to. Degrades to an empty map
  /// (not an error) if the backend is unreachable — a missing
  /// correction map just means no corrections get auto-applied this
  /// scan, never blocks or fails the scan itself.
  static Future<Map<String, String>> getCorrections({
    required String pharmacyId,
    bool forceRefresh = false,
  }) async {
    final cacheIsFresh =
        _cache != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheTtl;

    if (!forceRefresh && cacheIsFresh) {
      // ignore: avoid_print
      print(
        'CorrectionMemoryService: serving cached corrections '
        '(${_cache!.length} entries, cached '
        '${DateTime.now().difference(_cachedAt!).inSeconds}s ago) — '
        'NOT re-fetched from backend this call. Expires after 30 '
        'minutes or forceRefresh.',
      );
      return _cache!;
    }

    try {
      final token = AppSession.instance.token;
      final response = await http
          .get(
            Uri.parse('$_baseUrl/api/pharmacies/$pharmacyId/corrections'),
            headers: {
              'Accept': 'application/json',
              if (token != null && token.isNotEmpty)
                'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        // ignore: avoid_print
        print(
          'CorrectionMemoryService: GET /pharmacies/$pharmacyId/corrections '
          'returned ${response.statusCode} — proceeding with no correction memory this scan.',
        );
        return _cache ?? const {};
      }

      final decoded = jsonDecode(response.body);
      final List<dynamic> rawList = decoded is List
          ? decoded
          : (decoded['corrections'] as List<dynamic>? ?? []);

      final map = <String, String>{};
      for (final entry in rawList) {
        if (entry is! Map) continue;
        final ocrText = entry['ocr_text']?.toString().trim().toLowerCase();
        final correctedTo = entry['corrected_to']?.toString().trim();
        if (ocrText == null || ocrText.isEmpty) continue;
        if (correctedTo == null || correctedTo.isEmpty) continue;
        map[ocrText] = correctedTo;
      }

      _cache = map;
      _cachedAt = DateTime.now();
      return map;
    } catch (_) {
      return _cache ?? const {};
    }
  }

  /// Records that a pharmacist changed [ocrText] to [correctedTo] for
  /// this pharmacy. Fire-and-forget by design — logging a correction
  /// should never delay or block saving the actual prescription, so
  /// callers should NOT await this before proceeding with their own
  /// save flow.
  static Future<void> logCorrection({
    required String pharmacyId,
    required String ocrText,
    required String correctedTo,
  }) async {
    final ocr = ocrText.trim();
    final corrected = correctedTo.trim();
    if (ocr.isEmpty || corrected.isEmpty) return;
    if (ocr.toLowerCase() == corrected.toLowerCase()) return;

    try {
      final token = AppSession.instance.token;
      await http
          .post(
            Uri.parse('$_baseUrl/api/pharmacies/$pharmacyId/corrections'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              if (token != null && token.isNotEmpty)
                'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'ocr_text': ocr, 'corrected_to': corrected}),
          )
          .timeout(const Duration(seconds: 5));

      // Keep the in-memory cache in step with what we just logged, so
      // this same session doesn't have to wait for a re-fetch to
      // benefit from a correction just made.
      _cache = {...?_cache, ocr.toLowerCase(): corrected};
    } catch (_) {
      // Best-effort — a failed correction log shouldn't surface as an
      // error to the pharmacist; the prescription itself still saved
      // fine via whatever flow called this.
    }
  }

  static void invalidateCache() {
    _cache = null;
    _cachedAt = null;
  }
}
