import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../common/theme/app_colors.dart';
import '../data/admin_api_service.dart';
import '../models/admin_models.dart';
import '../models/admin_patient_adherence.dart';

class AdminPatientAdherenceDetailPage extends StatefulWidget {
  final String patientId;
  final String? altPatientId;
  final Map<String, dynamic>? initialPatient;

  const AdminPatientAdherenceDetailPage({super.key, required this.patientId, this.altPatientId, this.initialPatient});

  @override
  State<AdminPatientAdherenceDetailPage> createState() => _AdminPatientAdherenceDetailPageState();
}

class _AdminPatientAdherenceDetailPageState extends State<AdminPatientAdherenceDetailPage> {
  bool _isLoading = true;
  bool _isNotFound = false;
  String? _errorMessage;
  PatientDetailResponse? _patient;
  bool _isUpdating = false;

  @override
  void initState() {
    super.initState();
    debugPrint('AdminPatientAdherenceDetailPage init: patientId=${widget.patientId}');
    _loadPatient();
  }

  Future<void> _loadPatient() async {
    setState(() {
      _isLoading = true;
      _isNotFound = false;
      _errorMessage = null;
    });

    PatientDetailResponse? patient;
    String? failMsg;

    final hasAdherenceData = widget.initialPatient != null &&
        (widget.initialPatient!['adherence_status'] != null ||
         widget.initialPatient!['adherence_score'] != null ||
         widget.initialPatient!['medications'] != null ||
         widget.initialPatient!['refill_history'] != null);

    if (hasAdherenceData) {
      try {
        patient = PatientDetailResponse.fromJson(widget.initialPatient!);
      } catch (e) {
        failMsg = e.toString();
      }
    } else {
      try {
        final api = AdminApiService();
        try {
          debugPrint('Fetching admin patient detail for: ${widget.patientId}');
          patient = await api.fetchPatientDetail(widget.patientId);
        } on Exception catch (e) {
          final msg = e.toString();
          debugPrint('Primary fetch failed: $msg');
          if (widget.altPatientId != null && widget.altPatientId != widget.patientId) {
            debugPrint('Trying altPatientId: ${widget.altPatientId}');
            try {
              patient = await api.fetchPatientDetail(widget.altPatientId!);
            } on Exception catch (e2) {
              debugPrint('Alt fetch failed: ${e2.toString()}');
              failMsg = e2.toString();
            }
          } else {
            failMsg = msg;
          }
        }

        if (patient == null && widget.initialPatient != null) {
          debugPrint('Falling back to initialPatient');
          try {
            patient = PatientDetailResponse.fromJson(widget.initialPatient!);
          } catch (e) {
            debugPrint('fromJson fallback failed: ${e.toString()}');
            failMsg ??= e.toString();
          }
        }
      } catch (e) {
        debugPrint('Unexpected error: ${e.toString()}');
        failMsg = e.toString();
      }
    }

    if (!mounted) return;

    setState(() {
      if (patient != null) {
        _patient = patient;
        _isLoading = false;
      } else if (widget.initialPatient != null) {
        try {
          _patient = PatientDetailResponse.fromJson(widget.initialPatient!);
        } catch (e) {
          _patient = PatientDetailResponse(
            patientId: widget.initialPatient!['patient_id']?.toString() ?? widget.patientId,
            name: widget.initialPatient!['name']?.toString() ?? 'Unknown Patient',
            genderAge: '',
            hasHistory: true,
          );
        }
        _isLoading = false;
      } else {
        _isNotFound = failMsg != null && failMsg.contains('Patient not found');
        _errorMessage = _isNotFound ? null : 'Failed to load patient detail: $failMsg';
        _isLoading = false;
      }
    });
  }

  AdherenceTier get _tier {
    final p = _patient;
    if (p == null) return AdherenceTier.good;
    return p.adherenceLevel;
  }

  bool get _isFullyDispensed => _tier == AdherenceTier.fullyDispensed;

