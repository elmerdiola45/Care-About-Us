import 'dart:convert';

import 'package:flutter/material.dart';

import '../../common/session.dart';
import '../../common/services/laravel_api_service.dart';
import '../../common/utils/qr_token_parser.dart';
import '../widgets/branch_info_card.dart';

class CrossPharmacyScanColors {
  static const background = Color(0xFF0F172A);
  static const surface = Color(0xFF1E293B);
  static const primary = Color(0xFF6366F1);
  static const primaryLight = Color(0xFF818CF8);
  static const text = Color(0xFFE2E8F0);
  static const textSecondary = Color(0xFFCBD5E1);
  static const muted = Color(0xFF94A3B8);
  static const border = Color(0xFF334155);
  static const warning = Color(0xFFF59E0B);
  static const warningBg = Color(0xFFFEF3D9);
  static const danger = Color(0xFFEF4444);
  static const dangerBg = Color(0xFFFEE2E2);
}

/// Verifies a scanned/pasted QR value against the real backend — extracting
/// the secret token from either a raw {"token": "..."} JSON payload or a
/// bare `.../verify/{token}` URL (the format printed QR codes now encode).
/// Throws [LaravelApiException] on an invalid/expired/already-used token.
/// There is deliberately no demo-data fallback here: a cross-pharmacy scan
/// is about to modify another pharmacy's real records.
Future<LaravelVerifiedPrescription> verifyCrossPharmacyQr(String rawValue) async {
  String token = '';
  try {
    final decoded = jsonDecode(rawValue);
    if (decoded is Map) {
      token = (decoded['token'] ?? decoded['t'])?.toString() ?? '';
    }
  } catch (_) {
    // Not JSON — fall through to URL extraction below.
  }
  if (token.isEmpty) {
    token = extractTokenFromUrl(rawValue);
  }
  if (token.isEmpty) {
    throw const LaravelApiException('This QR code could not be recognized.');
  }

  final api = LaravelApiService(token: AppSession.instance.token);
  final verified = await api.verifyQrToken(token);
  if (!verified.valid) {
    throw LaravelApiException(verified.message ?? 'This QR code is invalid or already used.');
  }
  return verified;
}

// No live camera here — cross-pharmacy staff never open this app at all
// (they scan the printed QR with their own device via the public web
// portal; see PublicPortalController/verify.blade.php). This screen's only
// possible in-app use is a pharmacist manually pasting a QR's encoded
// link/token, so it's a plain text-entry verification flow on every
// platform, not a camera scanner.
class CrossPharmacyScanScreen extends StatefulWidget {
  final String branchName;
  const CrossPharmacyScanScreen({
    super.key,
    this.branchName = 'Care About Us Pharmacy',
  });

  @override
  State<CrossPharmacyScanScreen> createState() => _CrossPharmacyScanScreenState();
}

