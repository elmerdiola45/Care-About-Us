// ocr_result_screen.dart
//
// Standalone review screen for a scanned + priced prescription. Self
// contained: no repository/sanitizer/logger dependency — this screen
// only edits and hands back an ExtractedPrescription; whatever wires it
// to the backend (save, retry, error handling) lives in the caller via
// onSavePrescription.

import 'package:flutter/material.dart';
import '../../common/widgets/responsive_center.dart';
import '../models/extracted_prescription.dart';

class OcrResultScreen extends StatefulWidget {
  /// The scanned + priced prescription to review. Left null for now
  /// since there's no data source wired up yet — the screen falls back
  /// to an empty state.
  final ExtractedPrescription? prescription;

  final VoidCallback? onRecapture;
  final ValueChanged<ExtractedPrescription>? onSavePrescription;

  const OcrResultScreen({
    super.key,
    this.prescription,
    this.onRecapture,
    this.onSavePrescription,
  });

  @override
  State<OcrResultScreen> createState() => _OcrResultScreenState();
}

class _OcrResultScreenState extends State<OcrResultScreen> {
  late TextEditingController _doctorNameController;
  late TextEditingController _doctorLicenseController;
  late TextEditingController _dateController;
  late TextEditingController _patientController;
  late TextEditingController _diagnosisController;

  String? _validationError;

  @override
  void initState() {
    super.initState();
    _seedControllers(widget.prescription);
  }

