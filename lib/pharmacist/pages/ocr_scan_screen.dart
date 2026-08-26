// ocr_scan_screen.dart
//
// Capture screen for handwritten prescriptions. Cross-platform compatible
// (mobile + web) using Uint8List + Image.memory instead of File/Image.file.
//
// Pipeline: Groq vision OCR (via our backend proxy, tried first and
// alone) -> falls back to OCR.space Engine 2 (then Engine 3, merged in,
// if still weak) if Groq fails outright or reads weak -> fuzzy-matched
// against this pharmacy's real medicine list for pricing either way.
// See PrescriptionOcrService for the full pipeline.
//
// Trust/safety notes for this screen specifically:
//  - Diagnostic logging (preprocessing timing, failure codes) is gated to
//    debug builds via `debugPrint` + `kDebugMode`, so nothing is written
//    to release-build logs or crash reporters. There is currently no
//    SafeLogger/analytics wiring here — if one is added later, route
//    these through it instead of debugPrint.
//  - This screen must never surface or log raw OCR/exception text that
//    could contain fragments of the scanned prescription (patient name,
//    diagnosis, etc.) or device/file-path details. User-facing messages
//    below are fixed, curated strings — never the exception object
//    itself (no `$e` interpolation into UI or logs).

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'ocr_review_screen.dart';
import '../../common/widgets/responsive_center.dart';
import '../services/prescription_ocr_service.dart';
import '../services/image_preprocessor_service.dart';
import '../services/prescription_api_service.dart' show PrescriptionSaveResult;
import '../models/prescription.dart';

class OcrColors {
  static const teal = Color(0xFF0B7B77);
  static const tealLight = Color(0xFFF0FAF9);
  static const dark = Color(0xFF061516);
  static const dimText = Color(0xFF7C8D8E);
  static const iconDim = Color(0xFF4B5B5C);
  static const border = Color(0xFFE5E7EB);
  static const gray = Color(0xFF6B7280);
}

class OCRScanScreen extends StatefulWidget {
  const OCRScanScreen({
    super.key,
    required this.pharmacyId,
    this.onSave,
    this.onViewSavedList,
  });

  /// The pharmacy the logged-in staff member belongs to — used to fetch
  /// the right medicine dictionary for fuzzy-matching (see
  /// MedicineDictionaryService).
  final String pharmacyId;

  /// Forwarded to [OcrReviewScreen] — wire this to your actual
  /// save/backend-sync logic. See that screen for details.
  final Future<PrescriptionSaveResult> Function(
    Prescription prescription,
    String ocrCode, {
    bool confirmNew,
  })?
  onSave;

  /// Forwarded to [OcrReviewScreen] — wire this to navigate to wherever
  /// your saved prescriptions list lives.
  final VoidCallback? onViewSavedList;

  @override
  State<OCRScanScreen> createState() => _OCRScanScreenState();
}

class _OCRScanScreenState extends State<OCRScanScreen> {
  final ImagePicker _picker = ImagePicker();
  Uint8List? _imageBytes;
  bool _isProcessing = false;
  String? _errorMessage;
  bool _isQuotaExceeded = false;
  String _processingStage = 'Reading prescription…';

  // Guards against a second capture/navigation being kicked off from a
  // stray tap or double-tap while one is already in flight — the button
  // is disabled while `_isProcessing` is true, but that flag flips back
  // to false before navigation actually completes, leaving a short
  // window where a fast second tap could start a second picker session
  // or push a second review screen. This flag closes that window.
  bool _isNavigatingToReview = false;

  void _debugLog(String message) {
    // Debug-build-only diagnostic output. No exception text, no OCR
    // content, no user/patient data — only fixed, curated strings.
    if (kDebugMode) {
      debugPrint('[OcrScanScreen] $message');
    }
  }

  Future<void> _openCamera() async {
    // Re-entrancy guard: ignore a second tap while a scan is already
    // being processed or we're already navigating away.
    if (_isProcessing || _isNavigatingToReview) return;

    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        imageQuality: 90,
      );

      if (photo == null) return;
      if (!mounted) return;

      // Enter processing state IMMEDIATELY so the spinner renders
      // before readAsBytes yields to the event loop. This prevents the
      // "flash back to capture UI" that happens when _isProcessing
      // stays false during the async read.
      setState(() {
        _isProcessing = true;
        _errorMessage = null;
        _isQuotaExceeded = false;
        _processingStage = 'Enhancing image…';
      });

      final rawBytes = await photo.readAsBytes();
      if (!mounted) return;