class _CrossPharmacyScanScreenState extends State<CrossPharmacyScanScreen> {
  final TextEditingController _textController = TextEditingController();
  bool _processing = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _processText(String rawValue) async {
    if (_processing) return;
    if (rawValue.trim().isEmpty) return;

    setState(() => _processing = true);

    LaravelVerifiedPrescription? prescription;
    String? error;
    try {
      prescription = await verifyCrossPharmacyQr(rawValue.trim());
    } on LaravelApiException catch (e) {
      error = e.message;
    } catch (_) {
      error = 'Could not verify this QR code. Please try again.';
    }

    if (!mounted) return;

    if (error != null) {
      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), backgroundColor: CrossPharmacyScanColors.danger, duration: const Duration(seconds: 3)),
      );
      return;
    }

    final confirmed = await _showVerificationSheet(prescription!);

    if (!mounted) return;

    setState(() => _processing = false);
    _textController.clear();

    if (confirmed == true) {
      _submitCrossPharmacyDispense(prescription);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Scan cancelled. Ready for next prescription.'), duration: Duration(seconds: 2)),
      );
    }
  }

  Future<bool?> _showVerificationSheet(LaravelVerifiedPrescription prescription) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _VerificationSheet(prescription: prescription),
    );
  }

  Future<void> _submitCrossPharmacyDispense(LaravelVerifiedPrescription prescription) async {
    final branchInfo = await _showBranchInfoSheet();
    if (branchInfo == null || !mounted) return;

    final pharmacyName = branchInfo['pharmacyName']?.trim().isNotEmpty == true
        ? branchInfo['pharmacyName']!.trim()
        : 'Unknown Pharmacy';
    final staffName = branchInfo['staff']?.trim().isNotEmpty == true
        ? branchInfo['staff']!.trim()
        : 'Unknown Staff';
    final items = prescription.remainingItems
        .where((i) => i.remainingQuantity > 0)
        .map((i) => {'item_id': i.itemId, 'quantity': i.remainingQuantity})
        .toList();

    if (items.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing remains to dispense on this prescription.'), backgroundColor: CrossPharmacyScanColors.danger),
      );
      return;
    }

    try {
      final api = LaravelApiService(token: AppSession.instance.token);
      await api.submitCrossPharmacyDispense(
        token: prescription.token,
        pharmacyName: pharmacyName,
        branch: branchInfo['branch'],
        address: branchInfo['address'] ?? '',
        licenseNumber: branchInfo['license'] ?? '',
        staffDispensing: staffName,
        items: items,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Submitted for $pharmacyName — awaiting home pharmacy verification.'),
          backgroundColor: CrossPharmacyScanColors.primary,
          duration: const Duration(seconds: 3),
        ),
      );
    } on LaravelApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: CrossPharmacyScanColors.danger, duration: const Duration(seconds: 4)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to submit dispense: $e'), backgroundColor: CrossPharmacyScanColors.danger, duration: const Duration(seconds: 4)),
      );
    }
  }

  Future<Map<String, String>?> _showBranchInfoSheet() {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const BranchInfoCard(),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 20, 14),
      child: Row(children: [
        IconButton(onPressed: () => Navigator.maybePop(context), tooltip: 'Back', icon: const Icon(Icons.chevron_left, color: CrossPharmacyScanColors.text, size: 30)),
        Expanded(child: Column(children: [
          const Text('Cross-Pharmacy Scan', style: TextStyle(color: CrossPharmacyScanColors.text, fontWeight: FontWeight.w700, fontSize: 17)),
          const SizedBox(height: 3),
          Text('External branch — ${widget.branchName}', style: TextStyle(color: CrossPharmacyScanColors.primaryLight, fontSize: 12.5)),
        ])),
        const SizedBox(width: 48),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CrossPharmacyScanColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: CrossPharmacyScanColors.surface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: CrossPharmacyScanColors.border),
                        ),
                        child: Column(
                          children: [
                            const Icon(Icons.qr_code_scanner_outlined, color: CrossPharmacyScanColors.primaryLight, size: 48),
                            const SizedBox(height: 16),
                            const Text(
                              'Cross-Pharmacy Scanner',
                              style: TextStyle(color: CrossPharmacyScanColors.text, fontSize: 20, fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Paste the QR code content below to scan a prescription.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: CrossPharmacyScanColors.muted, fontSize: 14),
                            ),
                            const SizedBox(height: 20),
                            TextField(
                              controller: _textController,
                              maxLines: 5,
                              style: const TextStyle(color: CrossPharmacyScanColors.text, fontSize: 14),
                              decoration: InputDecoration(
                                hintText: 'Paste QR content here...',
                                hintStyle: const TextStyle(color: CrossPharmacyScanColors.muted),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: CrossPharmacyScanColors.border)),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: CrossPharmacyScanColors.border)),
                                contentPadding: const EdgeInsets.all(12),
                              ),
                            ),
                            const SizedBox(height: 16),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _processing ? null : () => _processText(_textController.text),
                                icon: _processing
                                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                    : const Icon(Icons.check, color: Colors.white),
                                label: Text(_processing ? 'Scanning...' : 'Scan QR', style: const TextStyle(fontWeight: FontWeight.w700)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: CrossPharmacyScanColors.primary,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      _immediateRecordBanner(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Shared "pending review" banner. This used to say dispensed quantities
// are recorded immediately — that stopped being true once
// CrossPharmacyDispenseService::commit() was split into stage()/approve():
// a submission from this screen is now held as a pending request until the
// home pharmacy's admin reviews and approves it (same corrected messaging
// applied to verify.blade.php's public portal page).
Widget _immediateRecordBanner() => Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: CrossPharmacyScanColors.warningBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: CrossPharmacyScanColors.warning.withValues(alpha: .45)),
      ),
      child: const Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.info_outline, color: CrossPharmacyScanColors.warning, size: 16),
        SizedBox(width: 7),
        Text('Submissions are held for home pharmacy review before the prescription record updates.', style: TextStyle(color: CrossPharmacyScanColors.warning, fontSize: 11.5, fontWeight: FontWeight.w600)),
      ]),
    );

class _VerificationSheet extends StatelessWidget {
  final LaravelVerifiedPrescription prescription;
  const _VerificationSheet({required this.prescription});

  @override
  Widget build(BuildContext context) {
    final items = prescription.remainingItems;

    return Container(
      margin: EdgeInsets.only(top: MediaQuery.of(context).size.height * 0.3),
      decoration: const BoxDecoration(
        color: CrossPharmacyScanColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.verified_outlined, color: CrossPharmacyScanColors.primaryLight, size: 20),
                    const SizedBox(width: 8),
                    const Text(
                      'Cross-Pharmacy Dispense',
                      style: TextStyle(color: CrossPharmacyScanColors.text, fontWeight: FontWeight.w800, fontSize: 16),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('RX: ${prescription.ocrCode}', style: const TextStyle(color: CrossPharmacyScanColors.muted, fontSize: 13)),
                const SizedBox(height: 4),
                Text('Patient: ${prescription.patientName}', style: const TextStyle(color: CrossPharmacyScanColors.text, fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 4),
                Text('Prescriber: ${prescription.doctorName}', style: const TextStyle(color: CrossPharmacyScanColors.muted, fontSize: 13)),
                const SizedBox(height: 12),
                const Divider(color: CrossPharmacyScanColors.border),
                const SizedBox(height: 12),
                const Text('Medicines to dispense (remaining)', style: TextStyle(color: CrossPharmacyScanColors.textSecondary, fontSize: 11.5, fontWeight: FontWeight.w900, letterSpacing: 0.6)),
                const SizedBox(height: 8),
                if (items.isEmpty)
                  const Text('No remaining quantity on this prescription.', style: TextStyle(color: CrossPharmacyScanColors.muted, fontSize: 13))
                else
                  ...items.map((i) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(children: [
                          Container(width: 6, height: 6, decoration: const BoxDecoration(color: CrossPharmacyScanColors.primaryLight, shape: BoxShape.circle)),
                          const SizedBox(width: 10),
                          Expanded(child: Text('${i.medicineName} × ${i.remainingQuantity}', style: const TextStyle(color: CrossPharmacyScanColors.text, fontSize: 14))),
                        ]),
                      )),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: CrossPharmacyScanColors.muted,
                          side: const BorderSide(color: CrossPharmacyScanColors.border),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: items.isEmpty ? null : () => Navigator.of(context).pop(true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: CrossPharmacyScanColors.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                        child: const Text('Continue', style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
