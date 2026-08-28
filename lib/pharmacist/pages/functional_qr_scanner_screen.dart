import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../common/services/laravel_api_service.dart';
import '../../common/session.dart';
import '../../common/utils/qr_token_parser.dart';

import 'dispense_screen.dart';

class ScanColors {
  static const background = Color(0xFF0A0F0D);
  static const surface = Color(0xFF15201D);
  static const teal = Color(0xFF14B8A6);
  static const text = Color(0xFFE8F1EE);
  static const muted = Color(0xFF9AB0AA);
  static const border = Color(0xFF294039);
}

class PrescriptionMedicine {
  final String name;
  final String strength;
  final int prescribedQuantity;
  final int stock;
  final double unitPrice;

  const PrescriptionMedicine({
    required this.name,
    required this.strength,
    required this.prescribedQuantity,
    required this.stock,
    required this.unitPrice,
  });

  factory PrescriptionMedicine.fromJson(Map<String, dynamic> json) {
    final quantity = _intValue(
      json['quantity'] ?? json['prescribedQuantity'],
      1,
    );
    return PrescriptionMedicine(
      name: _stringValue(
        json['name'] ?? json['medicine'],
        'Unspecified medicine',
      ),
      strength: _stringValue(json['strength'] ?? json['dose'], ''),
      prescribedQuantity: quantity,
      stock: _intValue(json['stock'], quantity * 3),
      unitPrice: _doubleValue(json['unitPrice'] ?? json['price'], 12.50),
    );
  }
}

class ScannedPrescription {
  final String rxNo;
  final String patientName;
  final int? patientAge;
  final String? patientSex;
  final String prescriber;
  final String issuedDate;
  final List<PrescriptionMedicine> medicines;
  final bool isVerifiedQrData;
  final String rawValue;
  final String? backendId;
  // Backend verified the token but the prescription is already fully
  // dispensed — the scanner must show the "already fully dispensed"
  // message and STOP, never open the Dispense screen.
  final bool isFullyDispensed;

  const ScannedPrescription({
    required this.rxNo,
    required this.patientName,
    this.patientAge,
    this.patientSex,
    required this.prescriber,
    required this.issuedDate,
    required this.medicines,
    required this.isVerifiedQrData,
    required this.rawValue,
    this.backendId,
    this.isFullyDispensed = false,
  });