  @override
  void didUpdateWidget(covariant OcrResultScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The widget can be reused with a new prescription (e.g. after a
    // re-capture) without this State being recreated — without this,
    // the text fields would keep showing stale data from the previous
    // scan.
    if (oldWidget.prescription != widget.prescription) {
      _disposeControllers();
      _seedControllers(widget.prescription);
    }
  }

  void _seedControllers(ExtractedPrescription? p) {
    _doctorNameController = TextEditingController(text: p?.doctorName ?? '');
    _doctorLicenseController = TextEditingController(
      text: p?.doctorLicense ?? '',
    );
    _dateController = TextEditingController(text: p?.date ?? '');
    _patientController = TextEditingController(text: p?.patientName ?? '');
    _diagnosisController = TextEditingController(text: p?.diagnosis ?? '');
    _validationError = null;
  }

  void _disposeControllers() {
    _doctorNameController.dispose();
    _doctorLicenseController.dispose();
    _dateController.dispose();
    _patientController.dispose();
    _diagnosisController.dispose();
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  /// UX-only sanity checks — keeps a pharmacist from saving an obviously
  /// incomplete record. Whatever backend `onSavePrescription` ultimately
  /// calls should still re-validate; this is a fast local check only.
  String? _validate() {
    if (_doctorNameController.text.trim().isEmpty) {
      return "Doctor name can't be empty.";
    }
    if (_patientController.text.trim().isEmpty) {
      return "Patient name can't be empty.";
    }
    if (_dateController.text.trim().isEmpty) {
      return "Date can't be empty.";
    }
    return null;
  }

  void _handleSave(ExtractedPrescription original) {
    final error = _validate();
    setState(() => _validationError = error);
    if (error != null) return;

    // Rebuild the prescription from the (possibly edited) controller
    // text rather than handing back the original, unedited object —
    // otherwise any correction the pharmacist makes here is silently
    // dropped. `medicines` isn't editable on this screen, so it's
    // carried over from `original` unchanged.
    final edited = ExtractedPrescription(
      doctorName: _doctorNameController.text.trim(),
      doctorLicense: _doctorLicenseController.text.trim(),
      date: _dateController.text.trim(),
      patientName: _patientController.text.trim(),
      diagnosis: _diagnosisController.text.trim(),
      medicines: original.medicines,
    );

    widget.onSavePrescription?.call(edited);
  }

  @override
  Widget build(BuildContext context) {
    final prescription = widget.prescription;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context),
            Expanded(
              child: ResponsiveCenter.form(
                padding: EdgeInsets.zero,
                child: prescription == null
                    ? _buildEmptyState()
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildOcrCompleteCard(prescription),
                            const SizedBox(height: 22),
                            _buildEditableFields(),
                            if (prescription.medicines.isNotEmpty) ...[
                              const SizedBox(height: 22),
                              _buildPriceList(prescription),
                            ],
                            if (_validationError != null) ...[
                              const SizedBox(height: 12),
                              _buildInlineError(_validationError!),
                            ],
                            const SizedBox(height: 22),
                            _buildActionButtons(prescription),
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

  Widget _buildInlineError(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFDECEA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFF3B6AF)),
      ),
      child: Text(
        message,
        style: const TextStyle(fontSize: 13, color: Color(0xFFC0392B)),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            tooltip: 'Back',
            icon: const Icon(
              Icons.arrow_back_ios_new,
              color: Color(0xFF0B7B77),
            ),
          ),
          const SizedBox(width: 4),
          const Text(
            "OCR Prescription Scan",
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _buildOcrCompleteCard(ExtractedPrescription p) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFDF6EC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF0DDB8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  p.doctorName.isEmpty ? 'Unknown Doctor' : p.doctorName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                    color: Color(0xFF1F2A2E),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF2E9C6B),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  "OCR Complete",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            "PRC Lic. No. ${p.doctorLicense.isEmpty ? '—' : p.doctorLicense}",
            style: const TextStyle(fontSize: 12, color: Color(0xFF8A9A9E)),
          ),
          const SizedBox(height: 8),
          Text(
            "Pt: ${p.patientName.isEmpty ? '—' : p.patientName} · "
            "Date: ${p.date.isEmpty ? '—' : p.date}",
            style: const TextStyle(
              fontSize: 12.5,
              fontStyle: FontStyle.italic,
              color: Color(0xFF3D4A4D),
            ),
          ),
          const SizedBox(height: 6),
          if (p.medicines.isEmpty)
            const Text(
              "No medicines were extracted from this scan.",
              style: TextStyle(
                fontSize: 12.5,
                fontStyle: FontStyle.italic,
                color: Color(0xFF9AA6A9),
              ),
            )
          else
            ...p.medicines.map(
              (m) => Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  "℞ ${m.name} ${m.dosage} tab #${m.quantity}".trim(),
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontStyle: FontStyle.italic,
                    color: Color(0xFF2E9C6B),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEditableFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "OCR EXTRACTED — EDITABLE",
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: Color(0xFF9AA6A9),
          ),
        ),
        const SizedBox(height: 12),
        _buildField("Doctor", _doctorNameController, const Color(0xFF0B7B77)),
        const SizedBox(height: 12),
        _buildField(
          "License",
          _doctorLicenseController,
          const Color(0xFF0B7B77),
        ),
        const SizedBox(height: 12),
        _buildField("Date", _dateController, const Color(0xFF0B7B77)),
        const SizedBox(height: 12),
        _buildField("Patient", _patientController, const Color(0xFF3B6EC9)),
        const SizedBox(height: 12),
        _buildField("Diagnosis", _diagnosisController, const Color(0xFFC98A2E)),
      ],
    );
  }

  Widget _buildField(
    String label,
    TextEditingController controller,
    Color labelColor,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: labelColor,
            ),
          ),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            // Clear any stale validation error as soon as the pharmacist
            // starts correcting the field it was about.
            onChanged: (_) {
              if (_validationError != null) {
                setState(() => _validationError = null);
              }
            },
            style: const TextStyle(fontSize: 14, color: Color(0xFF1F2A2E)),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFFF6F8F8),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPriceList(ExtractedPrescription p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                "AUTO-GENERATED PRICE LIST",
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: Color(0xFF9AA6A9),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                "MDRP Compliant",
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF3B6EC9),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF6F8F8),
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Row(
                children: const [
                  Expanded(
                    flex: 3,
                    child: Text(
                      "MEDICATION",
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: Color(0xFF8A9A9E),
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      "QTY /TAB",
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: Color(0xFF8A9A9E),
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      "TOTAL",
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: Color(0xFF8A9A9E),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ...p.medicines.map((m) => _buildPriceRow(m)),
              const Divider(height: 24, color: Color(0xFFE5E7EB)),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      "Total",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1F2A2E),
                      ),
                    ),
                  ),
                  Text(
                    "₱${p.total.toStringAsFixed(2)}",
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0B7B77),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPriceRow(PricedMedicine m) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Text(
              "${m.name} ${m.dosage}".trim(),
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1F2A2E),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              "${m.quantity} tabs ₱${m.pricePerTab.toStringAsFixed(2)}",
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280)),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              "₱${m.total.toStringAsFixed(2)}",
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1F2A2E),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(ExtractedPrescription p) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: widget.onRecapture,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF0B7B77),
              side: const BorderSide(color: Color(0xFFB9E4DF)),
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              "Re-capture",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton(
            onPressed: () => _handleSave(p),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0B7B77),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              "Save Prescription",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.description_outlined,
              size: 48,
              color: Color(0xFFB3BEC1),
            ),
            const SizedBox(height: 12),
            const Text(
              "No scan result yet",
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(0xFF5A6669),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            const Text(
              "Capture a prescription to see the extracted results here.",
              style: TextStyle(fontSize: 13, color: Color(0xFF9AA6A9)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
