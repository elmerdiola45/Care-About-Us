// saved_prescriptions_list_screen.dart
//
// Shows all saved (confirmed) OCR prescriptions. Each entry has a
// "Generate QR Code" / "View QR" action that expands an inline QR panel
// specific to that saved prescription, with a Print option.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:pharmacy_management_system/pharmacist/models/prescription.dart';
import 'package:pharmacy_management_system/pharmacist/data/saved_prescriptions_store.dart';
import 'package:pharmacy_management_system/pharmacist/models/adherence.dart';
import 'package:pharmacy_management_system/pharmacist/widgets/adherence_badge.dart';
import 'package:pharmacy_management_system/common/theme/app_colors.dart';
import 'package:pharmacy_management_system/common/services/laravel_api_service.dart';
import 'package:pharmacy_management_system/common/session.dart';
import 'package:pharmacy_management_system/pharmacist/pages/dispense_screen.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'prescription_detail_screen.dart';

class SavedListColors {
  static const teal = Color(0xFF0B7B77);
  static const green = Color(0xFF2E9C6B);
  static const greenBg = Color(0xFFDCF3E8);
  static const red = Color(0xFFDC2626);
  static const redBg = Color(0xFFFEE2E2);
  static const bg = Color(0xFFF3F4F6);
  static const card = Colors.white;
  static const textPrimary = Color(0xFF1F2937);
  static const textSecondary = Color(0xFF6B7280);
  static const textFaint = Color(0xFF9CA3AF);
  static const border = Color(0xFFE5E7EB);
  static const warning = Color(0xFFD97706);
}

enum _Filter {
  all,
  pendingQr,
  qrGenerated,
  fullyDispensed,
  overdispensing,
  partiallyDispensed,
}

class SavedPrescriptionsListScreen extends StatefulWidget {
  const SavedPrescriptionsListScreen({super.key});

  @override
  State<SavedPrescriptionsListScreen> createState() =>
      _SavedPrescriptionsListScreenState();
}

