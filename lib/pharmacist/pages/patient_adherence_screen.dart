import 'package:flutter/material.dart';
import '../../common/services/laravel_api_service.dart';
import '../../common/session.dart';
import '../../common/theme/app_colors.dart';
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
      final patients = await api.fetchPatients();
      debugPrint('Pharmacist adherence: fetched ${patients.length} patients');

      // Was a sequential await-per-patient loop — one of the two N+1 chains
      // that made this screen (and the dashboard, which pre-warms it) slow.
      // Future.wait preserves input order, so `results` lines up with
      // `patients` exactly as the old sequential loop did — no change to
      // list ordering or per-patient behavior, just concurrency.
      final results = await Future.wait(
        patients.map((patient) => _loadOneRecord(api, patient)),
      );

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

  /// One patient's adherence lookup, extracted from the old sequential loop
  /// so _loadRecords() can run every patient concurrently via Future.wait.
  /// Logic is unchanged from the original loop body — only the surrounding
  /// concurrency changed.
  Future<
    ({_PharmacistAdherenceRecord record, bool adherenceOk, String? error})
  >
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
        final historyJson = await api.fetchPatientDispensingHistory(
          patientId,
        );
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
            fontWeight: FontWeight.w700,
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
      body: Column(
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
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) =>
                          _buildPrescriptionCard(_filtered[index]),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFEEF0F3)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: TextField(
          controller: _searchController,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: 'Search by patient name or Rx number...',
            hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13.5),
            prefixIcon: Icon(
              Icons.search,
              color: Colors.grey.shade400,
              size: 20,
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
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
              padding: const EdgeInsets.only(right: 10),
              child: ChoiceChip(
                label: Text(label),
                selected: isSelected,
                onSelected: (_) => setState(() => _selectedTier = value),
                showCheckmark: false,
                labelStyle: TextStyle(
                  color: isSelected ? Colors.white : Colors.grey.shade600,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
                backgroundColor: Colors.white,
                selectedColor: AppColors.teal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: const BorderSide(color: Color(0xFFEEF0F3)),
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
            ),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
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
                  fontWeight: FontWeight.w700,
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
                            fontWeight: FontWeight.w700,
                            fontSize: 14.5,
                            color: AppColors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Rx: ${record.patientId}',
                          style: TextStyle(
                            color: Colors.grey.shade500,
                            fontSize: 11,
                          ),
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
                        color: Colors.grey.shade400,
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
                    horizontal: 10,
                    vertical: 5,
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
                        record.adherence.status == 'no_data' ? 'No Data' : 'Pending',
                      AdherenceTier.overDispensing => 'Overdispensing',
                      AdherenceTier.fullyDispensed => 'Fully Dispensed',
                    },
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
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
            const SizedBox(height: 10),
            Text(
              _searchController.text.trim().isEmpty
                  ? 'No patients found'
                  : 'No matching patients',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
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

  _PharmacistAdherenceRecord({
    required this.patientId,
    required this.name,
    required this.age,
    required this.sex,
    required this.lastFill,
    required this.adherence,
    required this.medications,
  });

  AdherenceTier get tier => adherence.tier;
}
