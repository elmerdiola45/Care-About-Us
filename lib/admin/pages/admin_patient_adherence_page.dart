import 'package:flutter/material.dart';
import '../../common/theme/app_colors.dart';
import '../../common/widgets/responsive_center.dart';
import '../data/admin_api_service.dart';
import '../models/admin_models.dart';
import '../models/admin_patient_adherence.dart';
import 'admin_patient_adherence_detail_page.dart';

int _safePositiveIntFromMap(
  Map<String, dynamic>? map,
  List<String> keys, [
  int fallback = 0,
]) {
  if (map == null) return fallback;
  for (final key in keys) {
    final value = map[key];
    if (value == null) continue;
    final parsed = _toPositiveInt(value);
    if (parsed != null && parsed > 0) return parsed;
  }
  return fallback;
}

int _safeIntFromMap(
  Map<String, dynamic>? map,
  List<String> keys, [
  int fallback = 0,
]) {
  if (map == null) return fallback;
  for (final key in keys) {
    final value = map[key];
    if (value == null) continue;
    final parsed = _toInt(value);
    if (parsed != null) return parsed;
  }
  return fallback;
}

int? _toInt(dynamic value) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is num) return value.toInt();
  final str = value.toString().trim();
  if (str.isEmpty) return null;
  final d = double.tryParse(str);
  if (d != null) return d.toInt();
  return int.tryParse(str);
}

int? _toPositiveInt(dynamic value) {
  final result = _toInt(value);
  return result != null && result > 0 ? result : null;
}

int _safePositiveIntFromAnyKey(Map<String, dynamic>? map, [int fallback = 0]) {
  if (map == null) return fallback;
  debugPrint(
    'FALLBACK SCAN: entering fallback for map keys=${map.keys.toList()}',
  );
  for (final entry in map.entries) {
    final value = entry.value;
    if (value == null) continue;
    if (value is String && value.toString().trim().isEmpty) continue;
    if (value is bool) continue;
    if (value is Map || value is List) continue;
    final parsed = _toPositiveInt(value);
    if (parsed != null) {
      debugPrint(
        'FALLBACK SCAN: found key=${entry.key} rawValue=$value type=${value.runtimeType} parsed=$parsed',
      );
      return parsed;
    }
  }
  debugPrint('FALLBACK SCAN: no positive int found');
  return fallback;
}

class AdminPatientAdherencePage extends StatefulWidget {
  const AdminPatientAdherencePage({super.key});

  @override
  State<AdminPatientAdherencePage> createState() =>
      _AdminPatientAdherencePageState();
}

class _AdminPatientAdherencePageState extends State<AdminPatientAdherencePage> {
  final TextEditingController _searchController = TextEditingController();
  AdherenceTier? _selectedTier;
  bool _isLoading = true;
  String? _errorMessage;
  final List<AdminPatientAdherenceRecord> _records = [];
  final AdminApiService _api = AdminApiService();

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
      final adherenceList = await _api.fetchPatientAdherence();
      debugPrint(
        'Admin adherence direct response count: ${adherenceList.length}',
      );

      if (!mounted) return;

