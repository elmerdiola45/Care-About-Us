import 'dart:typed_data';

import 'ocr_service.dart';
import 'groq_ocr_service.dart';
import 'prescription_parser_service.dart';
import 'prescription_result_scorer.dart';
import 'line_ensemble_service.dart';
import 'medicine_dictionary_service.dart';
import 'correction_memory_service.dart';
import '../models/prescription_scan_result.dart';

export '../models/prescription_scan_result.dart';

/// Full prescription-scanning pipeline:
///
///   photo bytes -> [Groq vision OCR] (via our own backend proxy — see
///                   GroqOcrService/GroqOcrController) tried FIRST and
///                   ALONE.
///                     |
///                     | good enough result (PrescriptionResultScorer)
///                     | -> DONE. This is the common case: one network
///                     | call total — the cheapest, lowest-token path,
///                     | since OCR.space never gets spent on a scan Groq
///                     | already nailed.
///                     |
///                     | Groq failed outright, OR its result looks weak
///                     v
///   photo bytes -> OCR.space Engine 2 -> parse -> score
///                     |
///                     | still looks weak -> ALSO try OCR.space Engine 3
///                     | on the same image -> MERGE the two outputs line
///                     | by line (LineEnsembleService — both come from
///                     | the same OCR.space model, so their segmentation
///                     | behavior is close enough that per-line
///                     | index-based alignment is trustworthy here) ->
///                     | parse the merged text ONCE
///                     |
///                     | if BOTH Groq and Engine 2 fail outright
///                     v
///              report failure (nothing left to try)
///
/// TESSERACT.JS REMOVED: it was a consistently weaker reader than
/// OCR.space on this kind of messy cursive handwriting across every real
/// test scan — see PROJECT_LOG or prior commit history for the raw-text
/// comparisons that motivated dropping it. It also added a real,
/// separately-preprocessed image variant, a WASM load, and PSM/OEM
/// tuning to maintain for a net-negative accuracy contribution. Groq +
/// OCR.space(2) + OCR.space(3) covers the same "have more than one
/// opinion on a hard photo" goal without that cost.
///
/// ACCURACY: Engine 2 and Engine 3 are two different OCR.space models
/// with different strengths on the same handwriting — merging their
/// output per-line means a line either one reads cleanly survives even
/// if the other mangles that exact line. This only runs on the minority
/// of scans where Groq AND Engine 2 alone both come up short.
///
/// Medicine names are fuzzy-matched against, in priority order: this
/// pharmacy's own correction memory (names a pharmacist has manually
/// fixed before — see CorrectionMemoryService), then its real
/// inventory dictionary, then a Philippine Essential Medicines List
/// fallback if the backend is unreachable.
///
/// This matching — and the MDRP price lookup that follows it on the
/// review screen (see PriceLookupService) — is completely engine-
/// agnostic: it runs on whatever text [PrescriptionParserService.parse]
/// received, whether that text came from Groq, OCR.space, or a merge of
/// two OCR.space engines. Groq's ONLY job in this pipeline is producing
/// a faithful transcription of the photo (see GroqOcrController's
/// system prompt on the backend) — it never sees this pharmacy's
/// medicine list and never computes a price itself; comparing against
/// the medicine list for pricing is the same offline code path every
/// engine shares.
class PrescriptionOcrService {
  static Future<PrescriptionScanResult> scanPrescription(
    Uint8List imageBytes, {
    required String pharmacyId,
    void Function(String stage)? onStageChanged,
  }) async {
    final totalSw = Stopwatch()..start();
    onStageChanged?.call('Reading handwriting…');

    // NOTE: the dictionary/corrections fetch is started further below,
    // AFTER the Groq call resolves — not here. Both the Groq proxy call
    // and the dictionary/corrections calls hit OUR OWN Laravel backend,
    // and `php artisan serve`'s built-in dev server handles exactly one
    // request at a time (no multi-worker support on Windows, where
    // pcntl-based PHP_CLI_SERVER_WORKERS isn't available at all). Firing
    // them at the same moment made them fight over that single worker —
    // in practice this showed up as `net::ERR_CONNECTION_RESET` on the
    // dictionary/corrections requests, which is worse than it sounds:
    // MedicineDictionaryService/CorrectionMemoryService catch that
    // failure and silently fall back to the generic offline drug list
    // instead of this pharmacy's real inventory, with no visible error
    // to the user. OCR.space doesn't talk to our backend at all, so the
    // dictionary fetch is still safe to overlap with THAT — just not
    // with Groq.

    // ---- Attempt 1: Groq vision OCR (backend-proxied) -------------------
    // Deliberately SEQUENTIAL and ALONE — in the common case (one clean
    // photo, one legible read) this means exactly one network call for
    // the whole scan. The OCR.space fallback further down only ever runs
    // when this fails or comes back weak, so it never costs anything
    // extra on a normal scan. See GroqOcrService for why this is safe to
    // expose client-side (no API key here — it's a proxy call to our own
    // backend) and how token usage is kept minimal on the Groq side.
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

    // Safe to start now — Groq's call to our backend has already
    // finished (success or failure), so the dev server's one worker is
    // free again. This can still safely overlap with OCR.space below,
    // since it doesn't touch our backend either.
    final dictionarySw = Stopwatch()..start();
    final dictionaryFuture =
        Future.wait([
          MedicineDictionaryService.getDictionary(pharmacyId: pharmacyId),
          CorrectionMemoryService.getCorrections(pharmacyId: pharmacyId),
        ]).then((results) {
          dictionarySw.stop();
          // ignore: avoid_print
          print(
            '[TIMING] Dictionary+corrections fetch: ${dictionarySw.elapsedMilliseconds}ms '
            '(started after Groq to avoid contending for the dev server\'s '
            'single worker — see note above)',
          );
          return results;
        });

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
          '(Groq only — OCR.space skipped)',
        );
        return groqParsed;
      }
      // ignore: avoid_print
      print(
        '[DEBUG] Groq result looked weak — falling back to OCR.space below.',
      );
    } else {
      // ignore: avoid_print
      print(
        '[DEBUG] Groq OCR failed (${groqResult.error}) — falling back to '
        'OCR.space below.',
      );
    }

    // ---- Attempt 2: OCR.space Engine 2 -----------------------------------
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

    // By this point the dictionary fetch has almost certainly already
    // finished (the OCR round-trip is the slower of the two in
    // virtually every case) — this await should resolve near-instantly.
    final results = await dictionaryFuture;
    final drugDictionary = results[0] as List<String>;
    final corrections = results[1] as Map<String, String>;

    if (!ocrSpace2.success) {
      totalSw.stop();
      // ignore: avoid_print
      print('[TIMING] TOTAL scan time: ${totalSw.elapsedMilliseconds}ms');
      return PrescriptionScanResult(
        success: false,
        error: groqResult.success ? ocrSpace2.error : groqResult.error,
        engineUsed: 'groq+ocrspace',
        isQuotaExceeded:
            ocrSpace2.isQuotaExceeded || groqResult.isQuotaExceeded,
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
      print('[TIMING] TOTAL scan time: ${totalSw.elapsedMilliseconds}ms');
      return engine2Parsed;
    }

    // ---- Attempt 3: OCR.space Engine 3, merged with Engine 2 ------------
    // Engine 2's read also looked weak — one more OCR.space call on
    // Engine 3, then merge the two engines' output line-by-line instead
    // of picking one whole result and discarding the other.
    onStageChanged?.call('Double-checking hard-to-read lines…');
    final engine3Sw = Stopwatch()..start();
    final ocrSpace3 = await OcrService.extractText(imageBytes, engine: '3');
    engine3Sw.stop();
    // ignore: avoid_print
    print(
      '[TIMING] OCR.space Engine 3 retry (weak Engine 2 result): ${engine3Sw.elapsedMilliseconds}ms',
    );

    if (!ocrSpace3.success) {
      // Engine 3 failed too — Engine 2's weak result is still better
      // than nothing.
      totalSw.stop();
      // ignore: avoid_print
      print('[TIMING] TOTAL scan time: ${totalSw.elapsedMilliseconds}ms');
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
    print('[TIMING] TOTAL scan time: ${totalSw.elapsedMilliseconds}ms');
    return finalParsed;
  }
}
