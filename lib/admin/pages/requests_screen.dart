import 'dart:async';
import 'package:flutter/material.dart';
import '../../../admin/data/admin_api_service.dart';
import '../../../admin/models/admin_models.dart';
import '../../../common/theme/app_colors.dart';
import '../../../common/utils/ph_time.dart';
import '../../../common/widgets/responsive_center.dart';

// Display-only filter for the Requests list. Each option maps to an existing
// RequestStatus — "Approved" is only a UI label; internally it filters on the
// existing `dispensed` status (there is no separate approved state applied to
// cross-pharmacy requests). `all` shows every existing card unchanged.
enum _RequestFilter { all, rejected, flagged, approved }

extension _RequestFilterLabel on _RequestFilter {
  String get label {
    switch (this) {
      case _RequestFilter.all:
        return 'All';
      case _RequestFilter.rejected:
        return 'Rejected';
      case _RequestFilter.flagged:
        // Filter chip label only — the request-card action stays "Flag as risk".
        return 'Flagged';
      case _RequestFilter.approved:
        return 'Approved';
    }
  }

  // Background colour for this chip when it is the selected filter. Inactive
  // chips are always neutral (see _buildFilterBar).
  Color get selectedColor {
    switch (this) {
      case _RequestFilter.all:
        return AppColors.textPrimary;
      case _RequestFilter.rejected:
        return AppColors.danger;
      case _RequestFilter.flagged:
        return AppColors.warning;
      case _RequestFilter.approved:
        return AppColors.success;
    }
  }

  // Returns true if the given request should be shown under this filter.
  // Does not touch the request — pure predicate over the existing status.
  bool matches(CrossPharmacyRequestResponse r) {
    switch (this) {
      case _RequestFilter.all:
        return true;
      case _RequestFilter.rejected:
        return r.status == RequestStatus.rejected;
      case _RequestFilter.flagged:
        return r.status == RequestStatus.flagged;
      case _RequestFilter.approved:
        return r.status == RequestStatus.dispensed;
    }
  }
}

// Client-side date filter, applied on top of the status filter. Compares
// the request's creation date in Philippine time (see toPhilippineTime) —
// never the device's local timezone — so a request lands in the right
// Today/Week/Month bucket regardless of how the tablet's clock is set.
// There is deliberately no "All dates" option.
enum _RequestDateFilter { today, week, month }

extension _RequestDateFilterLabel on _RequestDateFilter {
  String get label {
    switch (this) {
      case _RequestDateFilter.today:
        return 'Today';
      case _RequestDateFilter.week:
        return 'This Week';
      case _RequestDateFilter.month:
        return 'This Month';
    }
  }

  bool matches(CrossPharmacyRequestResponse r) {
    final createdAt = r.createdAt;
    if (createdAt == null) return false;

    final nowPh = toPhilippineTime(DateTime.now());
    final createdPh = toPhilippineTime(createdAt);

    switch (this) {
      case _RequestDateFilter.today:
        return createdPh.year == nowPh.year &&
            createdPh.month == nowPh.month &&
            createdPh.day == nowPh.day;
      case _RequestDateFilter.week:
        // Sunday-start week, matching the home dashboard: Dart weekday is
        // Mon=1..Sun=7, so weekday % 7 is Sun=0..Sat=6 — the number of days
        // to step back to reach this week's Sunday.
        final todayPh = DateTime(nowPh.year, nowPh.month, nowPh.day);
        final weekStart = todayPh.subtract(Duration(days: nowPh.weekday % 7));
        final weekEnd = weekStart.add(const Duration(days: 7)); // exclusive
        final createdDate = DateTime(
          createdPh.year,
          createdPh.month,
          createdPh.day,
        );
        return !createdDate.isBefore(weekStart) &&
            createdDate.isBefore(weekEnd);
      case _RequestDateFilter.month:
        return createdPh.year == nowPh.year && createdPh.month == nowPh.month;
    }
  }
}

class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key});

  @override
  RequestsScreenState createState() => RequestsScreenState();
}

