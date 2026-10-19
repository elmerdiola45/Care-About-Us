import 'package:flutter/material.dart';
import '../../common/services/laravel_api_service.dart';
import '../../common/session.dart';
import '../../common/theme/app_colors.dart';
import '../../common/theme/app_theme.dart';
import '../../common/services/app_config.dart';
import '../../common/widgets/responsive_center.dart';
import '../models/adherence.dart';
import 'patient_adherence_detail_screen.dart';

class PatientAdherenceScreen extends StatefulWidget {
  const PatientAdherenceScreen({super.key});

  @override
  State<PatientAdherenceScreen> createState() => _PatientAdherenceScreenState();
}

class _PatientAdherenceScreenState extends State<PatientAdherenceScreen> {
  final TextEditingController _searchController = TextEditingController();
  AdherenceTier? _selectedTier;
  bool _isLoading = true;
  String? _errorMessage;
  final List<_PharmacistAdherenceRecord> _records = [];

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadRecords() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final api = LaravelApiService(token: AppSession.instance.token);

      // The whole list in ONE request instead of 1–2 per patient. The
      // per-patient path below only runs if this fails (e.g. a backend that
      // predates the fixed /patients/adherence endpoint).
      try {
        final rows = await api.fetchAllPatientsAdherence();
        final records = rows.map(_recordFromBulkRow).toList();
        debugPrint('Pharmacist adherence: bulk loaded ${records.length}');
        if (mounted) {
          setState(() {
            _records
              ..clear()
              ..addAll(records);
            _isLoading = false;
          });
        }
        return;
      } catch (e) {
        debugPrint('Pharmacist adherence: bulk load failed, per-patient: $e');
      }

      final patients = await api.fetchPatients();
      debugPrint('Pharmacist adherence: fetched ${patients.length} patients');

      // Capped at 3 in flight (same as SavedPrescriptionsStore's adherence
      // prefetch): firing one request per patient all at once queued them
      // behind Render's 4 PHP-FPM workers, and the ones at the back hit the
      // 30s client timeout — "Could not load adherence data for N out of M
      // patients". Batches keep `results` in the same order as `patients`.
      const maxConcurrent = 3;
      final results =
          <
            ({
              _PharmacistAdherenceRecord record,
              bool adherenceOk,
              String? error,
            })
          >[];
      for (var i = 0; i < patients.length; i += maxConcurrent) {
        final batch = patients.skip(i).take(maxConcurrent);
        results.addAll(
          await Future.wait(batch.map((p) => _loadOneRecord(api, p))),
        );
      }

      // One sequential retry for patients whose adherence call failed
      // (transient timeout / cold-start 5xx) before reporting them.
      for (var i = 0; i < results.length; i++) {
        if (results[i].adherenceOk) continue;
        results[i] = await _loadOneRecord(api, patients[i]);
      }

      final List<_PharmacistAdherenceRecord> records = [];
      int adherenceSuccessCount = 0;
      int adherenceFailCount = 0;
      String? adherenceError;

      for (final r in results) {
        records.add(r.record);
        if (r.adherenceOk) {
          adherenceSuccessCount++;
        } else {
          adherenceFailCount++;
          adherenceError ??= r.error;
        }
      }

      debugPrint(
        'Pharmacist adherence: success=$adherenceSuccessCount fail=$adherenceFailCount',
      );

