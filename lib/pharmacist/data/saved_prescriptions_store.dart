// saved_prescriptions_store.dart
//
// In-memory store + optional Laravel sync for prescriptions.
// Keeps local state for offline use, and pushes to backend when available.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../common/services/laravel_api_service.dart';
import '../../common/session.dart';
import '../models/adherence.dart';
import '../models/prescription.dart';

class SavedPrescriptionsStore {
  SavedPrescriptionsStore._();

  static final SavedPrescriptionsStore instance = SavedPrescriptionsStore._();

  final List<PrescriptionEntry> _items = [];
  final Set<String> _hiddenOcrCodes = {};

  // Tracks a create-prescription call currently in flight for a given
  // ocrCode. Two entry points can race to create the same prescription
  // (the automatic sync in `add()`, and a manual "Save to backend" from
  // the detail screen using a stale `backendId` snapshot) — both would
  // otherwise POST the same ocr_code and the second hits the DB's unique
  // constraint. Concurrent callers for the same ocrCode await the same
  // in-flight Future instead of issuing a second request.
  final Map<String, Future<void>> _pendingCreates = {};

  LaravelApiService get _api =>
      LaravelApiService(token: AppSession.instance.token);

  List<PrescriptionEntry> get items => List.unmodifiable(_items);

  Set<String> get hiddenOcrCodes => Set.unmodifiable(_hiddenOcrCodes);

  bool isHidden(String ocrCode) => _hiddenOcrCodes.contains(ocrCode);

  Future<void> add(PrescriptionEntry prescription) async {
    _items.insert(0, prescription);
    await _syncEntryToBackend(prescription);
  }

  void replaceOrInsert(PrescriptionEntry entry) {
    final idx = _items.indexWhere((e) => e.ocrCode == entry.ocrCode);
    if (idx != -1) {
      _items[idx] = entry;
    } else {
      _items.insert(0, entry);
    }
  }

  void insertWithoutSync(PrescriptionEntry entry) {
    final idx = _items.indexWhere((e) => e.ocrCode == entry.ocrCode);
    if (idx != -1) {
      _items[idx] = entry;
    } else {
      _items.insert(0, entry);
    }
  }

  void updateStatus(String ocrCode, QrStatus status) {
    final idx = _items.indexWhere((p) => p.ocrCode == ocrCode);
    if (idx == -1) {
      return;
    }
    final updated = _items[idx].copyWith(
      prescription: _items[idx].prescription.copyWith(status: status),
    );
    _items[idx] = updated;
  }

  void updateQrToken(String ocrCode, String token, String verifyUrl) {
    final idx = _items.indexWhere((p) => p.ocrCode == ocrCode);
    if (idx == -1) {
      return;
    }
    final updated = _items[idx].copyWith(
      qrToken: token,
      backendVerifyUrl: verifyUrl,
      // Must be the bare verify URL, not a JSON blob — a generic external
      // QR reader (Google Lens, phone camera) only offers to open a link
      // when the QR encodes a URL directly; JSON text just displays as
      // text and never redirects. Mirrors the same fix already applied to
      // _inlineQrPayload() in saved_prescriptions_list_screen.dart.
      qrData: verifyUrl,
      prescription: _items[idx].prescription.copyWith(
        status: QrStatus.qrGenerated,
      ),
    );
    _items[idx] = updated;
  }

  void updateDisposedQuantities(
    String ocrCode,
    List<MedicineItem> updatedMedicines,
  ) {
    final idx = _items.indexWhere((p) => p.ocrCode == ocrCode);
    if (idx == -1) {
      return;
    }
    final updated = _items[idx].copyWith(
      prescription: _items[idx].prescription.copyWith(
        medicines: updatedMedicines,
      ),
    );
    _items[idx] = updated;
  }

  void updateDispensingStatus(String ocrCode, DispensingStatus status) {
    final idx = _items.indexWhere((p) => p.ocrCode == ocrCode);
    if (idx == -1) {
      return;
    }
    final updated = _items[idx].copyWith(
      prescription: _items[idx].prescription.copyWith(dispensingStatus: status),
    );
    _items[idx] = updated;
  }

