import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../common/services/laravel_api_service.dart';
import '../../common/session.dart';
import '../../common/theme/app_colors.dart';
import '../../common/widgets/bottom_nav_bar.dart';
import '../../common/widgets/responsive_center.dart';
import '../models/adherence.dart';

class PatientAdherenceDetailScreen extends StatefulWidget {
  final String patientId;
  final Map<String, dynamic>? patient;
  final AdherenceStatus? adherence;

  const PatientAdherenceDetailScreen({
    super.key,
    required this.patientId,
    this.patient,
    this.adherence,
  });

  @override
  State<PatientAdherenceDetailScreen> createState() =>
      _PatientAdherenceDetailScreenState();
}

class _PatientAdherenceDetailScreenState
    extends State<PatientAdherenceDetailScreen> {
  bool _isLoading = true;
  bool _isNotFound = false;
  String? _errorMessage;
  Map<String, dynamic>? _patient;
  AdherenceStatus? _adherence;
  List<AdherenceHistoryItem> _history = [];

  @override
  void initState() {
    super.initState();
    debugPrint(
      'PatientAdherenceDetailScreen init: patientId=${widget.patientId}',
    );
    _patient = widget.patient;
    _adherence = widget.adherence;
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() {
      _isLoading = true;
      _isNotFound = false;
      _errorMessage = null;
    });

    try {
      final api = LaravelApiService(token: AppSession.instance.token);
      debugPrint('Fetching pharmacist patient detail for: ${widget.patientId}');

      _patient ??= await api.fetchPatient(widget.patientId);
      debugPrint('DETAIL: patient keys=${_patient?.keys.toList()}');

      AdherenceStatus? adherence;
      Map<String, dynamic>? statusJson;
      try {
        statusJson = await api.fetchPatientAdherence(widget.patientId);
        debugPrint('DETAIL adherence: keys=${statusJson.keys.toList()}');
        debugPrint(
          'DETAIL adherence: has medications=${statusJson['medications'] != null || statusJson['items'] != null || statusJson['medication_details'] != null || statusJson['medicine_list'] != null || statusJson['prescription_items'] != null || statusJson['drugs'] != null}',
        );
        debugPrint(
          'DETAIL adherence: has refill_history=${statusJson['refill_history'] != null || statusJson['refillHistory'] != null || statusJson['dispensing_history'] != null || statusJson['dispensingHistory'] != null || statusJson['dispensing_logs'] != null || statusJson['dispensingLogs'] != null}',
        );
        debugPrint(
          'DETAIL adherence: adherence_percent=${statusJson['adherence_percent'] ?? statusJson['adherencePercent'] ?? statusJson['score'] ?? statusJson['percentage']}',
        );
        adherence = AdherenceStatus.fromJson(statusJson);
        debugPrint(
          'DETAIL: parsed adherence score=${adherence.score} hasData=${adherence.hasData} medNames=${adherence.medicationNames} refillHistoryCount=${adherence.refillHistory.length}',
        );
      } catch (e) {
        debugPrint('DETAIL: adherence fetch failed: $e');
        adherence = AdherenceStatus.noData();
      }

      List<AdherenceHistoryItem> history = List.from(adherence.refillHistory);
      debugPrint(
        'DETAIL: history from adherence.refillHistory count=${history.length}',
      );

      if (history.isEmpty) {
        try {
          final historyJson = await api.fetchPatientDispensingHistory(
            widget.patientId,
          );
          debugPrint(
            'DETAIL: dispensing-history endpoint returned ${historyJson.length} items',
          );
          history = historyJson
              .map((e) => AdherenceHistoryItem.fromJson(e))
              .toList();
          debugPrint('DETAIL: parsed history items count=${history.length}');
          for (final item in history) {
            debugPrint(
              'DETAIL history item: med=${item.medicineName} qty=${item.quantityServed}/${item.dispensedQuantity} date=${item.dispensedAt}',
            );
          }
        } catch (e) {
          debugPrint('DETAIL: dispensing-history fetch failed: $e');
          history = [];
        }
      }

      if (history.isEmpty) {
        final prescriptionId =
            _patient?['prescription_id']?.toString() ??
            _patient?['prescriptionId']?.toString() ??
            _patient?['backend_id']?.toString() ??
            _patient?['backendId']?.toString() ??
            _patient?['id']?.toString();
        if (prescriptionId != null && prescriptionId.isNotEmpty) {
          try {
            debugPrint(
              'DETAIL: trying fetchDispensingLogs with prescriptionId=$prescriptionId',
            );
            final logs = await api.fetchDispensingLogs(prescriptionId);
            debugPrint(
              'DETAIL: dispensing-logs endpoint returned ${logs.length} items',
            );
            history = logs
                .map(
                  (log) => AdherenceHistoryItem(
                    logId: log.logId,
                    prescriptionId: log.prescriptionId,
                    medicineName: log.productName,
                    quantityServed: log.quantityServed,
                    dispensedAt: log.dispensedAt ?? DateTime.now(),
                    pharmacyId: log.pharmacyId,
                    dispenserId: log.dispenserId,
                    daysSupply: 0,
                    expectedNextFill: null,
                    flag: log.status,
                    initialQuantity: 0,
                    dispensedQuantity: log.quantityServed,
                    remainingQuantity: 0,
                    fullyDispensed: false,
                  ),
                )
                .toList();
            debugPrint(
              'DETAIL: converted dispensing logs to history items count=${history.length}',
            );
          } catch (e) {
            debugPrint('DETAIL: dispensing-logs fetch failed: $e');
          }
        }
      }

      if (history.isNotEmpty && !adherence.hasData) {
        adherence = adherence.copyWith(hasData: true, hasHistory: true);
      }

      if (mounted) {
        setState(() {
          _patient = _patient;
          _adherence = adherence;
          _history = history;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString();
        setState(() {
          _isNotFound =
              msg.contains('Patient not found') || msg.contains('404');
          _errorMessage = _isNotFound
              ? null
              : 'Failed to load patient detail: $e';
          _isLoading = false;
        });
      }
    }
  }

  /// Authoritative per-medicine totals for this patient, sourced from
  /// `_patient['medications']` (the /patients/{id} endpoint). Unlike
  /// `_history` (the dispensing-log timeline), this always carries the real
  /// prescribed quantity, so it's the only source we trust to decide
  /// whether a prescription is actually fully — or over — dispensed.
  Map<
    String,
    ({int initial, int dispensed, int remaining, bool fullyDispensed})
  >
  get _medTotalsFromPatient {
    final result =
        <
          String,
          ({int initial, int dispensed, int remaining, bool fullyDispensed})
        >{};
    final meds = _patient?['medications'];
    if (meds is! List) return result;

    for (final raw in meds) {
      if (raw is! Map) continue;
      final mm = Map<String, dynamic>.from(raw);
      final name =
          mm['medicine_name']?.toString() ?? mm['name']?.toString() ?? '';
      if (name.isEmpty) continue;

      final initial = int.tryParse('${mm['quantity'] ?? 0}') ?? 0;
      final dispensed = int.tryParse('${mm['dispensed_quantity'] ?? 0}') ?? 0;
      final remaining =
          int.tryParse(
            '${mm['quantity_remaining'] ?? (initial - dispensed)}',
          ) ??
          (initial - dispensed);
      final status = mm['dispensing_status']?.toString() ?? '';
      final fullyDispensed =
          status == 'fully_dispensed' || (initial > 0 && dispensed >= initial);

      final current = result[name];
      result[name] = (
        initial: (current?.initial ?? 0) + initial,
        dispensed: (current?.dispensed ?? 0) + dispensed,
        remaining: (current?.remaining ?? 0) + remaining,
        fullyDispensed: fullyDispensed && (current?.fullyDispensed ?? true),
      );
    }
    return result;
  }

  AdherenceTier get _tier {
    final adherence = _adherence;
    final medTotals = _medTotalsFromPatient;

    // Only medTotals (real prescribed quantities) can prove a prescription
    // is fully or over dispensed. _history never carries prescribed
    // quantities reliably, so it is no longer used for this decision — using
    // it previously caused prescriptions to show as "Fully Dispensed" after
    // a single partial fill.
    if (medTotals.isNotEmpty) {
      if (medTotals.values.any(
        (t) => t.initial > 0 && t.dispensed > t.initial,
      )) {
        return AdherenceTier.overDispensing;
      }
      if (medTotals.values.every((t) => t.initial > 0 && t.fullyDispensed)) {
        return AdherenceTier.fullyDispensed;
      }
    }

    return adherence?.tier ?? AdherenceTier.good;
  }

  bool get _hasHistory => _adherence?.hasHistory ?? _history.isNotEmpty;

  (Color, Color, String) get _tierStyle {
    if (_tier == AdherenceTier.fullyDispensed) {
      return (
        const Color(0xFF6B7280),
        const Color(0xFFF3F4F6),
        'Fully Dispensed',
      );
    }
    if (!_hasHistory) {
      return (
        AppColors.textFaint,
        AppColors.border.withValues(alpha: 0.08),
        'No data yet',
      );
    }
    switch (_tier) {
      case AdherenceTier.good:
        return (AppColors.success, AppColors.successBg, 'Good');
      case AdherenceTier.atRisk:
        return (AppColors.warning, AppColors.warningBg, 'At Risk');
      case AdherenceTier.critical:
        return (AppColors.danger, AppColors.dangerBg, 'Critical');
      case AdherenceTier.overDispensing:
        return (AppColors.danger, AppColors.dangerBg, 'Overdispensing');
      case AdherenceTier.fullyDispensed:
        return (
          const Color(0xFF6B7280),
          const Color(0xFFF3F4F6),
          'Fully Dispensed',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final (tierColor, tierBg, tierLabel) = _tierStyle;
    final name = _patient?['name'] ?? 'Unknown Patient';

    if (_isNotFound) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(context, name),
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.person_off_outlined,
                          size: 48,
                          color: AppColors.textFaint,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Patient not found',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'The patient record could not be found. It may have been removed.',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 13,
                          ),
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
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: _buildBottomNav(context),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context, name),
            Expanded(
              child: ResponsiveCenter.dashboard(
                padding: EdgeInsets.zero,
                child: _isLoading
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: AppColors.teal),
                            SizedBox(height: 16),
                            Text(
                              'Loading patient data...',
                              style: TextStyle(color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      )
                    : _errorMessage != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.error_outline,
                                size: 44,
                                color: AppColors.danger,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                _errorMessage!,
                                style: const TextStyle(color: AppColors.danger),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 10),
                              ElevatedButton.icon(
                                onPressed: _loadDetail,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        children: [
                          _buildScoreCard(tierColor, tierBg, tierLabel),
                          const SizedBox(height: 14),
                          _buildMedicationsCard(),
                          const SizedBox(height: 14),
                          _buildRefillHistoryCard(),
                          const SizedBox(height: 14),
                          _buildInfoBanner(),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomNav(context),
    );
  }

  Widget _buildHeader(BuildContext context, String name) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 20, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _genderAgeDisplay,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textFaint,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String get _genderAgeDisplay {
    final patient = _patient;
    if (patient == null) return 'Loading...';
    final ageRaw =
        patient['age'] ?? patient['patient_age'] ?? patient['age_years'];
    final age = ageRaw is int ? ageRaw : int.tryParse('${ageRaw ?? ''}') ?? 0;
    final ageStr = age > 0 ? age.toString() : '';
    final gender =
        (patient['gender'] ??
                patient['sex'] ??
                patient['gender_identity'] ??
                '')
            .toString();
    final id = widget.patientId;
    final parts = <String>[];
    if (ageStr.isNotEmpty || gender.isNotEmpty) parts.add('$ageStr$gender');
    parts.add(id);
    return parts.join(' · ');
  }

  Widget _buildScoreCard(Color tierColor, Color tierBg, String tierLabel) {
    final adherence = _adherence;
    final isFullyDispensed = _tier == AdherenceTier.fullyDispensed;
    final score = isFullyDispensed ? 100 : (adherence?.score ?? 0);
    final displayScore = isFullyDispensed
        ? 100
        : (adherence?.hasData == true ? score : 0);

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
                  style: TextStyle(
                    color: tierColor,
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$displayScore%',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_adherence != null && _adherence!.reason.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    _adherence!.reason,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                      fontStyle: FontStyle.italic,
                    ),
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
    // Prefer the authoritative per-medicine totals from the patient record
    // (real prescribed quantities). Only fall back to reconstructing totals
    // from the dispensing-log timeline when that data isn't available —
    // and even then, never claim "fully dispensed" without a real
    // prescribed quantity to compare against (that false positive is what
    // caused prescriptions to show as complete after a single partial fill).
    var medTotals = _medTotalsFromPatient;

    if (medTotals.isEmpty) {
      final fallback =
          <
            String,
            ({int initial, int dispensed, int remaining, bool fullyDispensed})
          >{};
      for (final item in _history) {
        final current = fallback[item.medicineName];
        final dispensed = item.dispensedQuantity > 0
            ? item.dispensedQuantity
            : item.quantityServed;
        final remaining = item.remainingQuantity > 0
            ? item.remainingQuantity
            : 0;
        final initial = item.initialQuantity > 0
            ? item.initialQuantity
            : (current?.initial ?? 0);
        final fullyDispensed =
            initial > 0 &&
            (item.fullyDispensed || (current?.fullyDispensed ?? false));
        fallback[item.medicineName] = (
          initial: initial,
          dispensed: (current?.dispensed ?? 0) + dispensed,
          remaining: (current?.remaining ?? 0) + remaining,
          fullyDispensed: fullyDispensed,
        );
      }
      medTotals = fallback;
    }

    if (medTotals.isEmpty && _adherence != null) {
      final placeholders =
          <
            String,
            ({int initial, int dispensed, int remaining, bool fullyDispensed})
          >{};
      for (final name in _adherence!.medicationNames) {
        if (name.isNotEmpty) {
          placeholders[name] = (
            initial: 0,
            dispensed: 0,
            remaining: 0,
            fullyDispensed: false,
          );
        }
      }
      medTotals = placeholders;
    }

    final medEntries = medTotals.entries.toList();

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
          if (medEntries.isEmpty)
            Text(
              'No medications dispensed yet.',
              style: TextStyle(color: AppColors.textFaint, fontSize: 13),
            )
          else
            ...medEntries.map((entry) {
              final isLast = entry == medEntries.last;
              final totals = entry.value;
              return Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: AppColors.tealPale,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          totals.fullyDispensed
                              ? Icons.check_circle_outlined
                              : Icons.medication_outlined,
                          size: 16,
                          color: totals.fullyDispensed
                              ? AppColors.success
                              : AppColors.teal,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.key,
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            if (totals.initial > 0 || totals.dispensed > 0)
                              Text(
                                'Dispensed: ${totals.dispensed} of ${totals.initial} · Remaining: ${totals.remaining}',
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 12,
                                ),
                              ),
                            if (totals.fullyDispensed)
                              Text(
                                'Complete',
                                style: TextStyle(
                                  color: AppColors.success,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (!isLast)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Divider(height: 1, color: AppColors.border),
                    ),
                ],
              );
            }),
        ],
      ),
    );
  }

  Widget _buildRefillHistoryCard() {
    final events = _history;
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
            Text(
              'No dispensing history yet.',
              style: TextStyle(color: AppColors.textFaint, fontSize: 13),
            )
          else
            for (int i = 0; i < events.length; i++)
              _buildTimelineRow(events[i], isLast: i == events.length - 1),
        ],
      ),
    );
  }

  Widget _buildTimelineRow(AdherenceHistoryItem event, {required bool isLast}) {
    final isFlagged = event.flag != null && event.flag!.isNotEmpty;
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
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isFlagged ? Icons.warning_amber_rounded : Icons.check_circle,
                  size: 16,
                  color: color,
                ),
              ),
              if (!isLast)
                Expanded(child: Container(width: 1.5, color: AppColors.border)),
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
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '×${event.quantityServed} · ${_fmtDate(event.dispensedAt)}',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (event.expectedNextFill != null)
                    Text(
                      'Expected next fill: ${_fmtDate(event.expectedNextFill!)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textFaint,
                      ),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.tealPale,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.shield_outlined, color: AppColors.teal, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _adherence?.reason ??
                  'View only. Contact a pharmacist or admin to send reminders or make updates.',
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomNav(BuildContext context) {
    // This screen is pushed on top of the Home shell's Patients tab, so it
    // reuses the exact same 5-item list (see BottomNavBar.pharmacistItems)
    // instead of a hand-typed copy — that copy previously had only 4 items
    // (missing "Dispense") and a currentIndex that didn't even match its own
    // list, which is why the bar visibly changed shape between screens.
    return BottomNavBar(
      currentIndex: BottomNavBar.pharmacistPatientsIndex,
      onTap: (i) {
        // Already on Patients — nothing to do.
        if (i == BottomNavBar.pharmacistPatientsIndex) return;
        // Any other tab lives on the Home shell underneath this screen, so
        // pop back to it. (The shell itself was already on some tab; this
        // at least returns to a fully-formed, consistent nav bar rather than
        // silently doing nothing.)
        Navigator.of(context).pop();
      },
      items: BottomNavBar.pharmacistItems,
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }

  String _fmtDate(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}

class _ScoreRing extends StatelessWidget {
  final int score;
  final Color color;
  final Color trackColor;

  const _ScoreRing({
    required this.score,
    required this.color,
    required this.trackColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 72,
      child: CustomPaint(
        painter: _RingPainter(
          progress: (score / 100).clamp(0.0, 1.0),
          color: color,
          trackColor: trackColor,
        ),
        child: Center(
          child: Text(
            '$score%',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
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

  _RingPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
  });

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
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
