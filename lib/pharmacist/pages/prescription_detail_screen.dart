import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../common/services/laravel_api_service.dart';
import '../../common/session.dart';
import '../../common/utils/ph_time.dart';
import '../../common/widgets/responsive_center.dart';
import '../../common/widgets/authenticated_network_image.dart';
import '../models/prescription.dart';
import '../data/saved_prescriptions_store.dart';
import 'dispense_screen.dart';

class PrescriptionDetailScreen extends StatefulWidget {
  final PrescriptionEntry entry;

  const PrescriptionDetailScreen({super.key, required this.entry});

  @override
  State<PrescriptionDetailScreen> createState() =>
      _PrescriptionDetailScreenState();
}

class _PrescriptionDetailScreenState extends State<PrescriptionDetailScreen> {
  late TextEditingController _patientController;
  late TextEditingController _ageController;
  late TextEditingController _genderController;
  late TextEditingController _doctorController;
  late TextEditingController _licenseController;
  late TextEditingController _ptController;
  late TextEditingController _s2Controller;
  late TextEditingController _addressController;

  bool _isSaving = false;
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    final p = widget.entry.prescription;
    _patientController = TextEditingController(text: p.patientName);
    _ageController = TextEditingController(text: '${p.patientAge}');
    _genderController = TextEditingController(text: p.patientGender);
    _doctorController = TextEditingController(text: p.doctorName);
    _licenseController = TextEditingController(text: p.licenseNo);
    _ptController = TextEditingController(text: p.ptNo);
    _s2Controller = TextEditingController(text: p.s2);
    _addressController = TextEditingController(text: p.patientAddress ?? '');
  }

  @override
  void dispose() {
    _patientController.dispose();
    _ageController.dispose();
    _genderController.dispose();
    _doctorController.dispose();
    _licenseController.dispose();
    _ptController.dispose();
    _s2Controller.dispose();
    _addressController.dispose();
    super.dispose();
  }

  String _dispensingStatusLabel(DispensingStatus status) {
    switch (status) {
      case DispensingStatus.fullyDispensed:
        return 'Fully Dispensed';
      case DispensingStatus.partiallyDispensed:
        return 'Partially Dispensed';
      case DispensingStatus.overDispensing:
        return 'Overdispensing';
      default:
        return 'Pending Dispensing';
    }
  }

  Color _dispensingStatusColor(DispensingStatus status) {
    switch (status) {
      case DispensingStatus.fullyDispensed:
        return const Color(0xFF2E9C6B);
      case DispensingStatus.partiallyDispensed:
        return const Color(0xFFD97706);
      case DispensingStatus.overDispensing:
        return const Color(0xFFDC2626);
      default:
        return const Color(0xFF6B7280);
    }
  }

  Future<void> _saveDisposedQuantities() async {
    if (_isSaving) return;
    if (widget.entry.backendId == null || widget.entry.backendId!.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Save this prescription to the backend first'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    setState(() => _isSaving = true);

    try {
      final medicinesPayload = widget.entry.prescription.medicines
          .map((m) => {'id': m.name, 'disposed_quantity': m.disposedQuantity})
          .toList();

      await LaravelApiService(
        token: AppSession.instance.token,
      ).updateDisposedQuantities(widget.entry.backendId!, medicinesPayload);

      final updatedEntry = widget.entry.copyWith(
        prescription: widget.entry.prescription.copyWith(
          medicines: widget.entry.prescription.medicines,
        ),
      );
      SavedPrescriptionsStore.instance.replaceOrInsert(updatedEntry);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Dispensed quantities updated'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } on LaravelApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Backend error: ${e.message}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unknown error'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _saveToBackend() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      final age = int.tryParse(_ageController.text.trim()) ?? 0;
      final totalPrice = widget.entry.prescription.totalPrice;

      final medicinesPayload = widget.entry.prescription.medicines
          .map(
            (m) => {
              'name': m.name,
              'dosage': m.dosage,
              'quantity': m.quantity,
              'disposed_quantity': m.disposedQuantity,
              'unit_price': m.unitPrice,
              'is_essential': m.isEssential,
              'duration': m.duration,
              'days_supply': m.daysSupply,
            },
          )
          .toList();

      final session = AppSession.instance;
      final api = LaravelApiService(token: session.token);

      // Don't trust widget.entry.backendId alone — it's a snapshot from
      // whenever this screen was opened and may predate the store's own
      // background sync finishing (see SavedPrescriptionsStore.add()).
      // Check the store's live value first so we don't fire a second
      // createPrescription for an ocr_code that already exists.
      final liveBackendId =
          SavedPrescriptionsStore.instance.backendIdFor(widget.entry.ocrCode) ??
          widget.entry.backendId;

      if (liveBackendId == null || liveBackendId.isEmpty) {
        await api.createPrescription(
          ocrCode: widget.entry.ocrCode,
          patientName: _patientController.text.trim(),
          patientAge: age,
          patientGender: _genderController.text.trim(),
          doctorName: _doctorController.text.trim(),
          licenseNo: _licenseController.text.trim(),
          ptNo: _ptController.text.trim(),
          s2: _s2Controller.text.trim(),
          patientAddress: _addressController.text.trim(),
          dateTime: widget.entry.prescription.dateTime,
          medicines: medicinesPayload,
          totalPrice: totalPrice,
          rawExtractedText: widget.entry.rawExtractedText,
          pharmacistId: session.userType == 'admin' ? session.userId : null,
          dispenserId: session.userType == 'dispenser' ? session.userId : null,
          pharmacyId: session.pharmacyId,
          imageBytes: widget.entry.imageBytes,
        );
      } else {
        await api.updatePrescription(liveBackendId, {
          'patient_name': _patientController.text.trim(),
          'patient_age': age,
          'patient_gender': _genderController.text.trim(),
          'doctor_name': _doctorController.text.trim(),
          'license_no': _licenseController.text.trim(),
          'pt_no': _ptController.text.trim(),
          's2': _s2Controller.text.trim(),
          'patient_address': _addressController.text.trim(),
          'medicines': medicinesPayload,
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Saved to database'),
            duration: Duration(seconds: 2),
          ),
        );
        setState(() => _isEditing = false);
      }
    } on LaravelApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Backend error: ${e.message}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unknown error'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F4F6),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        foregroundColor: const Color(0xFF1F2937),
        title: const Text(
          'Prescription Details',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (widget.entry.prescription.dispensingStatus !=
                  DispensingStatus.fullyDispensed &&
              widget.entry.prescription.dispensingStatus !=
                  DispensingStatus.overDispensing)
            IconButton(
              onPressed: _isSaving
                  ? null
                  : () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => DispenseScreen(
                            initialOcrCode: widget.entry.ocrCode,
                          ),
                        ),
                      );
                    },
              icon: const Icon(
                Icons.local_pharmacy_rounded,
                color: Color(0xFF0B7B77),
                size: 24,
              ),
              tooltip: 'Dispense',
            ),
          IconButton(
            onPressed: _isSaving
                ? null
                : () {
                    if (_isEditing) {
                      _saveToBackend();
                    } else {
                      setState(() => _isEditing = true);
                    }
                  },
            icon: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF0B7B77),
                    ),
                  )
                : Icon(_isEditing ? Icons.save : Icons.edit),
            tooltip: _isEditing ? 'Save' : 'Edit',
          ),
        ],
      ),
      body: ResponsiveCenter.dashboard(
        padding: EdgeInsets.zero,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _buildPrescriptionHeader(context),
            const SizedBox(height: 16),
            _buildPatientInfoCard(),
            const SizedBox(height: 12),
            _buildDoctorInfoCard(),
            const SizedBox(height: 12),
            _buildMedicinesCard(),
            const SizedBox(height: 12),
            _buildDispensingActionCard(),
            const SizedBox(height: 12),
            _buildTotalCard(),
            const SizedBox(height: 16),
            if (widget.entry.qrData != null) ...[
              _buildQrSection(context),
              const SizedBox(height: 16),
            ],
            if (widget.entry.rawExtractedText.isNotEmpty) ...[
              _buildRawTextCard(),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPrescriptionHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => _openImageViewer(context),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _buildImageThumbnail(
                widget.entry.imageBytes,
                64,
                widget.entry.imageUrl,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.entry.prescription.patientName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${widget.entry.prescription.patientGender} · ${widget.entry.prescription.patientAge} years old',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color:
                        widget.entry.prescription.dispensingStatus ==
                            DispensingStatus.fullyDispensed
                        ? const Color(0xFFDCF3E8)
                        : widget.entry.prescription.dispensingStatus ==
                              DispensingStatus.partiallyDispensed
                        ? const Color(0xFFFFF7E6)
                        : const Color(0xFFFDF0D8),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _dispensingStatusLabel(
                      widget.entry.prescription.dispensingStatus,
                    ),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: _dispensingStatusColor(
                        widget.entry.prescription.dispensingStatus,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPatientInfoCard() {
    final editable = _isEditing;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.person_outline, color: Color(0xFF0B7B77), size: 18),
              SizedBox(width: 8),
              Text(
                'Patient Information',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 12.5,
                  color: Color(0xFF6B7280),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (editable) ...[
            _editableField('Name', _patientController),
            _editableField(
              'Age',
              _ageController,
              keyboardType: TextInputType.number,
            ),
            _editableField('Gender', _genderController),
            _editableField('Address', _addressController),
          ] else ...[
            _detailRow('Name', widget.entry.prescription.patientName),
            _detailRow('Age', '${widget.entry.prescription.patientAge}'),
            _detailRow('Gender', widget.entry.prescription.patientGender),
            if (widget.entry.prescription.patientAddress != null &&
                widget.entry.prescription.patientAddress!.isNotEmpty)
              _detailRow('Address', widget.entry.prescription.patientAddress!),
          ],
        ],
      ),
    );
  }

  Widget _buildDoctorInfoCard() {
    final editable = _isEditing;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(
                Icons.medical_services_outlined,
                color: Color(0xFF0B7B77),
                size: 18,
              ),
              SizedBox(width: 8),
              Text(
                'Prescriber Information',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 12.5,
                  color: Color(0xFF6B7280),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (editable) ...[
            _editableField('Doctor', _doctorController),
            _editableField('License No.', _licenseController),
            _editableField('PT No.', _ptController),
            _editableField('S2', _s2Controller),
          ] else ...[
            _detailRow('Doctor', widget.entry.prescription.doctorName),
            if (widget.entry.prescription.licenseNo.isNotEmpty)
              _detailRow('License No.', widget.entry.prescription.licenseNo),
            if (widget.entry.prescription.ptNo.isNotEmpty)
              _detailRow('PT No.', widget.entry.prescription.ptNo),
            if (widget.entry.prescription.s2.isNotEmpty)
              _detailRow('S2', widget.entry.prescription.s2),
            _detailRow('Date', _formatDate(widget.entry.prescription.dateTime)),
          ],
        ],
      ),
    );
  }

  Widget _buildMedicinesCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(
                Icons.medication_outlined,
                color: Color(0xFF0B7B77),
                size: 18,
              ),
              SizedBox(width: 8),
              Text(
                'Medicines',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 12.5,
                  color: Color(0xFF6B7280),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...widget.entry.prescription.medicines.map((m) {
            final typeColor = m.isEssential
                ? const Color(0xFF0B7B77)
                : const Color(0xFFD97706);
            final typeLabel = m.isEssential ? 'Essential' : 'Optional';
            final remaining = m.quantity - m.disposedQuantity;
            final isFullyDispensed = remaining <= 0;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${m.name} ${m.dosage}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        if (m.duration.isNotEmpty)
                          Text(
                            'Duration: ${m.duration}',
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 12,
                            ),
                          ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: typeColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            typeLabel,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: typeColor,
                            ),
                          ),
                        ),
                        if (isFullyDispensed)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Fully dispensed',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.green.shade700,
                              ),
                            ),
                          )
                        else if (m.disposedQuantity > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Remaining: $remaining',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.orange.shade700,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '/${m.quantity}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                      if (!isFullyDispensed)
                        SizedBox(
                          width: 80,
                          child: TextField(
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Dispensed',
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              border: OutlineInputBorder(),
                            ),
                            controller: TextEditingController(
                              text: '${m.disposedQuantity}',
                            ),
                            onChanged: (val) {
                              final qty = int.tryParse(val) ?? 0;
                              final idx = widget.entry.prescription.medicines
                                  .indexWhere((med) => med.name == m.name);
                              if (idx != -1) {
                                widget.entry.prescription.medicines[idx] = m
                                    .copyWith(
                                      disposedQuantity: qty.clamp(
                                        0,
                                        m.quantity,
                                      ),
                                    );
                                setState(() {});
                              }
                            },
                          ),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.green.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Done',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.green.shade700,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildDispensingActionCard() {
    final hasDisposed = widget.entry.prescription.medicines.any(
      (m) => m.disposedQuantity > 0,
    );
    final allFullyDispensed =
        widget.entry.prescription.medicines.isNotEmpty &&
        widget.entry.prescription.medicines.every(
          (m) => m.disposedQuantity >= m.quantity,
        );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          Icon(
            allFullyDispensed
                ? Icons.check_circle_rounded
                : Icons.local_pharmacy_outlined,
            color: allFullyDispensed ? Colors.green : const Color(0xFF0B7B77),
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              allFullyDispensed
                  ? 'All medicines fully dispensed'
                  : hasDisposed
                  ? 'Update dispensed quantities to reflect partial dispensing'
                  : 'Enter dispensed quantities for each medicine',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1F2937),
              ),
            ),
          ),
          if (hasDisposed && !allFullyDispensed)
            TextButton.icon(
              onPressed: _isSaving ? null : _saveDisposedQuantities,
              icon: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF0B7B77),
                      ),
                    )
                  : const Icon(
                      Icons.save_outlined,
                      size: 18,
                      color: Color(0xFF0B7B77),
                    ),
              label: const Text(
                'Save Dispensing',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0B7B77),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTotalCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0B7B77),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Text(
            'Total',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 16,
              color: Colors.white,
            ),
          ),
          const Spacer(),
          Text(
            '₱${widget.entry.prescription.totalPrice.toStringAsFixed(2)}',
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 22,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQrSection(BuildContext context) {
    final qrJson = widget.entry.qrData;
    if (qrJson == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        children: [
          Row(
            children: const [
              Icon(Icons.qr_code_2, color: Color(0xFF0B7B77), size: 18),
              SizedBox(width: 8),
              Text(
                'QR Code',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 12.5,
                  color: Color(0xFF6B7280),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (widget.entry.qrToken != null)
            Text(
              'Token: ${widget.entry.qrToken}',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
                fontFamily: 'monospace',
              ),
            ),
          const SizedBox(height: 10),
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: Text(
                qrJson,
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: 'monospace',
                  color: Colors.grey.shade700,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            widget.entry.backendVerifyUrl ?? 'QR token ready for scanning',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildRawTextCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(
                Icons.text_snippet_outlined,
                color: Color(0xFF0B7B77),
                size: 18,
              ),
              SizedBox(width: 8),
              Text(
                'Raw OCR Text',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 12.5,
                  color: Color(0xFF6B7280),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            widget.entry.rawExtractedText,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade700,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _editableField(
    String label,
    TextEditingController controller, {
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType ?? TextInputType.text,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(
            color: Color(0xFF6B7280),
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          isDense: true,
        ),
        style: const TextStyle(
          fontSize: 13.5,
          color: Color(0xFF1F2937),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1F2937),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) => formatPhilippineDateTime(dt);

  void _openImageViewer(BuildContext context) {
    final bytes = widget.entry.imageBytes;
    final imageUrl = widget.entry.imageUrl;
    if (bytes.isEmpty && (imageUrl == null || imageUrl.isEmpty)) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4,
              child: bytes.isNotEmpty
                  ? Image.memory(bytes, fit: BoxFit.contain)
                  : AuthenticatedNetworkImage(
                      imageUrl: imageUrl!,
                      token: AppSession.instance.token,
                      fit: BoxFit.contain,
                      errorWidget: Icon(
                        Icons.image_not_supported_outlined,
                        size: 64,
                        color: Colors.grey.shade600,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImageThumbnail(
    Uint8List bytes,
    double size, [
    String? imageUrl,
  ]) {
    if (bytes.isEmpty) {
      if (imageUrl != null && imageUrl.isNotEmpty) {
        return AuthenticatedNetworkImage(
          imageUrl: imageUrl,
          token: AppSession.instance.token,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorWidget: Icon(
            Icons.image_not_supported_outlined,
            size: size,
            color: Colors.grey.shade400,
          ),
        );
      }
      return Icon(
        Icons.image_not_supported_outlined,
        size: size,
        color: Colors.grey.shade400,
      );
    }
    return Image.memory(
      bytes,
      width: size,
      height: size,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => Icon(
        Icons.broken_image_outlined,
        size: size,
        color: Colors.grey.shade400,
      ),
    );
  }
}