  void removeLocal(String ocrCode) {
    _items.removeWhere((e) => e.ocrCode == ocrCode);
    _hiddenOcrCodes.add(ocrCode);
    debugPrint(
      'STORE: Soft-deleted ocrCode=$ocrCode (hidden, not removed from backend)',
    );
  }

  /// Deletes the prescription on the backend (soft delete — the row and its
  /// dispensing history are kept for audit purposes, but it stops showing up
  /// anywhere it's normally listed: Saved Rx, Dispense, and Patient
  /// Adherence). Falls back to a local-only hide if there's no backend
  /// record to delete (e.g. it was never synced).
  Future<void> deleteEverywhere(PrescriptionEntry entry) async {
    if (entry.backendId != null && entry.backendId!.isNotEmpty) {
      await _api.deletePrescription(entry.backendId!);
    }
    removeLocal(entry.ocrCode);
  }

  Future<void> syncEntryToBackend(PrescriptionEntry entry) async {
    await _syncEntryToBackend(entry);
  }

  /// The current backendId for [ocrCode], if this store has synced it —
  /// use this instead of a possibly-stale `PrescriptionEntry.backendId`
  /// snapshot (e.g. one captured by a widget before the background sync
  /// from `add()` finished) when deciding whether to create or update.
  String? backendIdFor(String ocrCode) {
    final idx = _items.indexWhere((p) => p.ocrCode == ocrCode);
    if (idx == -1) {
      return null;
    }
    final id = _items[idx].backendId;
    return (id != null && id.isNotEmpty) ? id : null;
  }

  Future<void> _syncEntryToBackend(PrescriptionEntry entry) async {
    if (entry.backendId != null && entry.backendId!.isNotEmpty) {
      return;
    }
    final ocrCode = entry.ocrCode;
    final existing = _pendingCreates[ocrCode];
    if (existing != null) {
      // Another caller is already creating this prescription — wait for
      // it instead of issuing a duplicate POST.
      return existing;
    }

    final future = _createEntryOnBackend(entry);
    _pendingCreates[ocrCode] = future;
    try {
      await future;
    } finally {
      _pendingCreates.remove(ocrCode);
    }
  }

  Future<void> _createEntryOnBackend(PrescriptionEntry entry) async {
    // Re-check after any await above resolved a race: the entry may have
    // picked up a backendId (via replaceOrInsert/fetchFromBackend) while
    // this call was queued.
    final live = backendIdFor(entry.ocrCode);
    if (live != null) {
      return;
    }
    final medicines = entry.prescription.medicines
        .map(
          (m) => {
            'name': m.name,
            'original_ocr_name': m.originalOcrName,
            'dosage': m.dosage,
            'brand_name': m.brand,
            'quantity': m.quantity,
            'unit_price': m.unitPrice,
            'is_essential': m.isEssential,
            'duration': m.duration,
            'days_supply': m.daysSupply,
          },
        )
        .toList();

    final session = AppSession.instance;
    final created = await _api.createPrescription(
      ocrCode: entry.ocrCode,
      patientName: entry.prescription.patientName,
      patientAge: entry.prescription.patientAge,
      patientGender: entry.prescription.patientGender,
      isSenior: entry.prescription.isSenior,
      oscaId: entry.prescription.oscaId,
      doctorName: entry.prescription.doctorName,
      licenseNo: entry.prescription.licenseNo,
      ptNo: entry.prescription.ptNo,
      s2: entry.prescription.s2,
      patientAddress: entry.prescription.patientAddress,
      dateTime: entry.prescription.dateTime,
      medicines: medicines,
      totalPrice: entry.prescription.totalPrice,
      rawExtractedText: entry.rawExtractedText,
      pharmacistId: session.userType == 'admin' ? session.userId : null,
      dispenserId: session.userType == 'dispenser' ? session.userId : null,
      pharmacyId: session.pharmacyId,
      imageBytes: entry.imageBytes,
    );

    final idx = _items.indexWhere((p) => p.ocrCode == entry.ocrCode);
    if (idx != -1) {
      _items[idx] = _items[idx].copyWith(backendId: created.id);
    }
  }

