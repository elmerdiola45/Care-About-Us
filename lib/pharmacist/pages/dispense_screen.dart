import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/prescription.dart';
import '../data/saved_prescriptions_store.dart';
import '../../common/services/laravel_api_service.dart';
import '../../common/session.dart';
import '../../common/theme/app_colors.dart';
import '../../common/theme/responsive_context.dart';
import '../../common/widgets/tap_target.dart';
import '../../common/widgets/authenticated_network_image.dart';
import 'dispensing_summary_screen.dart';
import 'saved_prescriptions_list_screen.dart';

class DispenseScreen extends StatefulWidget {
  final String? initialOcrCode;

  const DispenseScreen({super.key, this.initialOcrCode});

  @override
  State<DispenseScreen> createState() => _DispenseScreenState();
}

class _DispenseScreenState extends State<DispenseScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String? _selectedOcrCode;
  bool _isDispensing = false;
  bool _isLoading = true;

  // Track dispensed quantities per medicine for current fill
  final Map<String, int> _dispensedQuantities = {};

  // Text controllers backing the typed-quantity field per medicine name, and
  // any inline validation error to show under that field. Keyed by name
  // (not persisted across a different selected prescription — see
  // _resetDispensedQuantities).
  final Map<String, TextEditingController> _qtyControllers = {};
  final Map<String, String?> _quantityErrors = {};

  void _resetDispensedQuantities() {
    for (final c in _qtyControllers.values) {
      c.dispose();
    }
    _qtyControllers.clear();
    _quantityErrors.clear();
    _dispensedQuantities.clear();
  }

  TextEditingController _qtyControllerFor(String name, int value) {
    final existing = _qtyControllers[name];
    if (existing != null) return existing;
    final controller = TextEditingController(text: '$value');
    _qtyControllers[name] = controller;
    return controller;
  }

  // Backend dispensing logs
  final List<DispensingLog> _backendLogs = [];
  bool _historyLoading = false;

  /// How many distinct dispensing visits ("fills") this prescription has
  /// already had, based on server history. A visit can cover several
  /// medicines, and each medicine gets its own dispensing_logs row, so we
  /// group by batch_id (shared by every row written in the same visit)
  /// rather than counting rows. Rows written before batch_id existed have no
  /// batch_id — each of those is counted as its own fill, which is the best
  /// we can do for that legacy data.
  int get _priorFillCount {
    final batchIds = <String>{};
    var legacyRowsWithoutBatch = 0;
    for (final log in _backendLogs) {
      if (log.batchId != null && log.batchId!.isNotEmpty) {
        batchIds.add(log.batchId!);
      } else {
        legacyRowsWithoutBatch += 1;
      }
    }
    return batchIds.length + legacyRowsWithoutBatch;
  }

  /// Estimates how many fills this prescription will take in total, given
  /// the size of the fill happening right now. Fill sizes aren't fixed, so
  /// this is a projection based on the current pace — e.g. a 21-unit
  /// prescription filled 6 now (fill 1) projects to 4 fills total; if the
  /// next fill serves 12, it reprojects to 3 total. It intentionally is not
  /// "prescribed quantity ÷ a fixed fill size", since that only works when
  /// every fill is the same size.
  int _estimateTotalFills({
    required int fillNumber,
    required List<MedicineItem> prescriptionMedicines,
    required Map<String, int> previousDisposed,
  }) {
    var total = fillNumber;
    for (final m in prescriptionMedicines) {
      final servedThisFill = _dispensedQuantities[m.name] ?? 0;
      if (servedThisFill <= 0) continue;

      final previousCumulative = previousDisposed[m.name] ?? 0;
      final newCumulative = previousCumulative + servedThisFill;
      final remainingAfterThisFill = m.quantity - newCumulative;
      if (remainingAfterThisFill <= 0) continue;

      final additionalFillsNeeded = (remainingAfterThisFill / servedThisFill)
          .ceil();
      final projectedTotalForThisMed = fillNumber + additionalFillsNeeded;
      if (projectedTotalForThisMed > total) total = projectedTotalForThisMed;
    }
    return total;
  }

  final LaravelApiService _api = LaravelApiService(
    token: AppSession.instance.token,
  );

  List<PrescriptionEntry> get _filteredEntries {
    final store = SavedPrescriptionsStore.instance;
    var list = store.items;

    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((e) {
        final p = e.prescription;
        return p.patientName.toLowerCase().contains(q) ||
            p.ocrCode.toLowerCase().contains(q) ||
            p.doctorName.toLowerCase().contains(q);
      }).toList();
    }

    list = list.where((e) {
      final status = e.prescription.dispensingStatus;
      return status != DispensingStatus.fullyDispensed &&
          status != DispensingStatus.overDispensing;
    }).toList();

    return list;
  }

  PrescriptionEntry? get _selectedEntry {
    if (_selectedOcrCode == null) return null;
    try {
      return SavedPrescriptionsStore.instance.items.firstWhere(
        (e) => e.ocrCode == _selectedOcrCode || e.backendId == _selectedOcrCode,
      );
    } on StateError {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialOcrCode != null) {
      _selectedOcrCode = widget.initialOcrCode;
      PrescriptionEntry? found;
      try {
        found = SavedPrescriptionsStore.instance.items.firstWhere(
          (e) =>
              e.ocrCode == widget.initialOcrCode ||
              e.backendId == widget.initialOcrCode,
        );
      } on StateError {
        found = null;
      }
      if (found != null) {
        _selectedOcrCode = found.ocrCode;
        _resetDispensedQuantities();
      }
    }
    _fetchPrescriptions();
  }

  Future<void> _fetchPrescriptions({bool force = false}) async {
    try {
      // The manual refresh button always passes force: true to bypass the
      // store's freshness TTL. The automatic call from initState() respects
      // the TTL instead — this screen is pushed as a brand-new route on
      // every QR scan, so forcing here was making every scan-dispense-scan
      // cycle re-run a full pharmacy-wide sync (including adherence for
      // every patient) even when the store was already fresh.
      await SavedPrescriptionsStore.instance.fetchFromBackend(force: force);
      if (_selectedOcrCode != null) {
        PrescriptionEntry? entry;
        try {
          entry = SavedPrescriptionsStore.instance.items.firstWhere(
            (e) => e.ocrCode == _selectedOcrCode,
          );
        } on StateError {
          entry = null;
        }
        if (entry != null) {
          _resetDispensedQuantities();
        }
      }
    } on TimeoutException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Cannot reach backend server. Check if the backend is running and accessible.',
            ),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } on LaravelApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Backend error: ${e.message}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to load prescriptions from server'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) {
        if (widget.initialOcrCode != null) {
          PrescriptionEntry? entry;
          try {
            entry = SavedPrescriptionsStore.instance.items.firstWhere(
              (e) =>
                  e.ocrCode == widget.initialOcrCode ||
                  e.backendId == widget.initialOcrCode,
            );
          } on StateError {
            entry = null;
          }
          if (entry != null) {
            _selectedOcrCode = entry.ocrCode;
            _resetDispensedQuantities();
            _backendLogs.clear();
            _historyLoading = true;
            _loadBackendHistory(entry);
          }
        }
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    for (final c in _qtyControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onSelectEntry(PrescriptionEntry entry) {
    setState(() {
      _selectedOcrCode = entry.ocrCode;
      _resetDispensedQuantities();
      _backendLogs.clear();
      _historyLoading = true;
    });
    _loadBackendHistory(entry);
  }

  Future<void> _loadBackendHistory(PrescriptionEntry entry) async {
    if (entry.backendId == null || entry.backendId!.isEmpty) {
      if (mounted) {
        setState(() => _historyLoading = false);
      }
      return;
    }
    try {
      final logs = await _api.fetchDispensingLogs(entry.backendId!);
      if (mounted) {
        setState(() {
          _backendLogs.clear();
          _backendLogs.addAll(logs);
          _historyLoading = false;
        });
      }
    } on LaravelApiException catch (_) {
      // Ignore backend history fetch errors — local history will still show
      if (mounted) {
        setState(() => _historyLoading = false);
      }
    } catch (_) {
      // Ignore other errors
      if (mounted) {
        setState(() => _historyLoading = false);
      }
    }
  }

  /// How much of [m] can actually be handed over right now: capped both
  /// by what's still owed on the prescription (quantity - disposedQuantity)
  /// AND by this pharmacy's real remaining stock, when that's tracked.
  /// `availableStock == null` means "not tracked in inventory" — same
  /// convention as the backend (see LaravelPrescriptionItem.availableStock)
  /// — so it doesn't constrain anything, preserving today's behavior for
  /// medicines this pharmacy has never recorded stock for.
  int _dispensableCap(MedicineItem m) {
    final remaining = m.quantity - m.disposedQuantity;
    final stock = m.availableStock;
    if (stock == null) return remaining;
    return remaining < stock ? remaining : stock;
  }

  /// True once real stock data says there's nothing left to give for this
  /// medicine — distinct from "fully dispensed" (which means the
  /// PRESCRIBED amount was already served, not that the shelf is empty).
  bool _isOutOfStock(MedicineItem m) {
    final remaining = m.quantity - m.disposedQuantity;
    return remaining > 0 && _dispensableCap(m) <= 0;
  }

  /// Whether at least one medicine on the selected prescription can still
  /// be dispensed right now — drives both the blocking "Medicine Not
  /// Available" card and the final Dispense button's enabled state. A
  /// single-medicine prescription that's out of stock is just the
  /// smallest case of "nothing here is dispensable"; a multi-medicine
  /// prescription with at least one available item is never blocked.
  bool get _hasAnyDispensableMedicine {
    final entry = _selectedEntry;
    if (entry == null) return false;
    return entry.prescription.medicines.any(
      (m) => !_isOutOfStock(m) && (m.quantity - m.disposedQuantity) > 0,
    );
  }

  /// True when there's still something owed on this prescription (at
  /// least one medicine with quantity > disposedQuantity) — used to keep
  /// the "Medicine Not Available" card scoped to a genuine stock-out.
  /// Without this, a prescription that's simply already fully dispensed
  /// (nothing owed, so _hasAnyDispensableMedicine is also false) would
  /// wrongly show the same blocking card instead of the existing "Fully
  /// Dispensed" indicators.
  bool get _hasRemainingOwed {
    final entry = _selectedEntry;
    if (entry == null) return false;
    return entry.prescription.medicines.any(
      (m) => (m.quantity - m.disposedQuantity) > 0,
    );
  }

  /// The actual trigger for the blocking card: something is still owed,
  /// but stock says none of it can be handed over right now.
  bool get _isBlockedByStock => _hasRemainingOwed && !_hasAnyDispensableMedicine;

  void _incrementMedicine(String name) {
    MedicineItem? m;
    try {
      m = _selectedEntry?.prescription.medicines.firstWhere(
        (med) => med.name == name,
      );
    } on StateError {
      return;
    }
    if (m == null) return;
    final cap = _dispensableCap(m);
    final current = _dispensedQuantities[name] ?? 0;
    if (current < cap) {
      final next = current + 1;
      setState(() {
        _dispensedQuantities[name] = next;
        _quantityErrors[name] = null;
      });
      _qtyControllers[name]?.text = '$next';
    }
  }

  void _decrementMedicine(String name) {
    MedicineItem? m;
    try {
      m = _selectedEntry?.prescription.medicines.firstWhere(
        (med) => med.name == name,
      );
    } on StateError {
      return;
    }
    if (m == null) return;
    final current = _dispensedQuantities[name] ?? 0;
    if (current > 0) {
      final next = current - 1;
      setState(() {
        _dispensedQuantities[name] = next;
        _quantityErrors[name] = null;
      });
      _qtyControllers[name]?.text = '$next';
    }
  }

  void _onQuantityTyped(String name, String value, int maxAllowed) {
    final parsed = int.tryParse(value);
    setState(() {
      if (value.isEmpty) {
        _dispensedQuantities[name] = 0;
        _quantityErrors[name] = null;
      } else if (parsed == null) {
        _quantityErrors[name] = 'Invalid quantity';
      } else if (parsed > maxAllowed) {
        _dispensedQuantities[name] = maxAllowed;
        _quantityErrors[name] = 'Cannot exceed $maxAllowed';
      } else {
        _dispensedQuantities[name] = parsed;
        _quantityErrors[name] = null;
      }
    });
    // Mirrors _incrementMedicine/_decrementMedicine: without writing the
    // clamped value back into the visible field, typing e.g. "13" against a
    // cap of 12 left "13" displayed while only 12 was actually submitted —
    // silently misleading rather than blocked (reported: dispensed 13,
    // recorded 12, no visible indication why).
    if (parsed != null && parsed > maxAllowed) {
      _qtyControllers[name]?.text = '$maxAllowed';
    }
  }

  String _formatDate(DateTime dt) {
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
    final d = dt.toLocal();
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  Future<bool?> _validateDispense() async {
    final entry = _selectedEntry;
    if (entry == null) return null;

    final prescription = entry.prescription;
    if (prescription.dispensingStatus == DispensingStatus.fullyDispensed) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'You cannot dispense anymore. This prescription is already fully dispensed.',
          ),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 3),
        ),
      );
      return false;
    }

    // `_dispensedQuantities` holds how much to dispense THIS visit (starts
    // at 0, set via the +/- steppers), so this is a plain sum.
    final totalToDispense = _dispensedQuantities.values.fold<int>(
      0,
      (a, b) => a + b,
    );
    if (totalToDispense <= 0) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter quantities to dispense at least one medicine.'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 3),
        ),
      );
      return false;
    }

    final api = LaravelApiService(token: AppSession.instance.token);
    final backendId = entry.backendId;

    if (backendId == null || backendId.isEmpty) {
      return true;
    }

    try {
      final validation = await api.validateDispense(
        backendId,
        AppSession.instance.pharmacyId ?? '',
        totalToDispense,
      );
      final rawAllowed = validation['allowed'];
      final blocked = !(rawAllowed is bool ? rawAllowed : true);
      final rawWarning = validation['warning'];
      final warning = rawWarning is bool ? rawWarning : false;
      final priority = (validation['priority'] ?? 'normal').toString();
      final reason = (validation['reason'] ?? '').toString();

      if (!mounted) return !blocked;

      if (blocked) {
        final isHighPriority = priority == 'high';
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            backgroundColor: isHighPriority ? AppColors.dangerBg : AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Row(
              children: [
                Icon(
                  Icons.block_rounded,
                  color: isHighPriority ? AppColors.danger : AppColors.warning,
                  size: 28,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    isHighPriority
                        ? 'BLOCKED: High Priority Alert'
                        : 'Dispensing Alert',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: isHighPriority
                          ? AppColors.danger
                          : AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reason,
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.textSecondary,
                    height: 1.5,
                  ),
                ),
                if (isHighPriority) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.dangerBg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          color: AppColors.danger,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'This requires admin review before proceeding.',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.danger,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              if (!isHighPriority)
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.warning,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Proceed Anyway'),
                ),
            ],
          ),
        );
        return false;
      }

      if (warning) {
        if (!mounted) return true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(reason),
            backgroundColor: AppColors.warning,
            duration: const Duration(seconds: 4),
          ),
        );
      }

      return true;
    } catch (e) {
      if (!mounted) return false;
      String message = 'You cannot dispense anymore.';
      if (e is LaravelApiException) {
        final lower = e.message.toLowerCase();
        if (lower.contains('fully dispensed') ||
            lower.contains('already dispensed')) {
          message =
              'You cannot dispense anymore. This prescription is already fully dispensed.';
        } else if (lower.contains('not approved') ||
            lower.contains('cross pharmacy')) {
          message =
              'You cannot dispense anymore. This cross-pharmacy request is not approved yet.';
        } else if (lower.contains('blocked') || lower.contains('alert')) {
          message =
              'You cannot dispense anymore. This prescription is blocked.';
        } else if (lower.contains('not found') || lower.contains('invalid')) {
          message =
              'You cannot dispense anymore. Invalid prescription or quantity.';
        } else {
          message = 'You cannot dispense anymore. ${e.message}';
        }
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
      return false;
    }
  }

  /// Shows a blocking dialog telling the pharmacist that this fill was NOT
  /// recorded on the server, so they don't walk away believing it was.
  Future<void> _showSyncFailureDialog({
    List<String> succeededMeds = const [],
    required List<String> failedMeds,
  }) async {
    if (!mounted) return;
    final isPartial = succeededMeds.isNotEmpty;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              isPartial ? Icons.warning_amber_rounded : Icons.cloud_off_rounded,
              color: isPartial ? Colors.orange : Colors.red,
              size: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isPartial ? 'Partially saved to server' : 'Not saved to server',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
              ),
            ),
          ],
        ),
        content: Text(
          isPartial
              ? 'Recorded: ${succeededMeds.join(', ')}. Not recorded: '
                    '${failedMeds.join(', ')} — check your connection and tap '
                    'Dispense again to retry ${failedMeds.length > 1 ? 'those' : 'that one'}.'
              : failedMeds.isEmpty
              ? 'This dispensing could not be recorded on the server. '
                    'Nothing was marked as dispensed. Check your connection and try again.'
              : 'This dispensing could not be recorded on the server for: '
                    '${failedMeds.join(', ')}. Nothing was marked as dispensed. '
                    'Check your connection and try again.',
          style: const TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Prompts for the official receipt (OR) number before dispensing to a
  /// senior citizen — required for the Senior Citizen Discount compliance
  /// report. Returns the entered OR number, or null if the pharmacist
  /// cancelled (in which case the dispense should not proceed).
  Future<String?> _promptForOrNumber() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Official Receipt Number',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the OR number issued for this senior citizen discount transaction.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'e.g. 000123',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, null),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              final value = controller.text.trim();
              Navigator.pop(dialogContext, value.isEmpty ? null : value);
            },
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  Future<void> _onDispense() async {
    final entry = _selectedEntry;
    if (entry == null) return;
    final prescription = entry.prescription;

    // Set this immediately, before any awaited step, so the Dispense
    // button (gated on !_isDispensing) disables on the very first tap —
    // otherwise a fast double-tap during _validateDispense()'s network
    // round-trip or the OR-number prompt below could invoke this function
    // twice concurrently and submit the same fill to the server twice.
    setState(() => _isDispensing = true);

    try {
      final canProceed = await _validateDispense();
      if (canProceed != true) return;

      // Senior citizen dispenses need an OR number recorded for the
      // discount compliance report — collect it up front so the fill
      // isn't marked complete without it.
      String? orNumber;
      if (prescription.isSenior) {
        orNumber = await _promptForOrNumber();
        if (orNumber == null) return;
      }

      // Build the current fill record.
      //
      // `_dispensedQuantities[m.name]` is how much to dispense THIS visit
      // only (starts at 0, set via the +/- steppers — see
      // _incrementMedicine / _decrementMedicine). It is added on top of
      // m.disposedQuantity (the running total from prior visits) below.
      final currentFillMeds = <DispensedMedicine>[];
      for (final m in prescription.medicines) {
        final servedThisFill = _dispensedQuantities[m.name] ?? 0;
        if (servedThisFill > 0) {
          currentFillMeds.add(
            DispensedMedicine(
              name: m.name,
              genericName: m.genericName.isNotEmpty ? m.genericName : m.name,
              brand: m.brand,
              unitLabel: m.dosage.isNotEmpty ? m.dosage.split(' ').last : 'tab',
              quantity: servedThisFill,
              pricePerUnit: m.unitPrice,
              stockBefore: m.quantity - m.disposedQuantity,
              stockAfter: m.quantity - (m.disposedQuantity + servedThisFill),
              isSeniorCitizen: prescription.isSenior,
            ),
          );
        }
      }

      // Previous cumulative dispensed per medicine, before this fill — used
      // both for the backend log increment below and for the fill-count math.
      final previousDisposed = <String, int>{};
      for (final m in prescription.medicines) {
        previousDisposed[m.name] = m.disposedQuantity;
      }

      final fillNumber = _priorFillCount + 1;
      final totalFills = _estimateTotalFills(
        fillNumber: fillNumber,
        prescriptionMedicines: prescription.medicines,
        previousDisposed: previousDisposed,
      );
      // Every medicine dispensed in this visit shares one batch_id so the
      // server can later tell they belong to the same fill.
      final batchId =
          'BATCH-${DateTime.now().millisecondsSinceEpoch}-${entry.ocrCode}';

      // Build updated medicines for state: add this visit's amount on top
      // of the running total.
      final updatedMedicines = <MedicineItem>[];
      for (final m in prescription.medicines) {
        final servedThisFill = _dispensedQuantities[m.name] ?? 0;
        updatedMedicines.add(
          m.copyWith(disposedQuantity: m.disposedQuantity + servedThisFill),
        );
      }

      final newStatus =
          updatedMedicines.any((m) => m.disposedQuantity > m.quantity)
          ? DispensingStatus.overDispensing
          : updatedMedicines.every((m) => m.disposedQuantity >= m.quantity)
          ? DispensingStatus.fullyDispensed
          : DispensingStatus.partiallyDispensed;

      final updatedPrescription = prescription.copyWith(
        medicines: updatedMedicines,
        dispensingStatus: newStatus,
      );

      final updatedEntry = entry.copyWith(prescription: updatedPrescription);

      // Persist to the backend BEFORE treating this fill as final.
      //
      // Previously these calls were fired *after* the local store had
      // already been marked with the new dispensing status, wrapped in
      // catch (_) blocks that silently swallowed failures — so a dropped
      // connection meant the pharmacist saw "Fully Dispensed" and the
      // success screen even though nothing was actually recorded
      // server-side. The client's optimistic state was being treated as
      // authoritative regardless of whether the write it depends on
      // actually happened.
      //
      // Now: if a backendId exists, the log + status writes must succeed
      // before local state changes or the success screen shows. If they
      // fail, the pharmacist is told explicitly and nothing is marked
      // dispensed, so they know to retry rather than walking away
      // thinking the fill was recorded.

      if (entry.backendId != null && entry.backendId!.isNotEmpty) {
        final failedMeds = <String>[];
        for (final m in currentFillMeds) {
          // `m` is a DispensedMedicine; `quantity` is this visit's amount
          // (set directly from _dispensedQuantities, which starts at 0
          // per visit), so it's sent to the backend as-is.
          final servedThisFill = m.quantity;
          if (servedThisFill <= 0) {
            continue; // shouldn't happen, quantity > 0 was already required to build currentFillMeds
          }

          try {
            final createdLog = await _api.createDispensingLog(
              prescriptionId: entry.backendId!,
              pharmacyId: AppSession.instance.pharmacyId ?? 'PHARM-001',
              dispenserId: AppSession.instance.userId ?? 'DISPENSER-001',
              productName: m.name,
              quantityServed: servedThisFill,
              batchId: batchId,
              physicianName: prescription.doctorName,
              patientName: prescription.patientName,
              genericName: m.genericName.isNotEmpty ? m.genericName : m.name,
              brandName: m.brand,
              isSeniorCitizen: prescription.isSenior,
              oscaId: prescription.oscaId,
              orNumber: orNumber,
            );

            // Record the SC discount audit line for this item. This is a
            // best-effort secondary write: the medicine has physically
            // already been dispensed and the dispensing log above already
            // succeeded, so a failure here (e.g. missing OSCA ID) shouldn't
            // block the fill or make the pharmacist think nothing was
            // dispensed — it just means this one audit record is missing
            // and can be reconciled later.
            final oscaId = prescription.oscaId;
            final patientId = entry.patientId;
            if (prescription.isSenior &&
                oscaId != null &&
                oscaId.isNotEmpty &&
                patientId != null &&
                patientId.isNotEmpty) {
              try {
                await _api.createSeniorCitizenDiscount(
                  patientId: patientId,
                  patientName: prescription.patientName,
                  oscaId: oscaId,
                  drugName: m.name,
                  grossCost: m.grossTotal,
                  discountAmount: m.discountAmount,
                  netCost: m.lineTotal,
                  prescriptionId: entry.backendId,
                  dispensingLogId: createdLog.logId,
                );
              } catch (e) {
                debugPrint(
                  'Failed to record senior citizen discount for '
                  '${m.name}: $e',
                );
              }
            }
          } catch (_) {
            failedMeds.add(m.name);
          }
        }

        var statusSynced = true;
        try {
          final statusString = newStatus == DispensingStatus.fullyDispensed
              ? 'fully_dispensed'
              : newStatus == DispensingStatus.overDispensing
              ? 'over_dispensing'
              : 'partially_dispensed';
          await _api.updatePrescription(entry.backendId!, {
            'dispensing_status': statusString,
          });
        } catch (_) {
          statusSynced = false;
        }

        final succeededNames = currentFillMeds
            .map((m) => m.name)
            .where((name) => !failedMeds.contains(name))
            .toSet();

        if (succeededNames.isEmpty) {
          // Total failure — nothing recorded server-side. Leave local
          // state and the typed quantities untouched so the whole fill
          // can be retried as-is.
          if (mounted) setState(() => _isDispensing = false);
          await _showSyncFailureDialog(failedMeds: failedMeds);
          return;
        }

        if (failedMeds.isNotEmpty) {
          // Partial success: some medicines are already durably recorded
          // on the server, others aren't. Reflect only the confirmed
          // subset locally — never claim the failed ones were dispensed —
          // and only clear the typed quantity for medicines that actually
          // succeeded, so a retry only resubmits what actually failed
          // instead of double-submitting what already went through.
          final partialMedicines = <MedicineItem>[];
          for (final m in prescription.medicines) {
            final servedThisFill = succeededNames.contains(m.name)
                ? (_dispensedQuantities[m.name] ?? 0)
                : 0;
            partialMedicines.add(
              m.copyWith(
                disposedQuantity: m.disposedQuantity + servedThisFill,
              ),
            );
          }
          final partialStatus =
              partialMedicines.any((m) => m.disposedQuantity > m.quantity)
              ? DispensingStatus.overDispensing
              : partialMedicines.every(
                  (m) => m.disposedQuantity >= m.quantity,
                )
              ? DispensingStatus.fullyDispensed
              : DispensingStatus.partiallyDispensed;
          final partialEntry = entry.copyWith(
            prescription: prescription.copyWith(
              medicines: partialMedicines,
              dispensingStatus: partialStatus,
            ),
          );

          SavedPrescriptionsStore.instance.replaceOrInsert(partialEntry);
          // Best-effort — the per-item logs already written above are the
          // source of truth for what was actually dispensed; this
          // denormalized status field is secondary and safe to leave
          // stale until the next successful sync.
          try {
            final partialStatusString =
                partialStatus == DispensingStatus.fullyDispensed
                ? 'fully_dispensed'
                : partialStatus == DispensingStatus.overDispensing
                ? 'over_dispensing'
                : 'partially_dispensed';
            await _api.updatePrescription(entry.backendId!, {
              'dispensing_status': partialStatusString,
            });
          } catch (_) {}

          if (mounted) {
            setState(() {
              _isDispensing = false;
              for (final name in succeededNames) {
                _dispensedQuantities[name] = 0;
              }
            });
            for (final name in succeededNames) {
              _qtyControllers[name]?.text = '0';
            }
          }
          await _showSyncFailureDialog(
            succeededMeds: succeededNames.toList(),
            failedMeds: failedMeds,
          );
          return;
        }

        if (!statusSynced) {
          // Every medicine's dispense IS durably recorded (via the logs
          // above) — only the secondary dispensing_status field failed to
          // sync. That's not "nothing was dispensed", so fall through to
          // the normal success path below instead of showing the blocking
          // failure dialog; just note the miss for later reconciliation.
          debugPrint(
            'Dispensing recorded for ${entry.ocrCode}, but the '
            'dispensing_status field failed to sync to the server.',
          );
        }
      }

      SavedPrescriptionsStore.instance.replaceOrInsert(updatedEntry);

      if (!mounted) return;

      final transaction = DispensingTransaction(
        pharmacyName: 'Care About Us Pharmacy',
        fillNumber: fillNumber,
        totalFills: totalFills,
        dateTime: DateTime.now(),
        patientName: updatedPrescription.patientName,
        patientAge: updatedPrescription.patientAge,
        patientSex: updatedPrescription.patientGender,
        rxNumber: updatedPrescription.ocrCode,
        dispensedBy: AppSession.instance.userId ?? 'Pharmacist',
        dispensedByRole: 'Pharmacist',
        authorizedBy: updatedPrescription.doctorName,
        authorizedByTitle: 'Prescribing Doctor',
        medicines: currentFillMeds,
        isSenior: updatedPrescription.isSenior,
        oscaId: updatedPrescription.oscaId,
        dispensingStatus: newStatus,
      );

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DispensingSummaryScreen(transaction: transaction),
        ),
      );

      if (mounted) {
        setState(() {
          _resetDispensedQuantities();
          _selectedOcrCode = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Dispensing failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isDispensing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _filteredEntries;
    final selectedEntry = _selectedEntry;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        foregroundColor: const Color(0xFF1A1D29),
        title: widget.initialOcrCode != null && selectedEntry != null
            ? Text(
                selectedEntry.prescription.patientName,
                style: const TextStyle(fontWeight: FontWeight.w700),
              )
            : const Text(
                'Dispensing Record',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
        actions: [
          if (_selectedOcrCode != null)
            IconButton(
              onPressed: () {
                setState(() {
                  _selectedOcrCode = null;
                  _resetDispensedQuantities();
                  _backendLogs.clear();
                });
              },
              icon: const Icon(Icons.close),
              tooltip: 'Deselect',
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () {
              setState(() => _isLoading = true);
              _fetchPrescriptions(force: true);
            },
          ),
        ],
      ),
      body: SafeArea(
        child: _isLoading
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFF0B7B77)),
                    SizedBox(height: 16),
                    Text(
                      widget.initialOcrCode != null
                          ? 'Loading patient data...'
                          : 'Loading prescriptions...',
                      style: TextStyle(
                        fontSize: 14,
                        color: Color(0xFF8A8F9C),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              )
            : widget.initialOcrCode != null && selectedEntry == null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.person_off_outlined,
                      size: 48,
                      color: const Color(0xFF8A8F9C).withValues(alpha: 0.4),
                    ),
                    SizedBox(height: 12),
                    Text(
                      'No dispensing record found for this QR code.',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF8A8F9C),
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Prescription may not exist or has been removed.',
                      style: TextStyle(
                        color: Color(0xFF8A8F9C),
                        fontSize: 12.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            : _selectedOcrCode != null && selectedEntry != null
            ? SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  children: [
                    _buildPatientCard(selectedEntry),
                    if (_isBlockedByStock) ...[
                      const SizedBox(height: 18),
                      _buildMedicineNotAvailableCard(),
                    ],
                    const SizedBox(height: 18),
                    _sectionLabel('DISPENSING HISTORY'),
                    const SizedBox(height: 8),
                    _buildBackendHistoryCard(),
                    const SizedBox(height: 18),
                    _sectionLabel('DISPENSE NOW'),
                    const SizedBox(height: 8),
                    _buildMedicinesList(selectedEntry),
                  ],
                ),
              )
            : Column(
                children: [
                  _buildSearchBar(),
                  Expanded(child: _buildEntryList(entries)),
                ],
              ),
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  // ---------- SEARCH BAR ----------
  Widget _buildSearchBar() {
    return Container(
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
          onChanged: (v) => setState(() => _searchQuery = v),
          style: const TextStyle(fontSize: 14, color: Color(0xFF1A1D29)),
          decoration: InputDecoration(
            hintText: 'Search by patient name, RX code, or doctor...',
            hintStyle: const TextStyle(
              color: Color(0xFF8A8F9C),
              fontSize: 13.5,
            ),
            prefixIcon: const Icon(
              Icons.search,
              color: Color(0xFF8A8F9C),
              size: 20,
            ),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                    tooltip: 'Clear search',
                    icon: const Icon(
                      Icons.clear,
                      color: Color(0xFF8A8F9C),
                      size: 18,
                    ),
                  )
                : null,
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

  // ---------- SECTION LABEL ----------
  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: Color(0xFFA4A9B4),
        ),
      ),
    );
  }

  // ---------- PATIENT CARD WITH IMAGE ----------
  Widget _buildPatientCard(PrescriptionEntry entry) {
    final p = entry.prescription;
    final hasImage = entry.imageBytes.isNotEmpty;
    final imageBytes = hasImage ? entry.imageBytes : Uint8List(0);
    final hasNetworkImage = !hasImage && (entry.imageUrl?.isNotEmpty ?? false);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Prescription image thumbnail
          if (hasImage)
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: const Color(0xFFF0F2F5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFEEF0F3)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  imageBytes,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.image_not_supported_outlined,
                    size: 24,
                    color: Color(0xFFC0C4C8),
                  ),
                ),
              ),
            )
          else if (hasNetworkImage)
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: const Color(0xFFF0F2F5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFEEF0F3)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AuthenticatedNetworkImage(
                  imageUrl: entry.imageUrl!,
                  token: AppSession.instance.token,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  errorWidget: const Icon(
                    Icons.image_not_supported_outlined,
                    size: 24,
                    color: Color(0xFFC0C4C8),
                  ),
                ),
              ),
            )
          else
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: const Color(0xFF0F7A6E),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Text(
                p.patientName.isNotEmpty ? p.patientName[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${p.patientName}, ${p.patientAge}${p.patientGender}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1A1D29),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${p.ocrCode} · ${p.doctorName} · PRC ${p.licenseNo}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF8A8F9C),
                    height: 1.5,
                  ),
                ),
                Row(
                  children: [
                    if (p.isSenior)
                      Container(
                        margin: const EdgeInsets.only(top: 6, right: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF7E6),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(
                              Icons.elderly_rounded,
                              size: 12,
                              color: Color(0xFFD97706),
                            ),
                            SizedBox(width: 3),
                            Text(
                              'Senior Citizen',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFD97706),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (p.dispensingStatus != DispensingStatus.pending)
                      Container(
                        margin: const EdgeInsets.only(top: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color:
                              p.dispensingStatus ==
                                  DispensingStatus.fullyDispensed
                              ? const Color(0xFFE6F6EE)
                              : p.dispensingStatus ==
                                    DispensingStatus.overDispensing
                              ? const Color(0xFFFEE2E2)
                              : const Color(0xFFFFF7E6),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          p.dispensingStatus == DispensingStatus.fullyDispensed
                              ? 'Fully Dispensed'
                              : p.dispensingStatus ==
                                    DispensingStatus.overDispensing
                              ? 'Overdispensing'
                              : 'Partial',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color:
                                p.dispensingStatus ==
                                    DispensingStatus.fullyDispensed
                                ? const Color(0xFF1F9D63)
                                : p.dispensingStatus ==
                                      DispensingStatus.overDispensing
                                ? const Color(0xFFDC2626)
                                : const Color(0xFFD97706),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- MEDICINE NOT AVAILABLE CARD ----------
  /// Blocking card shown when NOTHING on the selected prescription can be
  /// dispensed right now — either because it's a single-medicine
  /// prescription and that medicine is out of stock, or (the general
  /// case this also covers) every medicine on a multi-medicine
  /// prescription is out of stock. When at least one medicine IS
  /// dispensable, this card does not show — the dispenser proceeds with
  /// what's available, and each unavailable line is instead marked
  /// "Out of Stock" in the list below (see _buildMedicineStepperRow),
  /// with its stepper simply not rendered so it can't be dispensed.
  Widget _buildMedicineNotAvailableCard() {
    final entry = _selectedEntry;
    final unavailable = entry == null
        ? const <MedicineItem>[]
        : entry.prescription.medicines
              .where((m) => (m.quantity - m.disposedQuantity) > 0)
              .toList();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFEE2E2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFDC2626).withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.report_rounded, color: Color(0xFFDC2626), size: 20),
              SizedBox(width: 8),
              Text(
                'Medicine Not Available',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                  color: Color(0xFFDC2626),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'None of the medicine(s) still owed on this prescription are '
            'currently in stock at this pharmacy:',
            style: TextStyle(fontSize: 12.5, color: Color(0xFF991B1B)),
          ),
          const SizedBox(height: 6),
          ...unavailable.map(
            (m) => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '• ${m.dosage.isNotEmpty ? '${m.name} (${m.dosage})' : m.name}',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF991B1B),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Dispensing is blocked for this prescription until stock is '
            'available. Nothing has been dispensed.',
            style: TextStyle(fontSize: 12, color: Color(0xFF991B1B)),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () =>
                  Navigator.of(context).popUntil((route) => route.isFirst),
              icon: const Icon(Icons.arrow_back, color: Color(0xFFDC2626)),
              label: const Text('Back to Dashboard'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFDC2626),
                side: const BorderSide(color: Color(0xFFDC2626)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 13.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- BACKEND DISPENSING LOGS CARD ----------
  Widget _buildBackendHistoryCard() {
    if (_backendLogs.isEmpty && !_historyLoading) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              Icons.history_outlined,
              size: 20,
              color: const Color(0xFF8A8F9C).withValues(alpha: 0.6),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'No dispensing history yet',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1A1D29),
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Records will appear here once this prescription is dispensed.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF8A8F9C)),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (_backendLogs.isEmpty && _historyLoading) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: const Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF0B7B77),
              ),
            ),
            SizedBox(width: 10),
            Text(
              'Loading dispensing history…',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF0B7B77),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.cloud_done_outlined,
                color: Color(0xFF0B7B77),
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                'Server History (${_backendLogs.length})',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0B7B77),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (int i = 0; i < _backendLogs.length; i++) ...[
            if (i > 0) const Divider(color: Color(0xFFEEF0F3), height: 1),
            const SizedBox(height: 10),
            _buildBackendLogRow(_backendLogs[i]),
          ],
        ],
      ),
    );
  }

  // Status badge for one dispensing-history row. DispensingLog.status is
  // never actually set to 'fully_dispensed'/'over_dispensing' by the normal
  // dispense flow (DispensingLogController::store never writes those
  // values — that state lives on the prescription's dispensing_status
  // instead), so comparing log.status against them here always fell
  // through to "Partial" and never showed Overdispensing at all. Instead,
  // match this log's medicine against the currently selected prescription
  // and reuse the exact same over/fully-dispensed calculation already used
  // for the stepper row above, for a status that's actually accurate.
  Widget _buildBackendLogRow(DispensingLog log) {
    MedicineItem? matched;
    try {
      matched = _selectedEntry?.prescription.medicines.firstWhere(
        (m) => m.name == log.productName,
      );
    } on StateError {
      matched = null;
    }

    final isOverDispensed =
        matched != null && matched.disposedQuantity > matched.quantity;
    final isFullyDispensed =
        matched != null &&
        !isOverDispensed &&
        (matched.quantity - matched.disposedQuantity) <= 0;

    final String label = isOverDispensed
        ? 'Overdispensing'
        : isFullyDispensed
        ? 'Fully Dispensed'
        : 'Partial';
    final Color badgeBg = isOverDispensed
        ? const Color(0xFFFEE2E2)
        : isFullyDispensed
        ? const Color(0xFFE6F6EE)
        : const Color(0xFFFFF7E6);
    final Color badgeFg = isOverDispensed
        ? const Color(0xFFDC2626)
        : isFullyDispensed
        ? const Color(0xFF1F9D63)
        : const Color(0xFFD97706);

    return Row(
      children: [
        Container(
          width: 18,
          height: 18,
          decoration: const BoxDecoration(
            color: Color(0xFF0B7B77),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.check, size: 12, color: Colors.white),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${log.productName} ×${log.quantityServed}',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1A1D29),
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: badgeBg,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: badgeFg,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _formatDate(log.dispensedAt ?? DateTime.now()),
          style: const TextStyle(fontSize: 12, color: Color(0xFF8A8F9C)),
        ),
      ],
    );
  }

  // ---------- MEDICINE LIST WITH STEPPER ----------
  Widget _buildMedicinesList(PrescriptionEntry entry) {
    final p = entry.prescription;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < p.medicines.length; i++) ...[
            if (i > 0) const Divider(color: Color(0xFFEEF0F3), height: 1),
            const SizedBox(height: 14),
            _buildMedicineStepperRow(p.medicines[i]),
          ],
          const SizedBox(height: 16),
          Divider(color: const Color(0xFFEEF0F3), height: 1),
          const SizedBox(height: 14),
          _buildTotalRow(p),
        ],
      ),
    );
  }

  Widget _buildMedicineStepperRow(MedicineItem m) {
    final currentDispensed = _dispensedQuantities[m.name] ?? 0;
    final remaining = m.quantity - m.disposedQuantity;
    final isOverDispensed = m.disposedQuantity > m.quantity;
    final isFullyDispensed = !isOverDispensed && remaining <= 0;
    final cap = _dispensableCap(m);
    // Real stock is tracked, is below what's still owed, but isn't zero —
    // worth telling the dispenser why the stepper caps out before
    // `remaining`, instead of it just looking like a bug.
    final isPartiallyStocked =
        !isOverDispensed && !isFullyDispensed && m.availableStock != null && cap < remaining && cap > 0;
    final isOutOfStock =
        !isOverDispensed && !isFullyDispensed && _isOutOfStock(m);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                m.name,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1A1D29),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                m.dosage,
                style: TextStyle(fontSize: 13, color: const Color(0xFF8A8F9C)),
              ),
              if (m.unitPrice > 0)
                Text(
                  '₱${m.unitPrice.toStringAsFixed(2)} / unit',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF0B5E55),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (m.disposedQuantity > 0)
                Text(
                  'Already dispensed: \u00D7${m.disposedQuantity}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF1F9D63),
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          if (isOverDispensed) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Overdispensing',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFFDC2626),
                ),
              ),
            ),
          ] else if (isFullyDispensed) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFE6F6EE),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Fully Dispensed',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1F9D63),
                ),
              ),
            ),
          ] else if (isOutOfStock) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFFDC2626).withValues(alpha: 0.4),
                ),
              ),
              child: const Text(
                'Out of Stock',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFDC2626),
                ),
              ),
            ),
          ] else ...[
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  children: [
                    _stepperButton(
                      Icons.remove,
                      () => _decrementMedicine(m.name),
                      'Decrease quantity',
                    ),
                    SizedBox(
                      width: 52,
                      child: TextFormField(
                        key: ValueKey('qty_${m.name}'),
                        controller: _qtyControllerFor(m.name, currentDispensed),
                        textAlign: TextAlign.center,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1A1D29),
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 6),
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) =>
                            _onQuantityTyped(m.name, value, cap),
                      ),
                    ),
                    _stepperButton(
                      Icons.add,
                      () => _incrementMedicine(m.name),
                      'Increase quantity',
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _quantityErrors[m.name] ??
                      (isPartiallyStocked
                          ? 'of $cap (stock: ${m.availableStock})'
                          : 'of $cap'),
                  style: TextStyle(
                    fontSize: 10,
                    color: _quantityErrors[m.name] != null || isPartiallyStocked
                        ? const Color(0xFFDC2626)
                        : const Color(0xFFA4A9B4),
                    fontWeight: _quantityErrors[m.name] != null || isPartiallyStocked
                        ? FontWeight.w700
                        : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTotalRow(Prescription p) {
    final totalCount = p.medicines.fold<int>(
      0,
      (sum, m) => sum + (_dispensedQuantities[m.name] ?? 0),
    );
    double gross = 0;
    for (final m in p.medicines) {
      final qty = _dispensedQuantities[m.name] ?? 0;
      gross += qty * m.unitPrice;
    }
    final discount = p.isSenior ? gross * 0.20 : 0.0;
    final net = gross - discount;

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Total Medicines',
              style: TextStyle(fontSize: 13, color: Color(0xFF8A8F9C)),
            ),
            Text(
              '$totalCount',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Color(0xFF0B5E55),
              ),
            ),
          ],
        ),
        if (gross > 0) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Subtotal',
                style: TextStyle(fontSize: 13, color: Color(0xFF8A8F9C)),
              ),
              Text(
                '₱${gross.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 13, color: Color(0xFF8A8F9C)),
              ),
            ],
          ),
          if (p.isSenior) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: const [
                    Icon(
                      Icons.elderly_rounded,
                      size: 16,
                      color: Color(0xFFD97706),
                    ),
                    SizedBox(width: 4),
                    Text(
                      'SC Discount (20%)',
                      style: TextStyle(
                        fontSize: 13,
                        color: Color(0xFFD97706),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Text(
                  '−₱${discount.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFFD97706),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Divider(color: Color(0xFFEEF0F3), height: 1),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Total Payable',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1A1D29),
                  ),
                ),
                Text(
                  '₱${net.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0B5E55),
                  ),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 8),
            const Divider(color: Color(0xFFEEF0F3), height: 1),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Total Payable',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1A1D29),
                  ),
                ),
                Text(
                  '₱${net.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0B5E55),
                  ),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }

  // ---------- STEPPER BUTTON ----------
  Widget _stepperButton(IconData icon, VoidCallback onTap, String label) {
    return TapTarget(
      onTap: onTap,
      semanticLabel: label,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 32,
        height: 32,
        decoration: const BoxDecoration(
          color: Color(0xFFEEF1F4),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 16, color: Color(0xFF1A1D29)),
      ),
    );
  }

  // ---------- ENTRY LIST ----------
  Widget _buildEntryList(List<PrescriptionEntry> entries) {
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.local_pharmacy_outlined,
                size: 48,
                color: const Color(0xFF8A8F9C).withValues(alpha: 0.4),
              ),
              const SizedBox(height: 12),
              Text(
                _searchQuery.isNotEmpty
                    ? 'No matching prescriptions'
                    : 'No prescriptions available for dispensing',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF8A8F9C),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _searchQuery.isNotEmpty
                    ? 'Try a different search term.'
                    : 'All prescriptions are either fully dispensed or already completed.',
                style: const TextStyle(
                  color: Color(0xFF8A8F9C),
                  fontSize: 12.5,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final p = entry.prescription;
        final isSelected = _selectedOcrCode == p.ocrCode;
        final isOverDispensed =
            p.dispensingStatus == DispensingStatus.overDispensing;
        final isPartiallyDispensed =
            p.dispensingStatus == DispensingStatus.partiallyDispensed;

        return InkWell(
          onTap: () => _onSelectEntry(entry),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFFF0FAF9) : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isSelected
                    ? const Color(0xFF0B7B77)
                    : const Color(0xFFEEF0F3),
                width: isSelected ? 1.5 : 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: isSelected ? 0.06 : 0.02,
                  ),
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
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF0B7B77)
                            : AppColors.teal.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.person_outline,
                        color: isSelected ? Colors.white : AppColors.teal,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.patientName,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color: isSelected
                                  ? const Color(0xFF0B7B77)
                                  : const Color(0xFF1F2937),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${p.patientGender} \u00B7 ${p.patientAge} years old',
                            style: const TextStyle(
                              color: Color(0xFF8A8F9C),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isOverDispensed)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEE2E2),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'Overdispensing',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFFDC2626),
                          ),
                        ),
                      ),
                    if (isPartiallyDispensed)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF7E6),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'Partial',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFFD97706),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${p.medicines.length} medicine(s) \u00B7 \u20B1${p.totalPrice.toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: Color(0xFF8A8F9C),
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Text(
                      p.ocrCode,
                      style: TextStyle(
                        fontSize: 10,
                        color: const Color(0xFF9CA3AF),
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------- BOTTOM BAR ----------
  Widget _buildBottomBar() {
    final selectedEntry = _selectedEntry;
    final hasAnyQuantity = _dispensedQuantities.values.any((v) => v > 0);
    // _hasAnyDispensableMedicine is the explicit "none of the medicines
    // can be dispensed" gate the stock-availability handling requires —
    // hasAnyQuantity would normally already be false in that case since
    // out-of-stock rows never render a stepper to type a quantity into,
    // but this keeps the button's disabled state directly traceable to
    // stock rather than incidental to the stepper UI.
    final canDispense =
        hasAnyQuantity &&
        selectedEntry != null &&
        !_isDispensing &&
        _hasAnyDispensableMedicine;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: const Color(0xFFEEF0F3))),
      ),
      child: SafeArea(
        child: Row(
          children: [
            if (selectedEntry != null) ...[
              Flexible(
                child: OutlinedButton.icon(
                  onPressed: _isDispensing
                      ? null
                      : () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => SavedPrescriptionsListScreen(),
                            ),
                          );
                        },
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text(
                    'View List',
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF0B7B77),
                    side: BorderSide(color: Color(0xFF0B7B77)),
                    padding: EdgeInsets.symmetric(
                      vertical: 14,
                      horizontal: context.isSmallPhone ? 10 : 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    textStyle: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed: canDispense ? _onDispense : null,
                icon: _isDispensing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.local_pharmacy_rounded),
                label: Text(_isDispensing ? 'Dispensing...' : 'Dispense'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0B7B77),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Color(
                    0xFF0B7B77,
                  ).withValues(alpha: 0.4),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14.5,
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
