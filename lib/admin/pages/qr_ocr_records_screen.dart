import 'package:flutter/material.dart';
import '../../../admin/data/admin_api_service.dart';
import '../../../admin/models/admin_models.dart';
import '../../../common/theme/app_colors.dart';
import '../../../common/widgets/tap_target.dart';
import 'over_dispensing_screen.dart';

enum _Filter { all, qr, ocr }

enum _DateFilter { today, week, month, allTime }

class QrOcrRecordsScreen extends StatefulWidget {
  /// Preselect "flagged only" when navigating here from a source that
  /// already knows it wants the flagged view (e.g. the "OD Flags Logged"
  /// stat card on the Overview tab).
  final bool initialFlaggedOnly;

  const QrOcrRecordsScreen({super.key, this.initialFlaggedOnly = false});

  @override
  State<QrOcrRecordsScreen> createState() => _QrOcrRecordsScreenState();
}

class _QrOcrRecordsScreenState extends State<QrOcrRecordsScreen> {
  final AdminApiService _api = AdminApiService();
  final TextEditingController _searchController = TextEditingController();

  _Filter _filter = _Filter.all;
  _DateFilter _dateFilter = _DateFilter.allTime;
  bool _flaggedOnly = false;
  bool _loading = true;
  String? _error;
  ScanRecordsResponse? _records;

  @override
  void initState() {
    super.initState();
    _flaggedOnly = widget.initialFlaggedOnly;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final records = await _api.fetchScanRecords(
        type: _filter == _Filter.all
            ? 'all'
            : _filter == _Filter.qr
            ? 'qr'
            : 'ocr',
        date: _dateFilter.name,
        search: _searchController.text.trim(),
        flaggedOnly: _flaggedOnly,
      );
      if (!mounted) return;
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _retry() => _load();

  String _dateFilterLabel() {
    switch (_dateFilter) {
      case _DateFilter.today:
        return 'Today';
      case _DateFilter.week:
        return 'This Week';
      case _DateFilter.month:
        return 'This Month';
      case _DateFilter.allTime:
        return 'All Time';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('QR & OCR Records'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Home pharmacy scans only',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _searchController,
              onChanged: (_) => _load(),
              decoration: InputDecoration(
                hintText: 'Search patient, RX number, staff...',
                hintStyle: const TextStyle(
                  color: AppColors.textFaint,
                  fontSize: 13,
                ),
                prefixIcon: const Icon(
                  Icons.search,
                  color: AppColors.textFaint,
                  size: 20,
                ),
                filled: true,
                fillColor: AppColors.surface,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                _FilterPill(
                  label: 'All',
                  selected: _filter == _Filter.all,
                  onTap: () {
                    setState(() => _filter = _Filter.all);
                    _load();
                  },
                ),
                const SizedBox(width: 8),
                _FilterPill(
                  label: 'QR Scans',
                  selected: _filter == _Filter.qr,
                  onTap: () {
                    setState(() => _filter = _Filter.qr);
                    _load();
                  },
                ),
                const SizedBox(width: 8),
                _FilterPill(
                  label: 'OCR Scans',
                  selected: _filter == _Filter.ocr,
                  onTap: () {
                    setState(() => _filter = _Filter.ocr);
                    _load();
                  },
                ),
                const Spacer(),
                _DateDropdown(
                  label: _dateFilterLabel(),
                  onTap: _showDateFilter,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                if (_records != null) ...[
                  _LegendDot(
                    color: AppColors.teal,
                    label: '${_records!.qrCount} QR scans',
                  ),
                  const SizedBox(width: 14),
                  _LegendDot(
                    color: AppColors.warning,
                    label: '${_records!.ocrCount} OCR saves',
                  ),
                ],
                const Spacer(),
                if (_records != null)
                  _FlaggedToggle(
                    flaggedOnly: _flaggedOnly,
                    onChanged: (v) {
                      setState(() => _flaggedOnly = v);
                      _load();
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.teal),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: AppColors.danger),
              const SizedBox(height: 16),
              const Text(
                "Couldn't reach the backend",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                _error ?? '',
                style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _retry,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.teal,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_records == null || _records!.records.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No scan records found.',
            style: TextStyle(fontSize: 14, color: AppColors.textFaint),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: AppColors.teal,
      child: Container(
        color: AppColors.bg,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'RECENT SCANS',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textFaint,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            ..._records!.records.map((r) => _RecordTile(record: r)),
          ],
        ),
      ),
    );
  }

  void _showDateFilter() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        final options = [
          _DateFilter.today,
          _DateFilter.week,
          _DateFilter.month,
          _DateFilter.allTime,
        ];
        final labels = ['Today', 'This Week', 'This Month', 'All Time'];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(options.length, (i) {
              final selected = _dateFilter == options[i];
              return ListTile(
                title: Text(
                  labels[i],
                  style: TextStyle(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    color: selected ? AppColors.teal : AppColors.textPrimary,
                  ),
                ),
                trailing: selected
                    ? const Icon(Icons.check, color: AppColors.teal)
                    : null,
                onTap: () {
                  setState(() => _dateFilter = options[i]);
                  Navigator.pop(context);
                  _load();
                },
              );
            }),
          ),
        );
      },
    );
  }
}

class _FilterPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: onTap,
      semanticLabel: label,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.teal : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.teal : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _DateDropdown extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _DateDropdown({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: onTap,
      semanticLabel: label,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.keyboard_arrow_down,
              size: 16,
              color: AppColors.textFaint,
            ),
          ],
        ),
      ),
    );
  }
}

class _FlaggedToggle extends StatelessWidget {
  final bool flaggedOnly;
  final ValueChanged<bool> onChanged;
  const _FlaggedToggle({required this.flaggedOnly, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: () => onChanged(!flaggedOnly),
      semanticLabel: flaggedOnly ? 'Flagged Only' : 'Show Flagged',
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: flaggedOnly ? AppColors.redLight : AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: flaggedOnly ? AppColors.danger : AppColors.border,
          ),
        ),
        child: Text(
          flaggedOnly ? 'Flagged Only' : 'Show Flagged',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: flaggedOnly ? AppColors.danger : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _RecordTile extends StatelessWidget {
  final ScanRecordEntry record;
  const _RecordTile({required this.record});

  @override
  Widget build(BuildContext context) {
    final isBlocked = record.status == ScanRecordStatus.blocked;
    final isOcr = record.type == ScanRecordType.ocr;

    Color statusDotColor = AppColors.warning;
    switch (record.status) {
      case ScanRecordStatus.dispensed:
        statusDotColor = AppColors.success;
        break;
      case ScanRecordStatus.blocked:
        statusDotColor = AppColors.danger;
        break;
      case ScanRecordStatus.saved:
        statusDotColor = AppColors.warning;
        break;
      default:
        statusDotColor = AppColors.warning;
        break;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: isBlocked && record.refNumber.isNotEmpty
          ? () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      OverDispensingScreen(prescriptionId: record.refNumber),
                ),
              );
            }
          : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: isOcr ? AppColors.amberLight : AppColors.tealPale,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isOcr ? 'OCR' : 'QR',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: isOcr ? AppColors.warning : AppColors.teal,
                    ),
                  ),
                ),
                if (record.isFlagged) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.redLight,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'FLAGGED',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                Text(
                  record.time,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textFaint,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              record.refNumber,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: statusDotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    record.description,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isBlocked ? FontWeight.w700 : FontWeight.w400,
                      color: isBlocked ? AppColors.danger : AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Staff: ${record.staff}',
              style: const TextStyle(fontSize: 11, color: AppColors.textFaint),
            ),
          ],
        ),
      ),
    );
  }
}