  factory ScannedPrescription.fromQr(String rawValue) {
    try {
      final decoded = jsonDecode(rawValue);
      if (decoded is Map) {
        final data = Map<String, dynamic>.from(decoded);
        final rxNo = _stringValue(
          data['rxNo'] ??
              data['rxNumber'] ??
              data['ocrCode'] ??
              data['ocr_code'],
        );
        final patient = _stringValue(
          data['patientName'] ?? data['patient'] ?? data['patient_name'],
        );
        final rawMedicines = data['medicines'] ?? data['items'];
        if (rxNo.isNotEmpty &&
            rawMedicines is List &&
            rawMedicines.isNotEmpty) {
          return ScannedPrescription(
            rxNo: rxNo,
            patientName: patient.isNotEmpty ? patient : 'Unknown Patient',
            patientAge: _intOrNull(
              data['patientAge'] ?? data['age'] ?? data['patient_age'],
            ),
            patientSex: _stringOrNull(
              data['patientSex'] ??
                  data['sex'] ??
                  data['patientGender'] ??
                  data['patient_gender'],
            ),
            prescriber: _stringValue(
              data['prescriber'] ??
                  data['doctor'] ??
                  data['doctorName'] ??
                  data['doctor_name'],
              'Not specified',
            ),
            issuedDate: _stringValue(
              data['issuedDate'] ??
                  data['date'] ??
                  data['dateTime'] ??
                  data['date_time'],
              'Today',
            ),
            medicines: rawMedicines
                .whereType<Map>()
                .map(
                  (item) => PrescriptionMedicine.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(),
            // NOT backend-verified — this is a local-JSON QR payload
            // (the offline fallback format), parsed on-device with no
            // token check. Dispensing must not treat it as verified;
            // the dispense screen requires a real backendId.
            isVerifiedQrData: false,
            rawValue: rawValue,
          );
        }
      }
    } catch (_) {
      // A non-JSON QR is still a successful camera scan; pass raw value through.
    }
    return ScannedPrescription.demo(rawValue);
  }

  static Future<ScannedPrescription> fromQrWithBackend(String rawValue) async {
    try {
      final decoded = jsonDecode(rawValue);
      if (decoded is Map) {
        final data = Map<String, dynamic>.from(decoded);
        final token = _stringValue(data['token'] ?? data['t']);
        if (token.isNotEmpty) {
          final api = LaravelApiService(token: AppSession.instance.token);
          final verified = await api.verifyQrToken(token);
          if (verified.fullyDispensed) {
            return _fullyDispensedResult(verified, rawValue);
          }
          if (verified.valid) {
            final remainingByName = <String, LaravelPrescriptionItemQuantity>{
              for (final r in verified.remainingItems)
                r.medicineName.toLowerCase(): r,
            };
            return ScannedPrescription(
              rxNo: verified.ocrCode,
              patientName: verified.patientName,
              patientAge: verified.patientAge,
              patientSex: verified.patientGender,
              prescriber: verified.doctorName,
              issuedDate: _formatDateTime(verified.dateTime),
              medicines: verified.medicines
                  .map(
                    (m) {
                      final r = remainingByName[m.name.toLowerCase()];
                      return PrescriptionMedicine(
                        name: m.name,
                        strength: m.dosage ?? '',
                        prescribedQuantity: m.quantity,
                        stock: r?.remainingQuantity ?? m.quantity,
                        unitPrice: r?.unitPrice ?? m.unitPrice,
                      );
                    },
                  )
                  .toList(),
              isVerifiedQrData: true,
              rawValue: rawValue,
              backendId: verified.prescriptionId,
            );
          }
        }
      }
    } on LaravelApiException {
      rethrow;
    } catch (_) {
      // Fallback to local parsing
    }

    final tokenFromUrl = extractTokenFromUrl(rawValue);
    if (tokenFromUrl.isNotEmpty) {
      try {
        final api = LaravelApiService(token: AppSession.instance.token);
        final verified = await api.verifyQrToken(tokenFromUrl);
        if (verified.fullyDispensed) {
          return _fullyDispensedResult(verified, rawValue);
        }
        if (verified.valid) {
          final remainingByName = <String, LaravelPrescriptionItemQuantity>{
            for (final r in verified.remainingItems)
              r.medicineName.toLowerCase(): r,
          };
          return ScannedPrescription(
            rxNo: verified.ocrCode,
            patientName: verified.patientName,
            patientAge: verified.patientAge,
            patientSex: verified.patientGender,
            prescriber: verified.doctorName,
            issuedDate: _formatDateTime(verified.dateTime),
            medicines: verified.medicines
                .map(
                  (m) {
                    final r = remainingByName[m.name.toLowerCase()];
                    return PrescriptionMedicine(
                      name: m.name,
                      strength: m.dosage ?? '',
                      prescribedQuantity: m.quantity,
                      stock: r?.remainingQuantity ?? m.quantity,
                      unitPrice: r?.unitPrice ?? m.unitPrice,
                    );
                  },
                )
                .toList(),
            isVerifiedQrData: true,
            rawValue: rawValue,
            // Carry the backend id through, exactly like the JSON-token
            // branch above. Without it the dispense screen has no server
            // identity to sync against and _validateDispense() blocks a
            // genuinely verified scan.
            backendId: verified.prescriptionId,
          );
        }
      } on LaravelApiException {
        rethrow;
      } catch (_) {
        // Fallback to local parsing
      }
    }

    return ScannedPrescription.fromQr(rawValue);
  }

  static ScannedPrescription _fullyDispensedResult(
    LaravelVerifiedPrescription verified,
    String rawValue,
  ) {
    return ScannedPrescription(
      rxNo: verified.ocrCode,
      patientName: verified.patientName,
      patientAge: verified.patientAge,
      patientSex: verified.patientGender,
      prescriber: verified.doctorName,
      issuedDate: _formatDateTime(verified.dateTime),
      medicines: const [],
      isVerifiedQrData: true,
      rawValue: rawValue,
      backendId: verified.prescriptionId,
      isFullyDispensed: true,
    );
  }

  static String _formatDateTime(DateTime dt) {
    final d = dt.toLocal();
    final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final minute = d.minute.toString().padLeft(2, '0');
    final ampm = d.hour < 12 ? 'AM' : 'PM';
    return '${d.month}/${d.day}/${d.year} · $hour:$minute $ampm';
  }

  factory ScannedPrescription.demo(String rawValue) => ScannedPrescription(
    rxNo: 'RX-2024-00511',
    patientName: 'Maria Santos',
    patientAge: 58,
    patientSex: 'F',
    prescriber: 'Dr. Andrea Cruz',
    issuedDate: '05 July 2025',
    medicines: const [
      PrescriptionMedicine(
        name: 'Amoxicillin',
        strength: '500 mg capsule',
        prescribedQuantity: 21,
        stock: 84,
        unitPrice: 12.50,
      ),
      PrescriptionMedicine(
        name: 'Paracetamol',
        strength: '500 mg tablet',
        prescribedQuantity: 10,
        stock: 126,
        unitPrice: 3.75,
      ),
    ],
    // Placeholder data shown when a QR could not be verified with the
    // backend (unrecognized format, or the verify call failed). It is
    // NOT verified and has no backendId, so the dispense screen must
    // refuse to record a dispense against it.
    isVerifiedQrData: false,
    rawValue: rawValue,
  );
}

class FunctionalQrScannerScreen extends StatefulWidget {
  final String branchName;
  final bool isHomeBranch;
  final bool showBackButton;