// State is public so the parent AdminDashboardPage can hold a
// GlobalKey<RequestsScreenState> and trigger a silent refresh when the
// Requests tab becomes active again (the screen is kept alive in an
// IndexedStack, so initState() only ever runs once).
class RequestsScreenState extends State<RequestsScreen> {
  final AdminApiService _api = AdminApiService();
  List<CrossPharmacyRequestResponse> _requests = [];

  // Display-only: which existing cards are rendered. Lives here (alongside
  // _requests/_loading/_error) so it persists across body state changes.
  _RequestFilter _filter = _RequestFilter.all;
  // Date filter — defaults to Today. Lives here alongside _filter/_requests
  // so it persists across body state changes. Client-side only; changing it
  // never triggers an API request.
  _RequestDateFilter _dateFilter = _RequestDateFilter.today;

  bool _loading = true;
  String? _error;
  Timer? _pollTimer;
  // Guards _silentRefresh() so a tab-activation refresh and a 30s poll tick
  // firing close together don't issue two overlapping list requests.
  bool _refreshInFlight = false;

  @override
  void initState() {
    super.initState();
    _load();
    // This screen lives inside an IndexedStack (see admin_dashboard_page.dart)
    // which keeps it mounted forever once built, so initState()/_load() only
    // ever fire once — a new request submitted by another pharmacy would
    // never appear without this. Mirrors the same polling pattern already
    // used for alerts on the dashboard page.
    _pollTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _silentRefresh(),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final requests = await _api.fetchCrossPharmacyRequests();
      if (!mounted) return;
      setState(() {
        _requests = requests;
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

  // Background refresh — no loading spinner, no error banner, so a
  // transient network hiccup during a periodic tick doesn't interrupt
  // whatever the admin is doing on screen.
  Future<void> _silentRefresh() async {
    // Skip if the initial full load or another silent refresh is already
    // running — the in-flight request will deliver the latest data.
    if (_loading || _refreshInFlight) return;
    _refreshInFlight = true;
    try {
      final requests = await _api.fetchCrossPharmacyRequests();
      if (!mounted) return;
      setState(() => _requests = requests);
    } catch (_) {
      // Ignore — the next periodic tick or manual refresh will retry.
    } finally {
      _refreshInFlight = false;
    }
  }

  /// Called by the parent dashboard (via GlobalKey) when the Requests tab
  /// becomes active again. Uses the same silent-refresh semantics as the
  /// 30s poll: the current list stays visible, no full-screen spinner, and
  /// the data is swapped in when the request completes.
  void refreshOnTabActivated() {
    _silentRefresh();
  }

  void _retry() => _load();

  // Replaces (or appends) a single request in _requests without touching
  // _loading — the surrounding list stays visible, only the one card
  // updates. Used after a successful approve/flag/reject so those actions
  // no longer blank the whole screen just to reflect one row's new status.
  void _patchRequest(CrossPharmacyRequestResponse updated) {
    if (!mounted) return;
    setState(() {
      final idx = _requests.indexWhere((r) => r.requestId == updated.requestId);
      if (idx != -1) {
        _requests[idx] = updated;
      } else {
        _requests = [..._requests, updated];
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: const Text(
          'Requests',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.textPrimary),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildFilterBar(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  // Display-only filter chips. Always visible — sits above the body so it
  // stays on screen during loading / error / empty / filtered states.
  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
      child: Row(
        children: [
          // Status chips scroll horizontally if they overflow; the date
          // dropdown stays pinned on the right, outside that scroll area.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final f in _RequestFilter.values) ...[
                    () {
                      final selected = _filter == f;
                      // Client-side counts from the already-loaded list — no
                      // extra API calls, recomputed on every build so they
                      // track _requests automatically. Deliberately NOT
                      // affected by the selected date filter.
                      final count = _requests.where(f.matches).length;
                      return ChoiceChip(
                        label: Text('${f.label} $count'),
                        selected: selected,
                        onSelected: (_) => setState(() => _filter = f),
                        backgroundColor: AppColors.bg,
                        selectedColor: f.selectedColor,
                        side: selected
                            ? BorderSide.none
                            : BorderSide(
                                color: AppColors.textSecondary.withValues(
                                  alpha: 0.4,
                                ),
                              ),
                        labelStyle: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: selected
                              ? Colors.white
                              : AppColors.textSecondary,
                        ),
                      );
                    }(),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          _buildDateDropdown(),
        ],
      ),
    );
  }

  // Today / This Week / This Month selector — sits to the right of the
  // status chips. Purely a display filter over the already-loaded
  // _requests; changing it issues no API request.
  Widget _buildDateDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.textSecondary.withValues(alpha: 0.4),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<_RequestDateFilter>(
          value: _dateFilter,
          isDense: true,
          icon: const Icon(
            Icons.arrow_drop_down,
            size: 20,
            color: AppColors.textSecondary,
          ),
          borderRadius: BorderRadius.circular(12),
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
          items: [
            for (final d in _RequestDateFilter.values)
              DropdownMenuItem(value: d, child: Text(d.label)),
          ],
          onChanged: (d) {
            if (d != null) setState(() => _dateFilter = d);
          },
        ),
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
              const Icon(
                Icons.error_outline,
                size: 48,
                color: AppColors.danger,
              ),
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

    if (_requests.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child: Icon(
                  Icons.notifications_none,
                  color: AppColors.teal,
                  size: 30,
                ),
              ),
              SizedBox(height: 16),
              Text(
                'No requests yet',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: AppColors.textPrimary,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Cross-pharmacy dispenses will appear here.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    // Display-only: pick which existing cards to render. Both the status
    // filter and the date filter are applied; the request objects in
    // _requests are not touched.
    final visible = _requests
        .where(_filter.matches)
        .where(_dateFilter.matches)
        .toList();

    if (visible.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            'No requests found',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: AppColors.teal,
      child: ResponsiveCenter.dashboard(
        padding: EdgeInsets.zero,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            ...visible.map(
              (r) => _RequestCard(
                key: ValueKey(r.requestId),
                request: r,
                api: _api,
                onUpdated: _patchRequest,
                onActionFailed: _silentRefresh,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// A cross-pharmacy request starts 'pending' (staged, nothing applied to the
// prescription yet) and either becomes 'dispensed' via Approve or 'flagged'
// via Flag as risk — there is no reject/decline action, so a flagged
// request stays actionable and can still be approved later. See
// CrossPharmacyDispenseService::stage()/approve()/flag() on the backend.
class _RequestCard extends StatefulWidget {
  final CrossPharmacyRequestResponse request;
  final AdminApiService api;
  final ValueChanged<CrossPharmacyRequestResponse> onUpdated;
  final VoidCallback onActionFailed;

  const _RequestCard({
    super.key,
    required this.request,
    required this.api,
    required this.onUpdated,
    required this.onActionFailed,
  });

  @override
  State<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends State<_RequestCard> {
  bool _acting = false;

  Future<void> _approve() async {
    setState(() => _acting = true);
    try {
      final updated = await widget.api.approveCrossPharmacyRequest(
        widget.request.requestId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Request approved and applied.')),
      );
      if (updated != null) {
        widget.onUpdated(updated);
      } else {
        widget.onActionFailed();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _acting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: AppColors.danger),
      );
      // A blocked approve leaves the request exactly as it was (still
      // pending) — reconcile anyway (without a full-screen reload) so the
      // card reflects anything else that may have changed (e.g. another
      // admin acted on it concurrently).
      widget.onActionFailed();
    }
  }

  Future<void> _flagAsRisk() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _FlagReasonDialog(
        title: 'Flag as risk',
        description:
            'The medication was actually dispensed, but this claim '
            'creates an over-dispense condition. The prescription will be '
            'reconciled and this will be logged as an audit alert. Describe '
            'the concern:',
        hintText: 'e.g. dispensed before the home pharmacy could review',
        confirmLabel: 'Flag',
      ),
    );
    if (reason == null || reason.trim().isEmpty) return;

    setState(() => _acting = true);
    try {
      final updated = await widget.api.flagCrossPharmacyRequest(
        widget.request.requestId,
        reason.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Request flagged as an over-dispense risk.'),
        ),
      );
      if (updated != null) {
        widget.onUpdated(updated);
      } else {
        widget.onActionFailed();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _acting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: AppColors.danger),
      );
    }
  }

  Future<void> _reject() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _FlagReasonDialog(
        title: 'Reject request',
        description:
            'This request will be denied outright — the '
            'prescription is not touched. Describe why:',
        hintText: 'e.g. unrecognized pharmacy, suspicious claim',
        confirmLabel: 'Reject',
      ),
    );
    if (reason == null || reason.trim().isEmpty) return;

    setState(() => _acting = true);
    try {
      final updated = await widget.api.rejectCrossPharmacyRequest(
        widget.request.requestId,
        reason.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Request rejected.')));
      if (updated != null) {
        widget.onUpdated(updated);
      } else {
        widget.onActionFailed();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _acting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: AppColors.danger),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final isFlagged = request.status == RequestStatus.flagged;
    final isRejected = request.status == RequestStatus.rejected;
    final isActionable = request.status == RequestStatus.pending;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  request.requestingPharmacyName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              _StatusBadge(status: request.status),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            request.requestingPharmacyLocation,
            style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
          ),
          if (request.requestingPharmacyLicense.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              'FDA License No. ${request.requestingPharmacyLicense}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${request.patientName} · ${request.rxNumber}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                for (final m in request.medicines)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${m.name} × ${m.quantity} claimed',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.teal,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Submitted by: ${request.dispensedBy ?? request.requestingStaffName}'
            '${request.dispensedAt != null ? ' · ${request.dispensedAt}' : ''}',
            style: TextStyle(fontSize: 11.5, color: AppColors.textFaint),
          ),
          if ((isFlagged || isRejected) && request.rejectionReason != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isRejected ? AppColors.redLight : AppColors.amberLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${isRejected ? 'Rejected' : 'Flagged'}: ${request.rejectionReason}',
                style: TextStyle(
                  fontSize: 12,
                  color: isRejected ? AppColors.danger : AppColors.warning,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          if (request.wouldExceedRemaining &&
              request.exceedDetails.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.redLight,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: AppColors.danger.withValues(alpha: 0.2),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.block, size: 16, color: AppColors.danger),
                      SizedBox(width: 6),
                      Text(
                        'OVERDISPENSING RISK',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.danger,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final d in request.exceedDetails)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${d.medicine}: this request wants ${d.requested}, another '
                        'pending request wants ${d.otherPending} — combined that\'s '
                        'more than the ${d.remaining} remaining on this prescription.',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.redDark,
                          height: 1.4,
                        ),
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    'Approving will record only the remaining amount and flag this '
                    'request as a critical over-dispense attempt for audit.',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.redDark.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (isActionable) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _acting ? null : _reject,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                      side: BorderSide(color: AppColors.textSecondary),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: _acting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.textSecondary,
                            ),
                          )
                        : const Text(
                            'Reject',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _acting ? null : _flagAsRisk,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      side: const BorderSide(color: AppColors.danger),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: _acting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.danger,
                            ),
                          )
                        : const Text(
                            'Flag as risk',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _acting ? null : _approve,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.teal,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: _acting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'Approve',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _FlagReasonDialog extends StatefulWidget {
  const _FlagReasonDialog({
    required this.title,
    required this.description,
    required this.hintText,
    required this.confirmLabel,
  });

  final String title;
  final String description;
  final String hintText;
  final String confirmLabel;

  @override
  State<_FlagReasonDialog> createState() => _FlagReasonDialogState();
}

class _FlagReasonDialogState extends State<_FlagReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        widget.title,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.description,
            style: const TextStyle(
              fontSize: 12.5,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: widget.hintText,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.danger,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final RequestStatus status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    late Color bg;
    late Color fg;
    late String label;
    switch (status) {
      case RequestStatus.pending:
        bg = AppColors.amberLight;
        fg = AppColors.warning;
        label = 'Pending';
        break;
      case RequestStatus.approved:
        bg = AppColors.greenLight;
        fg = AppColors.success;
        label = 'Approved';
        break;
      case RequestStatus.rejected:
        bg = AppColors.redLight;
        fg = AppColors.danger;
        label = 'Rejected';
        break;
      case RequestStatus.flagged:
        bg = AppColors.redLight;
        fg = AppColors.danger;
        label = 'Flagged';
        break;
      case RequestStatus.dispensed:
        bg = AppColors.tealPale;
        fg = AppColors.teal;
        label = 'Dispensed';
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}