  Future<void> syncDispensingStatusToBackend(
    String ocrCode,
    DispensingStatus status,
  ) async {
    final idx = _items.indexWhere((p) => p.ocrCode == ocrCode);
    if (idx == -1) {
      return;
    }
    final entry = _items[idx];
    if (entry.backendId == null) {
      return;
    }
    try {
      final statusString = status == DispensingStatus.fullyDispensed
          ? 'fully_dispensed'
          : status == DispensingStatus.overDispensing
          ? 'over_dispensing'
          : status == DispensingStatus.partiallyDispensed
          ? 'partially_dispensed'
          : 'pending';
      await _api.updatePrescription(entry.backendId!, {
        'dispensing_status': statusString,
      });
    } catch (_) {
      // Ignore backend sync errors for dispensing status
    }
  }

  Future<void> syncQrStatusToBackend(String ocrCode) async {
    final idx = _items.indexWhere((p) => p.ocrCode == ocrCode);
    if (idx == -1) {
      return;
    }
    final entry = _items[idx];
    if (entry.backendId == null || entry.qrToken == null) {
      return;
    }
    try {
      await _api.updatePrescription(entry.backendId!, {
        'status': 'qr_generated',
        'qr_token': entry.qrToken,
      });
    } catch (_) {
      // Ignore backend sync errors for QR status
    }
  }

  // The dashboard, SavedPrescriptionsListScreen, and DispenseScreen each
  // call fetchFromBackend() independently on their own first load — without
  // this guard, near-simultaneous calls (e.g. tapping a nav tab while the
  // dashboard's own fetch is still in flight) fire duplicate HTTP requests
  // and duplicate the sequential adherence-fetch chain below. Sharing one
  // in-flight Future means every concurrent caller awaits the same fetch
  // and gets the same result (or the same thrown exception).
  Future<void>? _inFlightFetch;

  // Guards against sequential redundant refetches (distinct from
  // _inFlightFetch above, which only guards concurrent ones) — e.g. the
  // dashboard's own load followed a few seconds later by navigating to
  // Saved Rx or Dispense, each triggering their own independent
  // fetchFromBackend() call for data that's still fresh.
  DateTime? _lastFetchedAt;
  static const _fetchTtl = Duration(seconds: 15);

  /// Fetches all prescriptions from the backend and merges them into the local store.
  /// Existing entries are updated; new entries from the backend are added.
  /// Throws on network or API errors so callers can handle loading/error UI.
  /// Pass [force] to bypass the freshness TTL — always do this for an
  /// explicit user-initiated refresh (pull-to-refresh, manual reload).
  Future<void> fetchFromBackend({bool force = false}) {
    final lastFetch = _lastFetchedAt;
    if (!force &&
        lastFetch != null &&
        DateTime.now().difference(lastFetch) < _fetchTtl) {
      return Future.value();
    }

    final existing = _inFlightFetch;
    if (existing != null) return existing;
    _lastFetchedAt = DateTime.now();
    final future = _fetchFromBackendInternal().whenComplete(() {
      _inFlightFetch = null;
    });
    _inFlightFetch = future;
    return future;
  }

  /// One-off fresh prescription fetch used purely to open a known
  /// prescription by id (the OCR "View Existing" / reopened-duplicate
  /// path). Deliberately isolated from the normal [fetchFromBackend]
  /// machinery:
  ///
  ///  * it does NOT read or assign [_inFlightFetch] — so it can't inherit
  ///    (or hand off) a normal fetch's still-pending store-wide adherence
  ///    fan-out, and vice versa;
  ///  * it does NOT touch [_lastFetchedAt] — so it can't make a later
  ///    dashboard/Saved Rx load skip its own required adherence refresh
  ///    inside the TTL window;
  ///  * it does NOT call [_fetchAdherenceForAll] — PrescriptionDetailScreen
  ///    (the only destination here) never reads entry.adherence, so the
  ///    N-patient adherence fan-out is pure dead weight on this path.
  ///
  /// It still performs a real, un-cached `fetchPrescriptions()` so a
  /// just-created duplicate record is guaranteed present before the caller
  /// looks it up. Prescription merge into [_items] is the exact same logic
  /// the normal fetch uses.
  Future<void> fetchPrescriptionsForNavigation() async {
    final prescriptions = await _api.fetchPrescriptions();
    _mergePrescriptions(prescriptions);
  }