  (Color, Color, String, String?) get _tierStyle {
    final p = _patient;
    if (p == null) {
      return (AppColors.textFaint, AppColors.border.withValues(alpha: 0.08), 'No data yet', null);
    }
    if (_tier == AdherenceTier.fullyDispensed) {
      return (const Color(0xFF6B7280), const Color(0xFFF3F4F6), 'Fully Dispensed', p.adherenceReason);
    }
    if (!p.hasHistory) {
      return (AppColors.textFaint, AppColors.border.withValues(alpha: 0.08), 'No data yet', null);
    }
    switch (_tier) {
      case AdherenceTier.good:
        return (AppColors.success, AppColors.successBg, 'Good', p.adherenceReason);
      case AdherenceTier.atRisk:
        return (AppColors.warning, AppColors.warningBg, 'At Risk', p.adherenceReason);
      case AdherenceTier.critical:
        return (AppColors.danger, AppColors.dangerBg, 'Pending', p.adherenceReason);
      case AdherenceTier.overDispensing:
        return (AppColors.danger, AppColors.dangerBg, 'Overdispensing', p.adherenceReason);
      case AdherenceTier.fullyDispensed:
        return (const Color(0xFF6B7280), const Color(0xFFF3F4F6), 'Fully Dispensed', p.adherenceReason);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isNotFound) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          iconTheme: const IconThemeData(color: AppColors.teal),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.person_off_outlined, size: 48, color: AppColors.textFaint),
                const SizedBox(height: 16),
                Text(
                  'Patient not found',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  'The patient record could not be found. It may have been removed.',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('Go back'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.teal,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final p = _patient;
    if (p == null || _isLoading) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          iconTheme: const IconThemeData(color: AppColors.teal),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_errorMessage ?? 'Loading...', textAlign: TextAlign.center),
          ),
        ),
      );
    }

    final (tierColor, tierBg, tierLabel, tierSub) = _tierStyle;
    final initialPrescription = widget.initialPatient != null &&
        (widget.initialPatient!['ocr_code'] != null || widget.initialPatient!['items'] != null);
    final rxNumber = initialPrescription ? widget.initialPatient!['ocr_code']?.toString() : null;
    final doctorName = initialPrescription ? widget.initialPatient!['doctor_name']?.toString() ?? widget.initialPatient!['doctor']?.toString() : null;
    final dateTime = initialPrescription ? widget.initialPatient!['date_time']?.toString() ?? widget.initialPatient!['date']?.toString() : null;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.teal),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(p.name, style: const TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
            if (rxNumber != null)
              Text('Rx: $rxNumber', style: TextStyle(color: Colors.grey.shade500, fontSize: 11.5))
            else
              Text(p.genderAge, style: TextStyle(color: Colors.grey.shade500, fontSize: 11.5)),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (initialPrescription) _buildPrescriptionInfoCard(rxNumber, doctorName, dateTime),
          if (initialPrescription) const SizedBox(height: 14),
          _buildScoreCard(tierColor, tierBg, tierLabel, tierSub),
          const SizedBox(height: 14),
          _buildMedicationsCard(),
          const SizedBox(height: 14),
          _buildRefillHistoryCard(),
          const SizedBox(height: 14),
          _buildInfoBanner(),
          const SizedBox(height: 14),
          _buildAdminActionSection(),
        ],
      ),
    );
  }

  Widget _buildPrescriptionInfoCard(String? rxNumber, String? doctorName, String? dateTime) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'PRESCRIPTION DETAILS',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 10),
          if (rxNumber != null)
            Row(
              children: [
                const Icon(Icons.qr_code_2, size: 16, color: AppColors.teal),
                const SizedBox(width: 8),
                Text('Rx Number: $rxNumber', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ],
            ),
          if (doctorName != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.person_outline, size: 16, color: AppColors.teal),
                const SizedBox(width: 8),
                Text('Doctor: $doctorName', style: const TextStyle(fontSize: 13)),
              ],
            ),
          ],
          if (dateTime != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.calendar_today_outlined, size: 16, color: AppColors.teal),
                const SizedBox(width: 8),
                Text('Date: $dateTime', style: const TextStyle(fontSize: 13)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildScoreCard(Color tierColor, Color tierBg, String tierLabel, String? tierSub) {
    final p = _patient!;
    final score = p.adherencePercent ?? 0;
    final displayScore = _isFullyDispensed ? 100 : score;

    return _card(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ADHERENCE STATUS',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  tierLabel,
                  style: TextStyle(color: tierColor, fontSize: 34, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  '$displayScore%',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                if (tierSub != null && tierSub.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    tierSub,
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5, fontStyle: FontStyle.italic),
                  ),
                ],
              ],
            ),
          ),
          _ScoreRing(score: displayScore, color: tierColor, trackColor: tierBg),
        ],
      ),
    );
  }

  Widget _buildMedicationsCard() {
    final p = _patient!;

    final historyTotals = <String, ({int initial, int dispensed, int remaining})>{};
    for (final ev in p.refillHistory) {
      final current = historyTotals[ev.medicineName];
      historyTotals[ev.medicineName] = (
        initial: current?.initial ?? 0,
        dispensed: (current?.dispensed ?? 0) + ev.quantity,
        remaining: current?.remaining ?? 0,
      );
    }

    final meds = p.medications;
    debugPrint('DETAIL: medications from API count=${meds.length}');
    for (final m in meds) {
      debugPrint('DETAIL med: name=${m.name} initial=${m.initialQuantity} dispensed=${m.dispensedQuantity} remaining=${m.remainingQuantity}');
    }
    debugPrint('DETAIL: historyTotals count=${historyTotals.length}');
    for (final entry in historyTotals.entries) {
      debugPrint('DETAIL history: name=${entry.key} initial=${entry.value.initial} dispensed=${entry.value.dispensed} remaining=${entry.value.remaining}');
    }

    final displayMeds = meds.isNotEmpty
        ? meds
        : historyTotals.keys.map((name) {
            final totals = historyTotals[name]!;
            return MedicationInfo(
              name: name,
              initialQuantity: totals.initial,
              dispensedQuantity: totals.dispensed,
              remainingQuantity: totals.remaining,
              fullyDispensed: totals.remaining <= 0 && totals.dispensed > 0,
            );
          }).toList();

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'MEDICATIONS FROM DISPENSING HISTORY',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 12),
          if (displayMeds.isEmpty)
            Text('No medications dispensed yet.', style: TextStyle(color: AppColors.textFaint, fontSize: 13))
          else
            for (int i = 0; i < displayMeds.length; i++)
              Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(color: AppColors.tealPale, borderRadius: BorderRadius.circular(8)),
                        child: Icon(
                          displayMeds[i].fullyDispensed ? Icons.check_circle_outlined : Icons.medication_outlined,
                          size: 16,
                          color: displayMeds[i].fullyDispensed ? AppColors.success : AppColors.teal,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              displayMeds[i].name,
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _medicationQuantityText(displayMeds[i], historyTotals[displayMeds[i].name]),
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                            ),
                            if (displayMeds[i].fullyDispensed)
                              Text(
                                'Complete',
                                style: TextStyle(color: AppColors.success, fontSize: 11.5, fontWeight: FontWeight.w600),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (i < displayMeds.length - 1)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Divider(height: 1, color: AppColors.border),
                    ),
                ],
              ),
        ],
      ),
    );
  }

  String _medicationQuantityText(MedicationInfo med, ({int initial, int dispensed, int remaining})? historyTotal) {
    final initial = med.initialQuantity > 0 ? med.initialQuantity : (historyTotal?.initial ?? 0);
    final dispensed = med.dispensedQuantity > 0 ? med.dispensedQuantity : (historyTotal?.dispensed ?? 0);
    final remaining = med.remainingQuantity > 0 ? med.remainingQuantity : (historyTotal?.remaining ?? 0);
    if (initial > 0 || dispensed > 0) {
      return 'Dispensed: $dispensed of $initial · Remaining: $remaining';
    }
    return '';
  }

  Widget _buildRefillHistoryCard() {
    final p = _patient!;
    final events = p.refillHistory;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'DISPENSING HISTORY',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 14),
          if (events.isEmpty)
            Text('No dispensing history yet.', style: TextStyle(color: AppColors.textFaint, fontSize: 13))
          else
            for (int i = 0; i < events.length; i++)
              _buildTimelineRow(events[i], isLast: i == events.length - 1),
        ],
      ),
    );
  }

  Widget _buildTimelineRow(RefillEvent event, {required bool isLast}) {
    final isFlagged = event.isFlagged;
    final color = isFlagged ? AppColors.warning : AppColors.success;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
                child: Icon(
                  isFlagged ? Icons.warning_amber_rounded : Icons.check_circle,
                  size: 16,
                  color: color,
                ),
              ),
              if (!isLast) Expanded(child: Container(width: 1.5, color: AppColors.border)),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.medicineName,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '\u00d7${event.quantity} \u00b7 ${_fmtDate(event.date)}',
                    style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                  ),
                  if (event.expectedNextFill != null)
                    Text(
                      'Expected next fill: ${_fmtDate(event.expectedNextFill!)}',
                      style: const TextStyle(fontSize: 12, color: AppColors.textFaint),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoBanner() {
    final p = _patient!;
    if (_isFullyDispensed) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.tealPale, borderRadius: BorderRadius.circular(14)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.shield_outlined, color: AppColors.teal, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                p.adherenceReason ?? 'All prescriptions fully dispensed.',
                style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary, height: 1.4),
              ),
            ),
          ],
        ),
      );
    }

    if (p.isLocked) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.dangerBg, borderRadius: BorderRadius.circular(14)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.lock, color: AppColors.danger, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                p.lockReason ?? 'This prescription is locked.',
                style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary, height: 1.4),
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildAdminActionSection() {
    final p = _patient!;

    if (_isFullyDispensed) {
      return const SizedBox.shrink();
    }

    if (p.isLocked) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _isUpdating ? null : _confirmUnlock,
          icon: const Icon(Icons.lock_open, size: 18),
          label: const Text('Unlock Prescription'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.teal,
            side: const BorderSide(color: AppColors.teal),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      );
    }

    final hasFlagged = p.refillHistory.any((e) => e.isFlagged);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasFlagged)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.warningBg, borderRadius: BorderRadius.circular(12)),
            child: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: AppColors.warning, size: 18),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This patient has an overdue refill \u2014 review before dispensing further.',
                    style: TextStyle(color: AppColors.warning, fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _isUpdating ? null : _confirmLock,
            icon: _isUpdating
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.block, size: 18),
            label: const Text('Mark as Fully Dispensed'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Admin-only action. Use when over-dispensing has been confirmed.',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 11.5),
        ),
      ],
    );
  }

  Future<void> _confirmLock() async {
    final patient = _patient;
    if (patient == null || patient.prescriptionId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Mark as Fully Dispensed?'),
        content: Text(
          "This will lock ${patient.name}'s prescription from any further dispensing \u2014 at this pharmacy or any other branch. "
          'This action should only be used when over-dispensing has been confirmed. Continue?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger, foregroundColor: Colors.white),
            child: const Text('Confirm Lock'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isUpdating = true);
    try {
      await AdminApiService().lockPrescription(patient.prescriptionId!);
      if (mounted) {
        setState(() => _isUpdating = false);
        await _loadPatient();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Prescription locked \u2014 cannot be dispensed anywhere.')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isUpdating = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to lock: $e', style: const TextStyle(color: Colors.white)),
            backgroundColor: AppColors.danger,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _confirmUnlock() async {
    final patient = _patient;
    if (patient == null || patient.prescriptionId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Unlock this prescription?'),
        content: const Text('This will allow dispensing to resume for this prescription.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.teal, foregroundColor: Colors.white),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isUpdating = true);
    try {
      await AdminApiService().unlockPrescription(patient.prescriptionId!);
      if (mounted) {
        setState(() => _isUpdating = false);
        await _loadPatient();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Prescription unlocked.')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isUpdating = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to unlock: $e', style: const TextStyle(color: Colors.white)),
            backgroundColor: AppColors.danger,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: child,
    );
  }

  String _fmtDate(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}

class _ScoreRing extends StatelessWidget {
  final int score;
  final Color color;
  final Color trackColor;

  const _ScoreRing({required this.score, required this.color, required this.trackColor});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 72,
      child: CustomPaint(
        painter: _RingPainter(progress: (score / 100).clamp(0.0, 1.0), color: color, trackColor: trackColor),
        child: Center(
          child: Text(
            '$score%',
            style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 13),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color trackColor;

  _RingPainter({required this.progress, required this.color, required this.trackColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 5;

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;

    final progressPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, trackPaint);

    const startAngle = -math.pi / 2;
    final sweepAngle = 2 * math.pi * progress;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), startAngle, sweepAngle, false, progressPaint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