      setState(() {
        _records
          ..clear()
          ..addAll(
            adherenceList.map((a) {
              final rawId = (a['id'] ?? a['patient_id'] ?? '').toString();
              final adherenceScore = safeInt(
                a['adherence_percent'] ??
                    a['adherencePercent'] ??
                    a['score'] ??
                    a['adherence_score'] ??
                    a['percentage'],
                0,
              );
              final apiStatus =
                  (a['status']?.toString() ??
                          a['adherence_status']?.toString() ??
                          'no_data')
                      .toLowerCase();

              final medications = safeList(a['medications']).map((m) {
                if (m is String) return MedicationInfo(name: m, dosage: '');
                final mm = safeMap(m) ?? {};
                debugPrint(
                  'RAW MED: keys=${mm.keys.toList()} values=${mm.values.toList()}',
                );
                final knownInitial = _safePositiveIntFromMap(mm, [
                  'total_prescribed_quantity',
                  'totalPrescribedQuantity',
                  'initial_quantity',
                  'initialQuantity',
                  'quantity',
                  'prescribed_quantity',
                  'prescribedQuantity',
                  'qty',
                  'stock',
                  'total_quantity',
                  'totalQuantity',
                  'amount',
                  'ordered_quantity',
                  'orderedQuantity',
                  'requested_quantity',
                  'requestedQuantity',
                ]);
                debugPrint('KNOWN initial=$knownInitial');
                final fallbackInitial = knownInitial == 0
                    ? _safePositiveIntFromAnyKey(mm)
                    : 0;
                debugPrint('FALLBACK initial=$fallbackInitial');
                final initial = knownInitial > 0
                    ? knownInitial
                    : fallbackInitial;
                final dispensed = _safeIntFromMap(mm, [
                  'total_dispensed_quantity',
                  'totalDispensedQuantity',
                  'disposed_quantity',
                  'disposedQuantity',
                  'dispensed_quantity',
                  'dispensedQuantity',
                  'quantity_dispensed',
                  'quantityDispensed',
                  'qty_dispensed',
                  'qtyDispensed',
                  'served',
                  'quantity_served',
                  'quantityServed',
                  'given',
                  'amount_given',
                  'amountGiven',
                ]);
                final remaining = _safeIntFromMap(mm, [
                  'remaining_quantity',
                  'remainingQuantity',
                  'remaining_qty',
                  'remainingQty',
                ]);
                final computedRemaining = initial > 0
                    ? (initial - dispensed).clamp(-999, initial)
                    : remaining;
                final fullyDispensed =
                    safeBool(mm['fully_dispensed'] ?? mm['fullyDispensed']) ||
                    (initial > 0 && computedRemaining <= 0 && dispensed > 0);
                final result = MedicationInfo(
                  name:
                      mm['name']?.toString() ??
                      mm['medicine_name']?.toString() ??
                      'Unknown',
                  dosage: mm['dosage']?.toString() ?? '',
                  initialQuantity: initial,
                  dispensedQuantity: dispensed,
                  remainingQuantity: computedRemaining,
                  fullyDispensed: fullyDispensed,
                );
                debugPrint(
                  'MED: name=${result.name} initial=${result.initialQuantity} dispensed=${result.dispensedQuantity} remaining=${result.remainingQuantity} keys=${mm.keys.toList()}',
                );
                return result;
              }).toList();

              final refillHistory = safeList(
                a['refill_history'] ??
                    a['refillHistory'] ??
                    a['dispensing_logs'] ??
                    a['dispensingLogs'],
              ).map((e) => RefillEvent.fromJson(safeMap(e) ?? {})).toList();

              final lastFill = a['last_fill'] != null || a['lastFill'] != null
                  ? DateTime.tryParse('${a['last_fill'] ?? a['lastFill']}') ??
                        DateTime.now()
                  : DateTime.now();

              return AdminPatientAdherenceRecord(
                patientId: (a['patient_id'] ?? a['id'] ?? '').toString(),
                id: rawId,
                name: (a['name'] ?? a['patient_name'] ?? 'Unknown').toString(),
                age: safeInt(a['age'] ?? a['patient_age']),
                sex: (a['sex'] ?? a['gender'] ?? '').toString(),
                lastFill: lastFill,
                medications: medications,
                adherenceScore: adherenceScore,
                adherenceStatus: apiStatus,
                prescriptionId: a['prescription_id']?.toString(),
                doctorName: a['doctor_name']?.toString(),
                refillHistory: refillHistory,
              );
            }).toList(),
          );
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to load adherence records: $e';
          _isLoading = false;
        });
      }
    }
  }

  List<AdminPatientAdherenceRecord> get _filtered {
    final query = _searchController.text.trim().toLowerCase();
    return _records.where((r) {
      final matchesSearch =
          query.isEmpty ||
          r.name.toLowerCase().contains(query) ||
          r.id.toLowerCase().contains(query);
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
                  ? Center(
                      child: Text(
                        'No prescriptions found',
                        style: TextStyle(color: Colors.grey.shade500),
                      ),
                    )
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

  Widget _buildPrescriptionCard(AdminPatientAdherenceRecord record) {
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
        final pid = record.patientId.isEmpty ? record.id : record.patientId;
        final alt = record.patientId.isNotEmpty && record.id != record.patientId
            ? record.id
            : null;
        debugPrint(
          'Admin adherence onTap: patientId=$pid, altPatientId=$alt, name=${record.name}',
        );
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AdminPatientAdherenceDetailPage(
              patientId: pid,
              altPatientId: alt,
              initialPatient: Map<String, dynamic>.from({
                'patient_id': record.patientId,
                'id': record.id,
                'name': record.name,
                'age': record.age,
                'sex': record.sex,
                'adherence_status': record.adherenceStatus,
                'adherence_score': record.adherenceScore,
                'has_history': true,
                'has_data': true,
                'medications': record.medications
                    .map((m) => m.toJson())
                    .toList(),
                'items': record.medications.map((m) => m.toJson()).toList(),
                'refill_history': record.refillHistory
                    .map((e) => e.toJson())
                    .toList(),
                'is_fully_dispensed':
                    record.tier == AdherenceTier.fullyDispensed,
                'is_locked': record.isLocked,
                'lock_reason': record.lockReason,
                'prescription_id': record.prescriptionId,
                'last_fill': record.lastFill.toIso8601String(),
                'ocr_code': record.id,
                'doctor_name': record.doctorName,
                'date_time': record.lastFill.toIso8601String(),
              }),
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
                          'Rx: ${record.id}',
                          style: TextStyle(
                            color: Colors.grey.shade500,
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (record.isLocked) ...[
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.lock,
                          size: 16,
                          color: AppColors.danger,
                        ),
                      ],
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
                      record.medications
                          .map((m) => m.name.isNotEmpty ? m.name : 'Unknown')
                          .join(', '),
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
                      AdherenceTier.critical =>
                        ((record.adherenceStatus ?? '').toLowerCase() ==
                                'no_data')
                            ? 'No Data'
                            : 'Pending',
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

  String _secondaryLine(AdminPatientAdherenceRecord r) {
    final parts = <String>[];
    final ageStr = r.age > 0 ? r.age.toString() : '';
    final sexStr = r.sex.trim();
    if (ageStr.isNotEmpty || sexStr.isNotEmpty) parts.add('$ageStr$sexStr');
    final isPending =
        (r.adherenceStatus ?? '').toLowerCase() == 'pending' ||
        (r.adherenceStatus ?? '').toLowerCase() == 'no_data';
    parts.add(
      isPending ? 'Not dispensed yet' : 'Last fill: ${_fmtDate(r.lastFill)}',
    );
    return parts.join(' · ');
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