  Future<void> _fetchFromBackendInternal() async {
    final prescriptions = await _api.fetchPrescriptions();
    _mergePrescriptions(prescriptions);
    await _fetchAdherenceForAll();
  }

  /// Merges a freshly fetched backend prescription list into [_items]:
  /// existing entries are updated in place, new ones appended, then the
  /// list is re-sorted newest-first. Pure local state work — no network,
  /// no adherence. Shared by [_fetchFromBackendInternal] and
  /// [fetchPrescriptionsForNavigation].
  void _mergePrescriptions(List<LaravelPrescription> prescriptions) {
    for (final p in prescriptions) {
      if (_hiddenOcrCodes.contains(p.ocrCode)) {
        continue;
      }
      final existingIdx = _items.indexWhere(
        (e) => e.ocrCode == p.ocrCode || e.backendId == p.id,
      );

      if (existingIdx != -1) {
        // Update existing entry with backend data
        final localEntry = _items[existingIdx];

        final medicines = p.items
            .map(
              (i) => MedicineItem(
                name: i.name,
                originalOcrName: i.originalOcrName ?? '',
                genericName: i.genericName ?? i.name,
                brand: i.brandName ?? '',
                dosage: i.dosage ?? '',
                quantity: i.quantity,
                disposedQuantity: i.disposedQuantity,
                unitPrice: i.unitPrice,
                isEssential: i.isEssential,
                duration: i.duration ?? '',
                daysSupply: i.daysSupply,
                availableStock: i.availableStock,
              ),
            )
            .toList();

        final status = p.status == 'qr_generated'
            ? QrStatus.qrGenerated
            : QrStatus.pendingQr;
        final dispensingStatus = _parseDispensingStatus(p.dispensingStatus);
        final localDispensingStatus = localEntry.prescription.dispensingStatus;
        final effectiveDispensingStatus =
            _isForwardDispensingProgression(
              localDispensingStatus,
              dispensingStatus,
            )
            ? dispensingStatus
            : localDispensingStatus;

        final updatedPrescription = localEntry.prescription.copyWith(
          patientName: p.patientName,
          patientAge: p.patientAge,
          patientGender: p.patientGender,
          doctorName: p.doctorName,
          licenseNo: p.licenseNo,
          ptNo: p.ptNo,
          s2: p.s2,
          patientAddress: p.patientAddress,
          dateTime: p.dateTime,
          medicines: medicines,
          totalPrice: p.totalPrice,
          status: status,
          dispensingStatus: effectiveDispensingStatus,
          pharmacyId: p.pharmacyId ?? '',
        );

        final updatedEntry = localEntry.copyWith(
          prescription: updatedPrescription,
          imageUrl: p.imageUrl,
          qrToken: p.qrToken,
          // Deliberately NOT reconstructing backendVerifyUrl from
          // p.qrToken (token_id) here. The server only ever stores the
          // token's hash, never the raw secret, so it's impossible to
          // rebuild a correct verify URL after the fact — and the backend
          // now rejects a bare token_id outright, so a reconstructed URL
          // would be a broken QR, not just a weaker one. Omitting this
          // field lets copyWith's `?? this.backendVerifyUrl` preserve
          // whatever correct URL was set by updateQrToken() earlier in
          // this session, instead of clobbering it every refresh.
          backendId: p.id,
          patientId: p.patientId,
          rawExtractedText: p.rawExtractedText ?? localEntry.rawExtractedText,
        );

        _items[existingIdx] = updatedEntry;
      } else {
        // Insert new entry from backend
        final medicines = p.items
            .map(
              (i) => MedicineItem(
                name: i.name,
                originalOcrName: i.originalOcrName ?? '',
                genericName: i.genericName ?? i.name,
                brand: i.brandName ?? '',
                dosage: i.dosage ?? '',
                quantity: i.quantity,
                disposedQuantity: i.disposedQuantity,
                unitPrice: i.unitPrice,
                isEssential: i.isEssential,
                duration: i.duration ?? '',
                daysSupply: i.daysSupply,
                availableStock: i.availableStock,
              ),
            )
            .toList();

        final status = p.status == 'qr_generated'
            ? QrStatus.qrGenerated
            : QrStatus.pendingQr;
        final dispensingStatus = _parseDispensingStatus(p.dispensingStatus);

        final prescription = Prescription(
          patientName: p.patientName,
          patientAge: p.patientAge,
          patientGender: p.patientGender,
          isSenior: p.isSenior,
          oscaId: p.oscaId,
          doctorName: p.doctorName,
          licenseNo: p.licenseNo,
          ptNo: p.ptNo,
          s2: p.s2,
          patientAddress: p.patientAddress,
          ocrCode: p.ocrCode,
          pharmacyId: p.pharmacyId ?? '',
          dateTime: p.dateTime,
          medicines: medicines,
          totalPrice: p.totalPrice,
          status: status,
          dispensingStatus: dispensingStatus,
        );

        final entry = PrescriptionEntry(
          ocrCode: p.ocrCode,
          imageBytes: Uint8List(0),
          imageUrl: p.imageUrl,
          rawExtractedText: p.rawExtractedText ?? '',
          prescription: prescription,
          qrToken: p.qrToken,
          // No backendVerifyUrl here — this is a brand-new local entry
          // with no prior session state, and (see note above) the server
          // cannot supply a working verify URL after the fact. The QR
          // panel falls back to its local-payload display until a fresh
          // token is generated for this prescription.
          backendId: p.id,
          patientId: p.patientId,
        );

        _items.add(entry);
      }
    }

    _items.sort(
      (a, b) => b.prescription.dateTime.compareTo(a.prescription.dateTime),
    );
  }