      if (mounted) {
        setState(() {
          _records
            ..clear()
            ..addAll(records);
          _isLoading = false;
          if (adherenceFailCount > 0 && adherenceSuccessCount == 0) {
            _errorMessage =
                'Failed to load patient adherence data from server.\n\nError: $adherenceError\n\nPlease check if the backend is running and the /api/patients/{id}/adherence endpoint is accessible.';
          } else if (adherenceFailCount > 0) {
            _errorMessage =
                'Note: Could not load adherence data for $adherenceFailCount out of ${patients.length} patients. Pull down to retry.';
          }
        });
      }
    } on LaravelApiException catch (e) {
      if (mounted) {
        String message = 'Failed to load patients.';
        final lower = e.message.toLowerCase();
        if (lower.contains('connection reset') ||
            lower.contains('connection reset by peer') ||
            lower.contains('socket exception')) {
          message =
              'Cannot connect to the server. Please check your internet connection and make sure the backend is running at ${AppConfig.baseUrl}.';
        } else if (lower.contains('connection refused') ||
            lower.contains('no route to host')) {
          message =
              'Cannot reach the server. The backend may be offline or the address is wrong.';
        } else if (lower.contains('timed out') || lower.contains('timeout')) {
          message = 'Server response timed out. Please try again.';
        } else {
          message = 'Failed to load patients: ${e.message}';
        }
        setState(() {
          _errorMessage = message;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        String message = 'Failed to load patients.';
        final lower = e.toString().toLowerCase();
        if (lower.contains('connection reset') ||
            lower.contains('connection reset by peer') ||
            lower.contains('socket exception')) {
          message =
              'Cannot connect to the server. Please check your internet connection and make sure the backend is running at ${AppConfig.baseUrl}.';
        } else if (lower.contains('connection refused') ||
            lower.contains('no route to host')) {
          message =
              'Cannot reach the server. The backend may be offline or the address is wrong.';
        } else if (lower.contains('timed out') || lower.contains('timeout')) {
          message = 'Server response timed out. Please try again.';
        } else {
          message = 'Failed to load patients: $e';
        }
        setState(() {
          _errorMessage = message;
          _isLoading = false;
        });
      }
    }
  }

  /// Same record _loadOneRecord() builds, from a /patients/adherence row
  /// (which already carries name/age/gender and the adherence fields).
  _PharmacistAdherenceRecord _recordFromBulkRow(Map<String, dynamic> row) {
    var adherence = AdherenceStatus.fromJson(row);
    final medications = <String>[
      ...adherence.medicationNames.where((name) => name.isNotEmpty),
    ];
    var lastFill =
        DateTime.tryParse(row['last_fill']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    for (final item in adherence.refillHistory) {
      if (item.medicineName.isNotEmpty &&
          !medications.contains(item.medicineName)) {
        medications.add(item.medicineName);
      }
      if (item.dispensedAt.isAfter(lastFill)) lastFill = item.dispensedAt;
    }
    if (!adherence.hasData && medications.isNotEmpty) {
      adherence = adherence.copyWith(hasData: true, hasHistory: true);
    }

    return _PharmacistAdherenceRecord(
      patientId: row['patient_id']?.toString() ?? '',
      name: row['patient_name']?.toString() ?? 'Unknown',
      age: int.tryParse('${row['age']}') ?? 0,
      sex: row['gender']?.toString() ?? '',
      lastFill: lastFill,
      adherence: adherence,
      medications: medications,
      fullHistory: false,
    );
  }

  /// One patient's adherence lookup, extracted from the old sequential loop
  /// so _loadRecords() can run every patient concurrently via Future.wait.
  /// Logic is unchanged from the original loop body — only the surrounding
  /// concurrency changed.
  Future<({_PharmacistAdherenceRecord record, bool adherenceOk, String? error})>
  _loadOneRecord(LaravelApiService api, Map<String, dynamic> patient) async {
    final patientId = patient['patient_id']?.toString() ?? '';
    AdherenceStatus adherence;
    bool adherenceLoaded = false;
    bool adherenceOk = false;
    String? error;
    Map<String, dynamic>? statusJson;
    try {
      statusJson = await api.fetchPatientAdherence(patientId);
      debugPrint(
        'LIST: patient=$patientId adherence keys=${statusJson.keys.toList()}',
      );
      debugPrint(
        'LIST: patient=$patientId has medications=${statusJson['medications'] != null || statusJson['items'] != null || statusJson['medication_details'] != null || statusJson['medicine_list'] != null || statusJson['prescription_items'] != null || statusJson['drugs'] != null} has refill_history=${statusJson['refill_history'] != null || statusJson['refillHistory'] != null || statusJson['dispensing_history'] != null || statusJson['dispensingHistory'] != null || statusJson['dispensing_logs'] != null || statusJson['dispensingLogs'] != null}',
      );
      adherence = AdherenceStatus.fromJson(statusJson);
      debugPrint(
        'LIST: patient=$patientId medNames=${adherence.medicationNames} refillCount=${adherence.refillHistory.length} score=${adherence.score} hasData=${adherence.hasData}',
      );
      adherenceLoaded = true;
      adherenceOk = true;
    } catch (e) {
      error = e.toString();
      debugPrint('LIST: patient=$patientId adherence fetch failed: $e');
      adherence = AdherenceStatus(
        status: 'good',
        reason: adherenceLoaded
            ? 'No dispensing history yet.'
            : 'Failed to load adherence data.',
        lastCalculatedAt: DateTime.now(),
      );
    }

    final medications = <String>[];
    medications.addAll(
      adherence.medicationNames.where(
        (name) => name.isNotEmpty && !medications.contains(name),
      ),
    );
    final lastFillRaw =
        patient['last_fill']?.toString() ??
        patient['lastFill']?.toString() ??
        statusJson?['last_fill']?.toString() ??
        statusJson?['lastFill']?.toString() ??
        '';
    DateTime lastFill =
        DateTime.tryParse(lastFillRaw) ??
        DateTime.fromMillisecondsSinceEpoch(0);

    // Use refill_history already parsed by AdherenceStatus.fromJson, fall back to separate endpoint
    for (final item in adherence.refillHistory) {
      if (item.medicineName.isNotEmpty &&
          !medications.contains(item.medicineName)) {
        medications.add(item.medicineName);
      }
      if (item.dispensedAt.isAfter(lastFill)) {
        lastFill = item.dispensedAt;
      }
    }

    if (medications.isEmpty &&
        lastFill.millisecondsSinceEpoch == 0 &&
        patientId.isNotEmpty) {
      try {
        final historyJson = await api.fetchPatientDispensingHistory(patientId);
        for (final e in historyJson) {
          final item = AdherenceHistoryItem.fromJson(e);
          if (item.medicineName.isNotEmpty &&
              !medications.contains(item.medicineName)) {
            medications.add(item.medicineName);
          }
          if (item.dispensedAt.isAfter(lastFill)) {
            lastFill = item.dispensedAt;
          }
        }
      } catch (e) {
        debugPrint(
          'Pharmacist adherence: failed to load dispensing history for patient $patientId: $e',
        );
      }
    }

    if (!adherence.hasData && medications.isNotEmpty) {
      adherence = adherence.copyWith(hasData: true, hasHistory: true);
    }

    final record = _PharmacistAdherenceRecord(
      patientId: patientId,
      name: patient['name']?.toString() ?? 'Unknown',
      age: patient['age'] ?? patient['patient_age'] ?? 0,
      sex: patient['gender']?.toString() ?? patient['sex']?.toString() ?? '',
      lastFill: lastFill,
      adherence: adherence,
      medications: medications,
    );

    return (record: record, adherenceOk: adherenceOk, error: error);
  }

  List<_PharmacistAdherenceRecord> get _filtered {
    final query = _searchController.text.trim().toLowerCase();
    return _records.where((r) {
      final matchesSearch =
          query.isEmpty ||
          r.name.toLowerCase().contains(query) ||
          r.patientId.toLowerCase().contains(query);
      final matchesTier = _selectedTier == null || r.tier == _selectedTier;
      return matchesSearch && matchesTier;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.teal),
        title: const Text(
          'Prescription Adherence',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.teal),
            tooltip: 'Refresh',
            onPressed: _isLoading ? null : _loadRecords,
          ),
        ],
      ),
      // Search, filters and list share one centered column so they line up
      // on wide screens (the search bar used to span the whole window).
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            children: [
              _buildSearchBar(),
              _buildFilterChips(),
              const SizedBox(height: 8),
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
                                'Loading prescriptions...',
                                style: TextStyle(
                                  color: AppColors.textSecondary,
                                ),
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
                                const SizedBox(height: 12),
                                Text(
                                  _errorMessage!,
                                  style: const TextStyle(
                                    color: AppColors.danger,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 12),
                                ElevatedButton.icon(
                                  onPressed: _loadRecords,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Retry'),
                                ),
                              ],
                            ),
                          ),
                        )
                      : _filtered.isEmpty
                      ? _buildEmptyState()
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                          itemCount: _filtered.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) =>
                              _buildPrescriptionCard(_filtered[index]),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: TextField(
          controller: _searchController,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: 'Search by patient name or Rx number...',
            hintStyle: TextStyle(color: AppColors.textFaint, fontSize: 14),
            prefixIcon: Icon(
              Icons.search,
              color: Colors.grey.shade400,
              size: 20,
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChips() {
    final chips = <(String, AdherenceTier?)>[
      ('All', null),
      ('Pending', AdherenceTier.critical),
      ('Partially Dispensed', AdherenceTier.atRisk),
      ('Fully Dispensed', AdherenceTier.fullyDispensed),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: chips.map((chip) {
            final (label, value) = chip;
            final isSelected = _selectedTier == value;
            return Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ChoiceChip(
                label: Text(label),
                selected: isSelected,
                onSelected: (_) => setState(() => _selectedTier = value),
                showCheckmark: false,
                labelStyle: TextStyle(
                  color: isSelected ? Colors.white : Colors.grey.shade600,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
                backgroundColor: Colors.white,
                selectedColor: AppColors.teal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: AppColors.border),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildPrescriptionCard(_PharmacistAdherenceRecord record) {
    final (bg, fg) = _tierColors(record.tier);
    final initials = record.name.isNotEmpty
        ? record.name
              .trim()
              .split(RegExp(r'\s+'))
              .map((w) => w.isNotEmpty ? w[0] : '')
              .take(2)
              .join()
              .toUpperCase()
        : '?';

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PatientAdherenceDetailScreen(
              patientId: record.patientId,
              patient: {
                'patient_id': record.patientId,
                'name': record.name,
                'age': record.age,
                'gender': record.sex,
                'last_fill': record.lastFill.toIso8601String(),
              },
              adherence: record.adherence,
              fullHistory: record.fullHistory,
            ),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.fromBorderSide(BorderSide(color: AppColors.border)),
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.teal,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                initials,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          record.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: AppColors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          record.patientId,
                          style: appMono(color: AppColors.textSecondary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _secondaryLine(record),
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  if (record.medications.isNotEmpty)
                    Text(
                      record.medications.join(', '),
                      style: const TextStyle(
                        color: AppColors.teal,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  else
                    Text(
                      'No medications',
                      style: TextStyle(
                        color: AppColors.textFaint,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    switch (record.tier) {
                      AdherenceTier.good => 'Good',
                      AdherenceTier.atRisk => 'Partially Dispensed',
                      // `critical` covers both `pending` and `no_data` (see
                      // tierFor / admin reference) — distinguish by raw status.
                      AdherenceTier.critical =>
                        record.adherence.status == 'no_data'
                            ? 'No Data'
                            : 'Pending',
                      AdherenceTier.overDispensing => 'Overdispensing',
                      AdherenceTier.fullyDispensed => 'Fully Dispensed',
                    },
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  (Color, Color) _tierColors(AdherenceTier tier) {
    switch (tier) {
      case AdherenceTier.good:
        return (AppColors.successBg, AppColors.success);
      case AdherenceTier.atRisk:
        return (AppColors.warningBg, AppColors.warning);
      case AdherenceTier.critical:
        return (AppColors.dangerBg, AppColors.danger);
      case AdherenceTier.overDispensing:
        return (AppColors.dangerBg, AppColors.danger);
      case AdherenceTier.fullyDispensed:
        return (const Color(0xFFE5E7EB), const Color(0xFF6B7280));
    }
  }

  String _secondaryLine(_PharmacistAdherenceRecord r) {
    final parts = <String>[];
    final ageStr = r.age > 0 ? r.age.toString() : '';
    final sexStr = r.sex.trim();
    if (ageStr.isNotEmpty || sexStr.isNotEmpty) parts.add('$ageStr$sexStr');
    if (r.adherence.hasData && r.lastFill.millisecondsSinceEpoch > 0) {
      parts.add('Last fill: ${_fmtDate(r.lastFill)}');
    } else if (!r.adherence.hasData) {
      parts.add('No dispensing history yet');
    }
    return parts.join(' \u00b7 ');
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

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.people_outline,
              size: 44,
              color: AppColors.textFaint,
            ),
            const SizedBox(height: 12),
            Text(
              _searchController.text.trim().isEmpty
                  ? 'No patients found'
                  : 'No matching patients',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PharmacistAdherenceRecord {
  final String patientId;
  final String name;
  final int age;
  final String sex;
  final DateTime lastFill;
  final AdherenceStatus adherence;
  final List<String> medications;

  /// False when built from the bulk endpoint, whose refill_history is
  /// trimmed to the last 3 fills — the detail screen then fetches the rest.
  final bool fullHistory;

  _PharmacistAdherenceRecord({
    required this.patientId,
    required this.name,
    required this.age,
    required this.sex,
    required this.lastFill,
    required this.adherence,
    required this.medications,
    this.fullHistory = true,
  });

  AdherenceTier get tier => adherence.tier;
}