  const FunctionalQrScannerScreen({
    super.key,
    this.branchName = 'Care About Us Pharmacy',
    this.isHomeBranch = true,
    this.showBackButton = true,
  });

  @override
  State<FunctionalQrScannerScreen> createState() =>
      _FunctionalQrScannerScreenState();
}

class _FunctionalQrScannerScreenState extends State<FunctionalQrScannerScreen>
    with WidgetsBindingObserver {
  late final MobileScannerController _controller;
  bool _processing = false;
  bool _torchOn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = MobileScannerController(
      facing: CameraFacing.back,
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (!mounted || _processing) return;
    if (!_controller.value.isInitialized) return;
    try {
      if (state == AppLifecycleState.resumed) {
        await _controller.start();
      } else if (state == AppLifecycleState.inactive ||
          state == AppLifecycleState.paused) {
        await _controller.stop();
      }
    } catch (_) {
      // Ignore lifecycle controller errors to avoid app crashes.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;
    if (capture.barcodes.isEmpty) return;
    final rawValue = capture.barcodes.first.rawValue;
    if (rawValue == null || rawValue.trim().isEmpty) return;

    setState(() => _processing = true);
    try {
      await _controller.stop();
    } catch (_) {
      // Some browsers throw if the stream is already stopped/unattached.
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));

    await _resolveAndOpen(rawValue);

    if (!mounted) return;
    setState(() => _processing = false);
    try {
      await _controller.start();
    } catch (_) {
      // Ignore — camera may already be running or unavailable.
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ready for the next prescription.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  /// Looks up (or fetches) the scanned prescription and opens it in the
  /// Dispense screen, which pulls the matching record from
  /// [SavedPrescriptionsStore] by its RX / OCR code.
  Future<void> _resolveAndOpen(String rawValue) async {
    ScannedPrescription prescription;
    try {
      prescription = await ScannedPrescription.fromQrWithBackend(rawValue);
    } on LaravelApiException catch (_) {
      prescription = ScannedPrescription.fromQr(rawValue);
    } catch (_) {
      prescription = ScannedPrescription.fromQr(rawValue);
    }

    if (!mounted) return;

    // Fully dispensed: show the completion message and STOP. Never open the
    // Dispense screen — there is nothing left to dispense and its embedded
    // QR payload would otherwise show stale "available" quantities.
    if (prescription.isFullyDispensed) {
      await _showFullyDispensedDialog();
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DispenseScreen(
          initialOcrCode: prescription.rxNo,
          scannedPrescription: prescription,
        ),
      ),
    );
  }

  Future<void> _showFullyDispensedDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: ScanColors.surface,
        icon: const Icon(
          Icons.check_circle,
          color: ScanColors.teal,
          size: 48,
        ),
        title: const Text(
          'Already Fully Dispensed',
          textAlign: TextAlign.center,
          style: TextStyle(color: ScanColors.text),
        ),
        content: const Text(
          'This prescription has already been fully dispensed.',
          textAlign: TextAlign.center,
          style: TextStyle(color: ScanColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _enterCodeManually() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: ScanColors.surface,
        title: const Text(
          'Enter prescription code',
          style: TextStyle(color: ScanColors.text),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: ScanColors.text),
          decoration: InputDecoration(
            hintText: 'e.g. RX-2026-95000',
            hintStyle: const TextStyle(color: ScanColors.muted),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: ScanColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: ScanColors.teal),
            ),
          ),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            style: ElevatedButton.styleFrom(
              backgroundColor: ScanColors.teal,
              foregroundColor: Colors.white,
            ),
            child: const Text('Open'),
          ),
        ],
      ),
    );

    if (value == null || value.trim().isEmpty || !mounted) return;
    setState(() => _processing = true);
    await _resolveAndOpen(value.trim());
    if (mounted) setState(() => _processing = false);
  }

  Future<void> _toggleTorch() async {
    await _controller.toggleTorch();
    if (mounted) setState(() => _torchOn = !_torchOn);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ScanColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            Expanded(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  MobileScanner(
                    controller: _controller,
                    onDetect: _onDetect,
                    errorBuilder: (context, error) => _cameraError(error),
                  ),
                  IgnorePointer(
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.34),
                    ),
                  ),
                  IgnorePointer(
                    // Shifted above dead-center: the bottom-anchored
                    // instruction/banner/button block (Positioned below)
                    // grows taller whenever the home-branch banner wraps to
                    // two lines, and a plain centered frame then overlaps
                    // its top edge — see the reported "square is in the
                    // text" bug. Nudging the frame up leaves clearance
                    // regardless of banner height.
                    child: Align(
                      alignment: const Alignment(0, -0.18),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final frameSize = (constraints.maxWidth * 0.7)
                              .clamp(180.0, 280.0);
                          return _scanFrame(frameSize);
                        },
                      ),
                    ),
                  ),
                  Positioned(
                    top: 14,
                    right: 16,
                    child: Row(
                      children: [
                        _roundButton(
                          _torchOn ? Icons.flash_on : Icons.flash_off,
                          _toggleTorch,
                        ),
                        const SizedBox(width: 10),
                        _roundButton(
                          Icons.cameraswitch_outlined,
                          _controller.switchCamera,
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    bottom: 28,
                    left: 20,
                    right: 20,
                    child: Column(
                      children: [
                        const Text(
                          'Align the prescription QR code within the frame',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: ScanColors.text,
                            fontSize: 13.5,
                          ),
                        ),
                        const SizedBox(height: 14),
                        _homeBanner(),
                        const SizedBox(height: 10),
                        TextButton.icon(
                          onPressed: _processing ? null : _enterCodeManually,
                          icon: const Icon(
                            Icons.keyboard_outlined,
                            size: 16,
                            color: ScanColors.muted,
                          ),
                          label: const Text(
                            'Type code instead',
                            style: TextStyle(color: ScanColors.muted),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_processing) _verificationOverlay(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
    child: widget.showBackButton
        ? Row(
            children: [
              SizedBox(
                width: 48,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => Navigator.maybePop(context),
                  tooltip: 'Back',
                  icon: const Icon(
                    Icons.chevron_left,
                    color: ScanColors.text,
                    size: 30,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Text(
                      'Home Pharmacy Scan',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: ScanColors.text,
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Your branch — ${widget.branchName}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: ScanColors.teal,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 48),
            ],
          )
        : Column(
            children: [
              const Text(
                'Home Pharmacy Scan',
                style: TextStyle(
                  color: ScanColors.text,
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'Your branch — ${widget.branchName}',
                style: const TextStyle(color: ScanColors.teal, fontSize: 12.5),
              ),
            ],
          ),
  );

  Widget _scanFrame(double size) => SizedBox(
    width: size,
    height: size,
    child: Stack(
      children: const [
        _FrameCorner(alignment: Alignment.topLeft),
        _FrameCorner(alignment: Alignment.topRight),
        _FrameCorner(alignment: Alignment.bottomLeft),
        _FrameCorner(alignment: Alignment.bottomRight),
      ],
    ),
  );

  Widget _roundButton(IconData icon, Future<void> Function() action) =>
      InkResponse(
        onTap: action,
        radius: 26,
        child: Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            color: Color(0xB3000000),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Colors.white),
        ),
      );

  Widget _homeBanner() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
    decoration: BoxDecoration(
      color: ScanColors.teal.withValues(alpha: .16),
      border: Border.all(color: ScanColors.teal.withValues(alpha: .45)),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.info_outline, color: ScanColors.teal, size: 16),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            widget.isHomeBranch
                ? 'Home branch — record updates immediately on scan.'
                : 'Other branch — record will be shared securely.',
            style: const TextStyle(
              color: ScanColors.teal,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _verificationOverlay() => Container(
    color: ScanColors.background.withValues(alpha: .93),
    child: const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 42,
            height: 42,
            child: CircularProgressIndicator(
              color: ScanColors.teal,
              strokeWidth: 3,
            ),
          ),
          SizedBox(height: 16),
          Text(
            'Verifying prescription…',
            style: TextStyle(color: ScanColors.text, fontSize: 14),
          ),
        ],
      ),
    ),
  );

  Widget _cameraError(MobileScannerException error) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.no_photography_outlined,
              color: ScanColors.teal,
              size: 44,
            ),
            const SizedBox(height: 14),
            Text(
              denied
                  ? 'Camera access is needed to scan prescriptions.'
                  : 'The camera could not be started.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: ScanColors.text,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              denied
                  ? 'Enable Camera permission for this app in Android Settings, then return here.'
                  : error.errorDetails?.message ??
                        'Please try again or restart the scanner.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: ScanColors.muted),
            ),
            const SizedBox(height: 18),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _controller.start,
                  child: const Text('Try camera again'),
                ),
                OutlinedButton(
                  onPressed: _enterCodeManually,
                  child: const Text('Type code instead'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FrameCorner extends StatelessWidget {
  final Alignment alignment;
  const _FrameCorner({required this.alignment});
  @override
  Widget build(BuildContext context) {
    final top =
        alignment == Alignment.topLeft || alignment == Alignment.topRight;
    final left =
        alignment == Alignment.topLeft || alignment == Alignment.bottomLeft;
    return Align(
      alignment: alignment,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          border: Border(
            top: top
                ? const BorderSide(color: ScanColors.teal, width: 3)
                : BorderSide.none,
            bottom: !top
                ? const BorderSide(color: ScanColors.teal, width: 3)
                : BorderSide.none,
            left: left
                ? const BorderSide(color: ScanColors.teal, width: 3)
                : BorderSide.none,
            right: !left
                ? const BorderSide(color: ScanColors.teal, width: 3)
                : BorderSide.none,
          ),
        ),
      ),
    );
  }
}

String _stringValue(dynamic value, [String fallback = '']) =>
    value?.toString().trim().isNotEmpty == true
    ? value.toString().trim()
    : fallback;
int _intValue(dynamic value, int fallback) => value is num
    ? value.toInt()
    : int.tryParse(value?.toString() ?? '') ?? fallback;
double _doubleValue(dynamic value, double fallback) => value is num
    ? value.toDouble()
    : double.tryParse(value?.toString() ?? '') ?? fallback;
int? _intOrNull(dynamic value) =>
    value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
String? _stringOrNull(dynamic value) {
  final string = value?.toString().trim();
  return string == null || string.isEmpty ? null : string;
}
