import 'dart:typed_data';

import 'ocr_service.dart';
import 'gemini_ocr_service.dart';
import 'groq_ocr_service.dart';
import 'prescription_parser_service.dart';
import 'prescription_result_scorer.dart';
import 'line_ensemble_service.dart';
import 'medicine_dictionary_service.dart';
import 'correction_memory_service.dart';
import '../models/prescription_scan_result.dart';

export '../models/prescription_scan_result.dart';

class PrescriptionOcrService {
  static Future<PrescriptionScanResult> scanPrescription(
    Uint8List imageBytes, {
    required String pharmacyId,
    void Function(String stage)? onStageChanged,
  }) async {
    final totalSw = Stopwatch()..start();
    onStageChanged?.call('Reading handwriting…');

    // ---- Attempt 1: Gemini vision OCR (backend-proxied) -----------------
    onStageChanged?.call('Reading handwriting with AI…');
    final geminiSw = Stopwatch()..start();
    final geminiResult = await GeminiOcrService.extractPrescription(imageBytes);
    geminiSw.stop();
    // ignore: avoid_print
    print('[TIMING] Gemini vision OCR call: ${geminiSw.elapsedMilliseconds}ms');
    // ignore: avoid_print
    print(
      '[DEBUG] Raw Gemini text:\n---START---\n${geminiResult.rawText}\n---END---',
    );

    // Dictionary/corrections fetch waits until AFTER Gemini resolves, same
    // reasoning as before Groq used to hold that spot — the dev server's
    // single worker can't take both requests at once.
    final dictionarySw = Stopwatch()..start();
    final dictionaryFuture =
        Future.wait([
          MedicineDictionaryService.getDictionary(pharmacyId: pharmacyId),
          CorrectionMemoryService.getCorrections(pharmacyId: pharmacyId),
        ]).then((results) {
          dictionarySw.stop();
          // ignore: avoid_print
          print(
            '[TIMING] Dictionary+corrections fetch: ${dictionarySw.elapsedMilliseconds}ms',
          );
          return results;
        });

    if (geminiResult.success) {
      onStageChanged?.call('Matching medicines…');
      final geminiDictResults = await dictionaryFuture;
      final geminiParsed = PrescriptionParserService.parse(
        geminiResult.rawText,
        engineUsed: 'gemini+parser',
        drugDictionary: geminiDictResults[0] as List<String>,
        corrections: geminiDictResults[1] as Map<String, String>,
      );

      if (!PrescriptionResultScorer.isWeak(geminiParsed)) {
        totalSw.stop();
        // ignore: avoid_print
        print(
          '[TIMING] TOTAL scan time: ${totalSw.elapsedMilliseconds}ms '
          '[PATH: Gemini-only — Groq/OCR.space skipped]',
        );
        return geminiParsed;
      }
      // ignore: avoid_print
      print('[DEBUG] Gemini result looked weak — falling back to Groq below.');
    } else {
      // ignore: avoid_print
      print(
        '[DEBUG] Gemini OCR failed (${geminiResult.error}) — falling back '
        'to Groq below.',
      );
    }

    // ---- Attempt 2: Groq vision OCR (backend-proxied) --------------------
    onStageChanged?.call('Reading handwriting with AI…');
    final groqSw = Stopwatch()..start();
    final groqResult = await GroqOcrService.extractPrescription(imageBytes);
    groqSw.stop();
    // ignore: avoid_print
    print('[TIMING] Groq vision OCR call: ${groqSw.elapsedMilliseconds}ms');
    // ignore: avoid_print
    print(
      '[DEBUG] Raw Groq text:\n---START---\n${groqResult.rawText}\n---END---',
    );

    if (groqResult.success) {
      onStageChanged?.call('Matching medicines…');
      final groqDictResults = await dictionaryFuture;
      final groqParsed = PrescriptionParserService.parse(
        groqResult.rawText,
        engineUsed: 'groq+parser',
        drugDictionary: groqDictResults[0] as List<String>,
        corrections: groqDictResults[1] as Map<String, String>,
      );

      if (!PrescriptionResultScorer.isWeak(groqParsed)) {
        totalSw.stop();
        // ignore: avoid_print
        print(
          '[TIMING] TOTAL scan time: ${totalSw.elapsedMilliseconds}ms '
          '[PATH: Gemini weak/failed + Groq accepted — OCR.space skipped]',
        );
        return groqParsed;
      }
      // ignore: avoid_print
      print(
        '[DEBUG] Groq result also looked weak — falling back to OCR.space below.',
      );
    } else {
      // ignore: avoid_print
      print(
        '[DEBUG] Groq OCR failed (${groqResult.error}) — falling back to '
        'OCR.space below.',
      );
    }

    // ---- Attempt 3: OCR.space Engine 2 -----------------------------------
    onStageChanged?.call('Reading handwriting…');
    final engine2Sw = Stopwatch()..start();
    final ocrSpace2 = await OcrService.extractText(imageBytes, engine: '2');
    engine2Sw.stop();
    // ignore: avoid_print
    print(
      '[TIMING] OCR.space Engine 2 call: ${engine2Sw.elapsedMilliseconds}ms',
    );
    // ignore: avoid_print
    print(
      '[DEBUG] Raw OCR.space text:\n---START---\n${ocrSpace2.fullText}\n---END---',
    );

    final results = await dictionaryFuture;
    final drugDictionary = results[0] as List<String>;
    final corrections = results[1] as Map<String, String>;

    if (!ocrSpace2.success) {
      totalSw.stop();
      // ignore: avoid_print
      print(
        '[TIMING] TOTAL scan time: ${totalSw.elapsedMilliseconds}ms '
        '[PATH: Gemini failed/weak + Groq failed/weak + Engine 2 failed]',
      );
      return PrescriptionScanResult(
        success: false,
        error: groqResult.success
            ? ocrSpace2.error
            : (geminiResult.success ? groqResult.error : geminiResult.error),
        engineUsed: 'gemini+groq+ocrspace',
        isQuotaExceeded:
            ocrSpace2.isQuotaExceeded ||
            groqResult.isQuotaExceeded ||
            geminiResult.isQuotaExceeded,
      );
    }

    onStageChanged?.call('Matching medicines…');
    final engine2Parsed = PrescriptionParserService.parse(
      ocrSpace2.fullText,
      engineUsed: 'ocrspace(engine2)+parser',
      drugDictionary: drugDictionary,
      corrections: corrections,
    );

    if (!PrescriptionResultScorer.isWeak(engine2Parsed)) {
      totalSw.stop();
      // ignore: avoid_print
      print(
        '[TIMING] TOTAL scan time: ${totalSw.elapsedMilliseconds}ms '
        '[PATH: Gemini weak/failed + Groq weak/failed + Engine 2 accepted]',
      );
      return engine2Parsed;
    }

    // ---- Attempt 4: OCR.space Engine 3, merged with Engine 2 ------------
    onStageChanged?.call('Double-checking hard-to-read lines…');
    final engine3Sw = Stopwatch()..start();
    final ocrSpace3 = await OcrService.extractText(imageBytes, engine: '3');
    engine3Sw.stop();
    // ignore: avoid_print
    print(
      '[TIMING] OCR.space Engine 3 retry (weak Engine 2 result): ${engine3Sw.elapsedMilliseconds}ms',
    );

    if (!ocrSpace3.success) {
      totalSw.stop();
      // ignore: avoid_print
      print(
        '[TIMING] TOTAL scan time: ${totalSw.elapsedMilliseconds}ms '
        '[PATH: Gemini + Groq weak/failed + Engine 2 weak + Engine 3 failed]',
      );
      return engine2Parsed;
    }

    final mergedText = LineEnsembleService.merge(
      ocrSpace2.fullText,
      ocrSpace3.fullText,
    );

    final finalParsed = PrescriptionParserService.parse(
      mergedText,
      engineUsed: 'ocrspace(engine2+engine3 merged)+parser',
      drugDictionary: drugDictionary,
      corrections: corrections,
    );

    totalSw.stop();
    // ignore: avoid_print
    print(
      '[TIMING] TOTAL scan time: ${totalSw.elapsedMilliseconds}ms '
      '[PATH: Gemini + Groq weak/failed + Engine 2 weak + Engine 3 merged]',
    );
    return finalParsed;
  }
}