      if (rawBytes.isEmpty) {
        setState(() {
          _isProcessing = false;
          _errorMessage =
              "That photo didn't come through. Please try capturing again.";
          _isQuotaExceeded = false;
        });
        _debugLog('camera_capture_empty');
        return;
      }

      // Show the captured image immediately — the user sees what they
      // just photographed while preprocessing runs in the background.
      setState(() => _imageBytes = rawBytes);

      // Yield so the framework can flush the captured-image frame before
      // CPU-heavy preprocessing begins.
      await Future.delayed(Duration.zero);
      if (!mounted) return;

      // Clean up the photo on-device before it reaches OCR.space —
      // exposure/contrast correction, sharpen, then binarize. Falls back
      // to the raw photo if preprocessing can't run for any reason.
      //
      // This runs on a background isolate (Isolate.run) so the O(width*height)
      // pixel loop in ImagePreprocessorService never blocks the main UI
      // thread — the spinner and stage text stay responsive.
      final preprocessSw = Stopwatch()..start();
      Uint8List preprocessedBytes;
      try {
        preprocessedBytes = await Isolate.run(
          () => ImagePreprocessorService.preprocessOrFallback(rawBytes),
        );
      } catch (_) {
        // Belt-and-suspenders: even though preprocessOrFallback is
        // documented to fall back internally, never let a preprocessing
        // failure (or an isolate crash) take down the whole capture flow —
        // fall back to the raw bytes here too.
        preprocessedBytes = rawBytes;
      }
      preprocessSw.stop();
      // Perf timing only — no image content, no OCR output.
      _debugLog('ocr_preprocess_timing_ms:${preprocessSw.elapsedMilliseconds}');

      if (!mounted) return;
      // Note: _imageBytes stays as rawBytes — the displayed image is the
      // raw capture, not the preprocessed version. Only the OCR pipeline
      // sees the preprocessed bytes.