  Future<void> _fetchAdherenceForAll() async {
    final uniquePatientIds = _items
        .where((e) => e.patientId != null && e.patientId!.isNotEmpty)
        .map((e) => e.patientId!)
        .toSet()
        .toList();

    // Was a sequential await-per-patient loop — one of the two N+1 chains
    // that made the dashboard/Saved Rx/Dispense screens slow right after
    // login. Running every patient's fetch concurrently instead cuts this
    // from O(patients) sequential round trips to one. Each iteration's
    // _items mutation happens synchronously right after its own await with
    // nothing else awaited in between, so concurrent completions can't
    // interleave and corrupt shared state (Dart's single-threaded event
    // loop). Per-patient failures are still isolated exactly as before —
    // one patient's failed fetch doesn't affect any other's.
    await Future.wait(
      uniquePatientIds.map((pid) async {
        try {
          final statusJson = await _api.fetchPatientAdherence(pid);
          debugPrint(
            'STORE: patient=$pid adherence keys=${statusJson.keys.toList()}',
          );
          debugPrint(
            'STORE: patient=$pid has medications=${statusJson['medications'] != null || statusJson['items'] != null} has refill_history=${statusJson['refill_history'] != null || statusJson['refillHistory'] != null || statusJson['dispensing_history'] != null || statusJson['dispensing_history'] != null}',
          );
          final adherence = AdherenceStatus.fromJson(statusJson);
          debugPrint(
            'STORE: patient=$pid medNames=${adherence.medicationNames} refillCount=${adherence.refillHistory.length} score=${adherence.score} hasData=${adherence.hasData}',
          );
          // Write the single fetched result back to EVERY Saved Rx entry for
          // this patient, not just the first — indexWhere() only matched one,
          // so a patient's 2nd/3rd prescription kept adherence == null and the
          // list screen hid its adherence badge.
          for (var i = 0; i < _items.length; i++) {
            if (_items[i].patientId == pid) {
              _items[i] = _items[i].copyWith(adherence: adherence);
            }
          }
        } catch (e) {
          debugPrint('STORE: patient=$pid adherence fetch failed: $e');
        }
      }),
    );
  }