class _SavedPrescriptionsListScreenState
    extends State<SavedPrescriptionsListScreen> {
  String? _expandedOcrCode;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  _Filter _filter = _Filter.all;
  bool _isLoading = true;
  String? _errorMessage;
  final LaravelApiService _api = LaravelApiService(
    token: AppSession.instance.token,
  );
  Timer? _weeklyRefreshTimer;

  @override
  void initState() {
    super.initState();
    _fetchFromBackend();
    _startWeeklyRefresh();
  }

  void _startWeeklyRefresh() {
    _weeklyRefreshTimer = Timer.periodic(const Duration(days: 7), (_) {
      if (mounted) _fetchFromBackend();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _weeklyRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchFromBackend() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await SavedPrescriptionsStore.instance.fetchFromBackend();
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage =
              'Cannot reach backend server. Check if the backend is running and accessible.';
        });
      }
    } on LaravelApiException catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Backend error: ${e.message}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load prescriptions from server.';
        });
      }
    }
  }

  List<PrescriptionEntry> get _visibleItems {
    var list = SavedPrescriptionsStore.instance.items;
    if (_filter == _Filter.pendingQr) {
      list = list
          .where((e) => e.prescription.status == QrStatus.pendingQr)
          .toList();
    } else if (_filter == _Filter.qrGenerated) {
      list = list
          .where((e) => e.prescription.status == QrStatus.qrGenerated)
          .toList();
    } else if (_filter == _Filter.fullyDispensed) {
      list = list.where((e) {
        final actual =
            e.prescription.dispensingStatus == DispensingStatus.pending
            ? SavedPrescriptionsStore.computeDispensingStatus(
                e.prescription.medicines,
              )
            : e.prescription.dispensingStatus;
        return actual == DispensingStatus.fullyDispensed;
      }).toList();
    } else if (_filter == _Filter.overdispensing) {
      list = list.where((e) {
        final actual =
            e.prescription.dispensingStatus == DispensingStatus.pending
            ? SavedPrescriptionsStore.computeDispensingStatus(
                e.prescription.medicines,
              )
            : e.prescription.dispensingStatus;
        return actual == DispensingStatus.overDispensing;
      }).toList();
    } else if (_filter == _Filter.partiallyDispensed) {
      list = list.where((e) {
        final actual =
            e.prescription.dispensingStatus == DispensingStatus.pending
            ? SavedPrescriptionsStore.computeDispensingStatus(
                e.prescription.medicines,
              )
            : e.prescription.dispensingStatus;
        return actual == DispensingStatus.partiallyDispensed;
      }).toList();
    }
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((e) {
        final p = e.prescription;
        return p.patientName.toLowerCase().contains(q) ||
            p.ocrCode.toLowerCase().contains(q) ||
            p.doctorName.toLowerCase().contains(q);
      }).toList();
    }
    return list;
  }

  String _formatDateTime(DateTime dt) {
    final d = dt.toLocal();
    final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final minute = d.minute.toString().padLeft(2, '0');
    final ampm = d.hour < 12 ? 'AM' : 'PM';
    return '${d.month}/${d.day}/${d.year} · $hour:$minute $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final items = _visibleItems;
    final canPop = Navigator.of(context).canPop();

    return Scaffold(
      backgroundColor: SavedListColors.bg,
      appBar: AppBar(
        backgroundColor: SavedListColors.bg,
        elevation: 0,
        automaticallyImplyLeading: canPop,
        iconTheme: const IconThemeData(color: SavedListColors.textPrimary),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'Saved Prescriptions',
              style: TextStyle(
                color: SavedListColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: 2),
            Text(
              "Tap 'Generate QR' to create a scannable code",
              style: TextStyle(
                color: SavedListColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _buildSearchBar(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: _buildFilterChips(),
          ),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: SavedListColors.teal,
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
                            size: 48,
                            color: Colors.red,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Failed to load records',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _errorMessage!,
                            style: const TextStyle(
                              color: SavedListColors.textSecondary,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: _fetchFromBackend,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Retry'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: SavedListColors.teal,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : items.isEmpty
                ? _buildEmptyState()
                : RefreshIndicator(
                    onRefresh: _fetchFromBackend,
                    color: SavedListColors.teal,
                    child: Container(
                      color: SavedListColors.bg,
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, index) =>
                            _buildEntryCard(items[index]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      decoration: BoxDecoration(
        color: SavedListColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SavedListColors.border),
      ),
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _searchQuery = v),
        style: const TextStyle(
          fontSize: 14,
          color: SavedListColors.textPrimary,
        ),
        decoration: InputDecoration(
          hintText: 'Search patient, code, or doctor',
          hintStyle: const TextStyle(
            color: SavedListColors.textSecondary,
            fontSize: 13.5,
          ),
          prefixIcon: const Icon(
            Icons.search,
            color: SavedListColors.textSecondary,
            size: 20,
          ),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(
                    Icons.clear,
                    color: SavedListColors.textSecondary,
                    size: 18,
                  ),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _chip('All', _Filter.all, Icons.all_inclusive_outlined),
          const SizedBox(width: 8),
          _chip(
            'Pending QR',
            _Filter.pendingQr,
            Icons.hourglass_empty_outlined,
          ),
          const SizedBox(width: 8),
          _chip(
            'QR Ready',
            _Filter.qrGenerated,
            Icons.qr_code_scanner_outlined,
          ),
          const SizedBox(width: 8),
          _chip(
            'Fully Dispensed',
            _Filter.fullyDispensed,
            Icons.check_circle_outline,
          ),
          const SizedBox(width: 8),
          _chip(
            'Overdispensing',
            _Filter.overdispensing,
            Icons.warning_amber_outlined,
          ),
          const SizedBox(width: 8),
          _chip(
            'Partial',
            _Filter.partiallyDispensed,
            Icons.warning_amber_outlined,
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, _Filter value, IconData icon) {
    final selected = _filter == value;
    final isAlert =
        value == _Filter.overdispensing || value == _Filter.partiallyDispensed;
    final isSuccess = value == _Filter.fullyDispensed;

    return ChoiceChip(
      avatar: CircleAvatar(
        backgroundColor: selected
            ? (isAlert
                  ? SavedListColors.red.withValues(alpha: 0.2)
                  : isSuccess
                  ? SavedListColors.green.withValues(alpha: 0.2)
                  : AppColors.teal.withValues(alpha: 0.2))
            : AppColors.textFaint.withValues(alpha: 0.15),
        foregroundColor: selected
            ? (isAlert
                  ? SavedListColors.red
                  : isSuccess
                  ? SavedListColors.green
                  : Colors.white)
            : AppColors.textFaint,
        child: Icon(icon, size: 16),
      ),
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _filter = value),
      selectedColor: isAlert
          ? SavedListColors.redBg
          : isSuccess
          ? SavedListColors.greenBg
          : AppColors.teal,
      labelStyle: TextStyle(
        color: selected
            ? (isAlert
                  ? SavedListColors.red
                  : isSuccess
                  ? SavedListColors.textPrimary
                  : Colors.white)
            : SavedListColors.textSecondary,
        fontWeight: FontWeight.w700,
        fontSize: 12.5,
      ),
      backgroundColor: SavedListColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
        side: BorderSide(
          color: selected
              ? (isAlert
                    ? SavedListColors.red
                    : isSuccess
                    ? SavedListColors.green
                    : AppColors.teal)
              : SavedListColors.border,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    );
  }

  Widget _buildEmptyState() {
    final hasAnyItems = SavedPrescriptionsStore.instance.items.isNotEmpty;

    final String title;
    final String subtitle;

    if (!hasAnyItems) {
      // The store itself is empty — nothing has ever been scanned/saved.
      title = 'No saved prescriptions yet';
      subtitle = 'Confirm an OCR-scanned prescription to see it here.';
    } else if (_searchQuery.isNotEmpty) {
      // Data exists and the status filter may well have matches — it's
      // the search text that's zeroing out the results here.
      title = 'No matching prescriptions';
      subtitle =
          'No results for "$_searchQuery". Try a different name, code, or doctor.';
    } else {
      // The store has entries, but none match the active status filter —
      // make that distinction clear instead of implying data is missing.
      switch (_filter) {
        case _Filter.pendingQr:
          title = 'No prescriptions pending a QR';
          subtitle =
              'Every saved prescription already has a QR code generated.';
          break;
        case _Filter.qrGenerated:
          title = 'No QR-ready prescriptions';
          subtitle =
              'Prescriptions will appear here once a QR code has been generated.';
          break;
        case _Filter.fullyDispensed:
          title = 'No fully dispensed prescriptions';
          subtitle =
              'Prescriptions will appear here once all medicines are dispensed.';
          break;
        case _Filter.overdispensing:
          title = 'No overdispensing flags';
          subtitle =
              'Prescriptions will appear here if a fill exceeds what was prescribed.';
          break;
        case _Filter.partiallyDispensed:
          title = 'No partially dispensed prescriptions';
          subtitle =
              'Prescriptions will appear here once some, but not all, medicines are dispensed.';
          break;
        case _Filter.all:
          // Shouldn't be reachable when hasAnyItems is true and search is
          // empty, but a search query can still zero out "All" results.
          title = 'No matching prescriptions';
          subtitle = 'Try a different search term or filter.';
          break;
      }
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.receipt_long_outlined,
              size: 48,
              color: SavedListColors.textSecondary,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(color: SavedListColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntryCard(PrescriptionEntry entry) {
    final p = entry.prescription;
    final isPending = p.status == QrStatus.pendingQr;
    final isExpanded = _expandedOcrCode == p.ocrCode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: SavedListColors.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: SavedListColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: _buildImageThumbnail(entry.imageBytes, 52, entry.imageUrl),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${p.patientName} (${p.patientGender}) · ${p.patientAge}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${p.medicines.length} medicine(s) · ₱${p.totalPrice.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: SavedListColors.textSecondary,
                            fontSize: 12.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _statusPill(isPending: isPending),
                              const SizedBox(width: 8),
                              _dispensingStatusPill(p.dispensingStatus),
                              const SizedBox(width: 8),
                              Builder(
                                builder: (_) {
                                  final tier =
                                      entry.adherence?.tier ??
                                      (p.dispensingStatus ==
                                              DispensingStatus.fullyDispensed
                                          ? AdherenceTier.fullyDispensed
                                          : p.dispensingStatus ==
                                                DispensingStatus.overDispensing
                                          ? AdherenceTier.overDispensing
                                          : AdherenceTier.good);
                                  return Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      AdherenceBadge(
                                        tier: tier,
                                        compact: false,
                                      ),
                                      if (tier ==
                                          AdherenceTier.fullyDispensed) ...[
                                        const SizedBox(width: 6),
                                        Text(
                                          '100%',
                                          style: TextStyle(
                                            color: const Color(0xFF6B7280),
                                            fontWeight: FontWeight.w700,
                                            fontSize: 12.5,
                                          ),
                                        ),
                                      ],
                                    ],
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => _onDeletePressed(entry),
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.red,
                      size: 20,
                    ),
                    tooltip: 'Remove from list (backend preserved)',
                  ),
                  IconButton(
                    onPressed: () => _onViewDetails(entry),
                    icon: const Icon(
                      Icons.visibility_outlined,
                      color: SavedListColors.teal,
                      size: 20,
                    ),
                    tooltip: 'View details',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _infoLine('${p.doctorName}  ·  ${p.ocrCode}'),
              const SizedBox(height: 4),
              _infoLine(_formatDateTime(p.dateTime)),
              if (p.medicines.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Divider(height: 1),
                const SizedBox(height: 8),
                for (final m in p.medicines) ...[
                  _medicineLine(
                    '${m.name} ${m.dosage}',
                    '× ${m.quantity}${m.disposedQuantity > 0 ? " (dispensed: ${m.disposedQuantity})" : ""}',
                    isEssential: m.isEssential,
                    duration: m.duration,
                  ),
                ],
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _onActionPressed(entry),
                        icon: const Icon(Icons.qr_code_2, size: 18),
                        label: Text(isPending ? 'Generate QR' : 'View QR'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: SavedListColors.teal,
                          side: BorderSide(
                            color: SavedListColors.teal.withValues(alpha: 0.9),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (p.dispensingStatus != DispensingStatus.fullyDispensed &&
                        p.dispensingStatus != DispensingStatus.overDispensing)
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => _onDispensePressed(entry),
                          icon: const Icon(
                            Icons.local_pharmacy_rounded,
                            size: 18,
                          ),
                          label: const Text('Dispense'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.teal,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (isExpanded) ...[
          const SizedBox(height: 6),
          _buildInlineQrPanel(entry: entry),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  Widget _infoLine(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: SavedListColors.textSecondary,
        fontSize: 12,
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _medicineLine(
    String name,
    String qty, {
    bool isEssential = true,
    String duration = '',
  }) {
    final typeColor = isEssential
        ? SavedListColors.teal
        : SavedListColors.warning;
    final typeLabel = isEssential ? 'Essential' : 'Optional';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
          const SizedBox(width: 6),
          Text(
            qty,
            style: const TextStyle(
              fontSize: 12.5,
              color: SavedListColors.textSecondary,
            ),
          ),
          if (duration.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              '· $duration',
              style: const TextStyle(
                fontSize: 11,
                color: SavedListColors.textFaint,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _inlineQrPayload(PrescriptionEntry entry) {
    // Gate on backendVerifyUrl, not entry.qrToken (token_id) — the
    // backend only ever verifies the real secret via its hash, so a URL
    // built from token_id alone is now rejected outright rather than
    // just being weaker. backendVerifyUrl is only ever populated with a
    // real, working verify URL (see updateQrToken() / saved_prescriptions_
    // store.dart); when it's absent, fall back to showing the local
    // payload rather than encoding a QR that can never verify.
    final verifyUrl = entry.backendVerifyUrl;
    if (verifyUrl == null || verifyUrl.isEmpty) {
      return jsonEncode({
        'rxNumber': entry.ocrCode,
        'patientName': entry.prescription.patientName,
        'patientAge': entry.prescription.patientAge,
        'patientSex': entry.prescription.patientGender,
        'doctor': entry.prescription.doctorName,
        'date': entry.prescription.dateTime.toIso8601String(),
        'medicines': entry.prescription.medicines
            .map(
              (m) => {
                'name': m.name,
                'strength': m.dosage,
                'prescribedQuantity': m.quantity,
                'stock': m.quantity * 3,
                'unitPrice': 12.50,
              },
            )
            .toList(),
      });
    }

    return verifyUrl;
  }

  Widget _buildInlineQrPanel({required PrescriptionEntry entry}) {
    final qrData = _inlineQrPayload(entry);
    final p = entry.prescription;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SavedListColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SavedListColors.border),
      ),
      child: Column(
        children: [
          Center(
            child: QrImageView(
              data: qrData,
              version: QrVersions.auto,
              size: 180,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'QR code for ${p.ocrCode}',
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 14.5,
              color: Color(0xFF1F2937),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Patient: ${p.patientName}',
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13.5,
              color: Color(0xFF6B7280),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: SavedListColors.greenBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: SavedListColors.green.withValues(alpha: .35),
              ),
            ),
            child: const Text(
              'Ready to scan at any branch.',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 13.5,
                color: Color(0xFF2E9C6B),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    setState(() => _expandedOcrCode = null);
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: SavedListColors.teal,
                    side: BorderSide(
                      color: SavedListColors.teal.withValues(alpha: 0.95),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text(
                    'OK',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () async {
                    await _printQrForThermal(prescription: p, qrData: qrData);
                  },
                  icon: const Icon(Icons.print_rounded, size: 16),
                  label: const Text(
                    ' Print',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SavedListColors.teal,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusPill({required bool isPending}) {
    final bg = isPending ? const Color(0xFFFDF0D8) : const Color(0xFFDCF3E8);
    final fg = isPending ? const Color(0xFFC98A2E) : const Color(0xFF2E9C6B);
    final label = isPending ? 'Pending QR' : 'QR Generated';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }

  Widget _dispensingStatusPill(DispensingStatus status) {
    String label;
    Color bg;
    Color fg;

    switch (status) {
      case DispensingStatus.fullyDispensed:
        label = 'Fully Dispensed';
        bg = const Color(0xFFDCF3E8);
        fg = const Color(0xFF2E9C6B);
        break;
      case DispensingStatus.partiallyDispensed:
        label = 'Partially Dispensed';
        bg = const Color(0xFFFFF7E6);
        fg = const Color(0xFFD97706);
        break;
      case DispensingStatus.overDispensing:
        label = 'Overdispensing';
        bg = const Color(0xFFFEE2E2);
        fg = const Color(0xFFDC2626);
        break;
      default:
        label = 'Pending Dispensing';
        bg = const Color(0xFFF3F4F6);
        fg = const Color(0xFF6B7280);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }

  Future<void> _onViewDetails(PrescriptionEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PrescriptionDetailScreen(entry: entry)),
    );
  }

  Future<void> _onDeletePressed(PrescriptionEntry entry) async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete this prescription?'),
            content: const Text(
              'This permanently removes it from Saved Rx, the Dispense list, and Patient Adherence. Its dispensing history is kept for records. This cannot be undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text(
                  'Delete',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed) return;

    try {
      await SavedPrescriptionsStore.instance.deleteEverywhere(entry);
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to delete: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _onActionPressed(PrescriptionEntry entry) async {
    final shouldExpand = _expandedOcrCode != entry.ocrCode;

    if (entry.prescription.status == QrStatus.pendingQr) {
      await _generateBackendQrToken(entry);
    }

    if (!mounted) return;

    setState(() {
      _expandedOcrCode = shouldExpand ? entry.ocrCode : null;
    });
  }

  Future<void> _onDispensePressed(PrescriptionEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DispenseScreen(initialOcrCode: entry.ocrCode),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _generateBackendQrToken(PrescriptionEntry entry) async {
    try {
      // QrTokenController@generate only flips the prescription's status to
      // 'qr_generated' when it receives a prescription_id. If this entry
      // hasn't been synced to the backend yet (backendId still null), the
      // token still gets created but is never linked to the prescription —
      // so the status silently stays 'pending' server-side. The UI looks
      // fine right after generating (optimistic local update via
      // updateQrToken below), but reverts to "Generate QR" on the next
      // refresh once fetchFromBackend() pulls the real, still-pending
      // status. Make sure a backendId exists first.
      if (entry.backendId == null || entry.backendId!.isEmpty) {
        await SavedPrescriptionsStore.instance.syncEntryToBackend(entry);
        final syncedId = SavedPrescriptionsStore.instance.backendIdFor(
          entry.ocrCode,
        );
        if (syncedId != null) {
          entry = entry.copyWith(backendId: syncedId);
        }
      }

      final medicinesPayload = entry.prescription.medicines
          .map(
            (m) => {
              'name': m.name,
              'dosage': m.dosage,
              'quantity': m.quantity,
              'is_essential': m.isEssential,
              'duration': m.duration,
            },
          )
          .toList();

      final response = await _api.generateQrToken(
        ocrCode: entry.ocrCode,
        patientName: entry.prescription.patientName,
        patientAge: entry.prescription.patientAge,
        patientGender: entry.prescription.patientGender,
        doctorName: entry.prescription.doctorName,
        licenseNo: entry.prescription.licenseNo,
        ptNo: entry.prescription.ptNo,
        s2: entry.prescription.s2,
        patientAddress: entry.prescription.patientAddress,
        dateTime: entry.prescription.dateTime,
        medicines: medicinesPayload,
        totalPrice: entry.prescription.totalPrice,
        rawExtractedText: entry.rawExtractedText,
        prescriptionId: entry.backendId,
      );

      final token = response.token;
      final verifyUrl = response.verifyUrl;

      SavedPrescriptionsStore.instance.updateQrToken(
        entry.ocrCode,
        token,
        verifyUrl,
      );

      // The backend already links prescription <-> qr_token on generate,
      // so a separate status sync is no longer needed.

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('QR token generated via backend'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } on LaravelApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Backend QR failed: ${e.message}. Using local QR.'),
          ),
        );
      }
      SavedPrescriptionsStore.instance.updateStatus(
        entry.ocrCode,
        QrStatus.qrGenerated,
      );
    } catch (_) {
      SavedPrescriptionsStore.instance.updateStatus(
        entry.ocrCode,
        QrStatus.qrGenerated,
      );
    }
  }

  Future<void> _printQrForThermal({
    required Prescription prescription,
    required String qrData,
  }) async {
    const thermalWidth = 164.0;
    const thermalHeight = 200.0;
    final thermalFormat = PdfPageFormat(thermalWidth, thermalHeight);

    await Printing.layoutPdf(
      name: 'QR Thermal',
      format: thermalFormat,
      onLayout: (format) async {
        final doc = pw.Document();

        doc.addPage(
          pw.Page(
            pageFormat: thermalFormat,
            margin: const pw.EdgeInsets.all(4),
            build: (pw.Context ctx) {
              return pw.Center(
                child: pw.BarcodeWidget(
                  barcode: pw.Barcode.qrCode(),
                  data: qrData,
                  width: 150,
                  height: 150,
                  drawText: false,
                ),
              );
            },
          ),
        );

        return doc.save();
      },
    );
  }

  Widget _buildImageThumbnail(Uint8List bytes, double size, [String? imageUrl]) {
    if (bytes.isEmpty) {
      if (imageUrl != null && imageUrl.isNotEmpty) {
        return Image.network(
          imageUrl,
          headers: {'Authorization': 'Bearer ${AppSession.instance.token}'},
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => Icon(
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