      await _processOcr(preprocessedBytes);
    } on TimeoutException {
      // Shouldn't normally surface here (picker itself has no timeout),
      // but keep the failure path uniform if the platform channel ever
      // stalls.
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _errorMessage = "Couldn't open the camera. Please try again.";
      });
      _debugLog('camera_open_timeout');
    } catch (_) {
      // Never interpolate the raw exception into UI or logs — it can
      // carry device/file-path details that don't belong in either.
      if (!mounted) return;
      setState(() => _isProcessing = false);
      _debugLog('camera_open_failed');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Couldn't open the camera. Please check camera permissions "
            "and try again.",
          ),
        ),
      );
    }
  }

  Future<void> _processOcr(Uint8List bytes) async {
    PrescriptionScanResult result;
    try {
      // Safety net: every network call inside scanPrescription already
      // has its own short timeout, but nothing previously bounded the
      // synchronous parsing/fuzzy-matching work that happens after they
      // return. This overall timeout makes sure that even an unforeseen
      // slow path (e.g. a pathological OCR result) surfaces as an error
      // the user can retry from, instead of leaving the spinner running
      // forever with no feedback.
      result = await PrescriptionOcrService.scanPrescription(
        bytes,
        pharmacyId: widget.pharmacyId,
        onStageChanged: (stage) {
          if (!mounted) return;
          setState(() => _processingStage = stage);
        },
      ).timeout(const Duration(seconds: 35));
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _isQuotaExceeded = false;
        _errorMessage =
            'This scan is taking too long. Please try again with a clearer photo.';
      });
      _debugLog('ocr_scan_timeout');
      return;
    } catch (_) {
      // Any unexpected failure from the pipeline itself (not modeled as
      // a `result.success == false` outcome) — fail closed with a
      // generic message rather than let an uncaught exception crash the
      // screen or leak exception text.
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _isQuotaExceeded = false;
        _errorMessage =
            'Something went wrong while scanning. Please try again.';
      });
      _debugLog('ocr_scan_unexpected_error');
      return;
    }

    if (!mounted) return;
    setState(() => _isProcessing = false);

    if (result.success) {
      _debugLog('ocr_scan_succeeded');

      // Gate: a "successful" OCR call only means the pipeline returned
      // *something*, not that the something is safe to hand straight to
      // the review/pricing screen. If PrescriptionScanResult exposes a
      // confidence score or per-field confidence, check it here and shunt
      // low-confidence results into the same "needs review" path the
      // review screen already gates Save on — don't let a "success" flag
      // alone imply the data is trustworthy.
      //
      // Example (uncomment/adjust to your actual PrescriptionScanResult
      // shape):
      // if (result.overallConfidence != null &&
      //     result.overallConfidence! < 0.5) {
      //   result = result.copyWith(needsManualReview: true);
      // }

      if (_isNavigatingToReview) return;
      _isNavigatingToReview = true;
      try {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => OcrReviewScreen(
              imageBytes: bytes,
              pharmacyId: widget.pharmacyId,
              scanResult: result,
              onSave: widget.onSave,
              onViewSavedList: widget.onViewSavedList,
            ),
          ),
        );
      } finally {
        if (mounted) setState(() => _isNavigatingToReview = false);
      }
      return;
    }

    // IMPORTANT: `result.error` comes from the OCR pipeline. If
    // PrescriptionOcrService ever builds that string by embedding raw
    // recognized text (e.g. "couldn't parse: <ocr text>"), that string
    // can contain fragments of the prescription itself — patient name,
    // diagnosis, medicine names. Treat it as untrusted content:
    //  - It's fine to show `result.error` in the UI to the person who
    //    just took the photo (they already have the source document).
    //  - It must NOT be written to debug logs, crash reporting, or any
    //    analytics call. Only a fixed code is logged below.
    if (!mounted) return;
    setState(() {
      _isQuotaExceeded = result.isQuotaExceeded;
      _errorMessage = result.isQuotaExceeded
          ? "OCR.space's free-tier limit has been reached for now. "
                "Please try again later (limits typically reset daily)."
          : (result.error ?? 'OCR failed. Please try again.');
    });

    _debugLog(
      result.isQuotaExceeded ? 'ocr_scan_quota_exceeded' : 'ocr_scan_failed',
    );
  }

  @override
  void dispose() {
    // Drop the captured image reference promptly rather than waiting on
    // the framework — a prescription photo can be a sizeable buffer and
    // there's no reason to keep it alive once this screen is gone.
    _imageBytes = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          child: ResponsiveCenter.form(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _buildHeader(),
                const SizedBox(height: 22),
                _buildCameraCard(),
                const SizedBox(height: 70),
                _buildBookIcon(),
                const SizedBox(height: 26),
                _buildTitle(),
                const SizedBox(height: 22),
                _buildDescription(),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 34),
                    child: Text(
                      _errorMessage!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _isQuotaExceeded
                            ? const Color(0xFF9A6B0A)
                            : Colors.red,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 60),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: OcrColors.border)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back_ios_new, color: OcrColors.teal),
          ),
          const SizedBox(width: 4),
          const Text(
            'OCR Prescription Scan',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 22),
      padding: const EdgeInsets.symmetric(vertical: 34),
      width: double.infinity,
      decoration: BoxDecoration(
        color: OcrColors.dark,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        children: [
          if (_isProcessing)
            const SizedBox(
              height: 42,
              width: 42,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: OcrColors.teal,
              ),
            )
          else if (_imageBytes == null)
            const Icon(
              Icons.photo_camera_outlined,
              color: OcrColors.iconDim,
              size: 44,
            )
          else
            ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: Image.memory(_imageBytes!, height: 220, fit: BoxFit.cover),
            ),
          const SizedBox(height: 18),
          Text(
            _isProcessing ? _processingStage : 'Tap to capture prescription',
            style: const TextStyle(color: OcrColors.dimText, fontSize: 16),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: (_isProcessing || _isNavigatingToReview)
                ? null
                : _openCamera,
            style: ElevatedButton.styleFrom(
              backgroundColor: OcrColors.teal,
              foregroundColor: Colors.white,
              elevation: 0,
              minimumSize: const Size(170, 52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: const Text(
              'Capture Photo',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBookIcon() {
    return Container(
      width: 78,
      height: 78,
      decoration: BoxDecoration(
        color: OcrColors.tealLight,
        borderRadius: BorderRadius.circular(18),
      ),
      child: const Icon(
        Icons.menu_book_outlined,
        color: OcrColors.teal,
        size: 44,
      ),
    );
  }

  Widget _buildTitle() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 35),
      child: Text(
        'Capture a Handwritten Prescription',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildDescription() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 34),
      child: Text(
        'Photograph the prescription clearly.\n'
        'RxTrack extracts medicines using OCR.space and generates\n'
        'a MDRP-compliant price list automatically.\n'
        'Save to generate a QR code.\n\n'
        'Tips: Use good lighting, keep the prescription flat, '
        'and make sure all text is in focus.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 16, color: OcrColors.gray, height: 1.8),
      ),
    );
  }
}