  static DispensingStatus _parseDispensingStatus(String? value) {
    switch (value) {
      case 'fully_dispensed':
        return DispensingStatus.fullyDispensed;
      case 'partially_dispensed':
        return DispensingStatus.partiallyDispensed;
      case 'over_dispensing':
        return DispensingStatus.overDispensing;
      default:
        if (value != null && value.isNotEmpty) {
          debugPrint('Unknown dispensing_status from backend: $value');
        }
        return DispensingStatus.pending;
    }
  }

  static bool _isForwardDispensingProgression(
    DispensingStatus local,
    DispensingStatus backend,
  ) {
    if (local == backend) return true;
    if (local == DispensingStatus.pending) return true;
    if (local == DispensingStatus.partiallyDispensed &&
        backend == DispensingStatus.fullyDispensed) {
      return true;
    }
    return false;
  }

  static DispensingStatus effectiveDispensingStatus(Prescription prescription) {
    if (prescription.dispensingStatus != DispensingStatus.pending) {
      return prescription.dispensingStatus;
    }
    return computeDispensingStatus(prescription.medicines);
  }

  static DispensingStatus computeDispensingStatus(
    List<MedicineItem> medicines,
  ) {
    if (medicines.isEmpty) {
      return DispensingStatus.pending;
    }
    bool anyDispensed = false;
    bool allFullyDispensed = true;
    bool anyOverDispensed = false;
    for (final m in medicines) {
      final dispensed = m.disposedQuantity;
      final prescribed = m.quantity;
      if (dispensed > 0) {
        anyDispensed = true;
      }
      if (dispensed < prescribed) {
        allFullyDispensed = false;
      }
      if (dispensed > prescribed) {
        anyOverDispensed = true;
      }
    }
    if (anyOverDispensed) {
      return DispensingStatus.overDispensing;
    }
    if (allFullyDispensed && anyDispensed) {
      return DispensingStatus.fullyDispensed;
    }
    if (anyDispensed) {
      return DispensingStatus.partiallyDispensed;
    }
    return DispensingStatus.pending;
  }
}

class PrescriptionEntry {
  final String ocrCode;
  final Uint8List imageBytes;
  final String? imageUrl;
  final String rawExtractedText;
  final Prescription prescription;
  final String? qrData;
  final String? qrToken;
  final String? backendVerifyUrl;
  final String? backendId;
  final String? patientId;
  final AdherenceStatus? adherence;

  const PrescriptionEntry({
    required this.ocrCode,
    required this.imageBytes,
    this.imageUrl,
    required this.rawExtractedText,
    required this.prescription,
    this.qrData,
    this.qrToken,
    this.backendVerifyUrl,
    this.backendId,
    this.patientId,
    this.adherence,
  });

  PrescriptionEntry copyWith({
    Uint8List? imageBytes,
    String? imageUrl,
    String? rawExtractedText,
    Prescription? prescription,
    String? qrData,
    String? qrToken,
    String? backendVerifyUrl,
    String? backendId,
    String? patientId,
    AdherenceStatus? adherence,
  }) {
    return PrescriptionEntry(
      ocrCode: ocrCode,
      imageBytes: imageBytes ?? this.imageBytes,
      imageUrl: imageUrl ?? this.imageUrl,
      rawExtractedText: rawExtractedText ?? this.rawExtractedText,
      prescription: prescription ?? this.prescription,
      qrData: qrData ?? this.qrData,
      qrToken: qrToken ?? this.qrToken,
      backendVerifyUrl: backendVerifyUrl ?? this.backendVerifyUrl,
      backendId: backendId ?? this.backendId,
      patientId: patientId ?? this.patientId,
      adherence: adherence ?? this.adherence,
    );
  }
}
