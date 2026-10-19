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

  void _removeRequest(String requestId) {
    if (!mounted) return;
    setState(
      () =>
          _requests = _requests.where((r) => r.requestId != requestId).toList(),
    );
  }

  // Replaces (or appends) a single request in _requests without touching
  // _loading — the surrounding list stays visible, only the one card
  // updates. Used after a successful approve/flag/reject so those actions
  // no longer blank the whole screen just to reflect one row's new status.
  void _patchRequest(CrossPharmacyRequestResponse updated) {
    if (!mounted) return;
    setState(() {
      final idx = _requests.indexWhere((r) => r.requestId == updated.requestId);
      // Builds a new list instead of writing into _requests in place, which
      // throws if the list from the API/poll is unmodifiable.
      _requests = idx != -1
          ? [
              for (var i = 0; i < _requests.length; i++)
                i == idx ? updated : _requests[i],
            ]
          : [..._requests, updated];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            children: [
              // Header lives in the centered column (not an AppBar) so the
              // title and controls line up with the list on wide screens.
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Requests',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      _buildDateDropdown(),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(
                          Icons.refresh,
                          color: AppColors.textPrimary,
                        ),
                        tooltip: 'Refresh',
                        onPressed: _loading ? null : _load,
                      ),
                    ],
                  ),
                ),
              ),
              _buildFilterBar(),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  // Display-only filter chips. Always visible — sits above the body so it
  // stays on screen during loading / error / empty / filtered states.
  Widget _buildFilterBar() {
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final f in _RequestFilter.values) ...[
              () {
                final selected = _filter == f;
                return ChoiceChip(
                  showCheckmark: false,
                  label: Text(f.label),
                  selected: selected,
                  onSelected: (_) => setState(() => _filter = f),
                  backgroundColor: AppColors.bg,
                  selectedColor: f.selectedColor,
                  side: selected
                      ? BorderSide.none
                      : BorderSide(
                          color: AppColors.textSecondary.withValues(alpha: 0.4),
                        ),
                  labelStyle: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : AppColors.textSecondary,
                  ),
                );
              }(),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }

  // Today / This Week / This Month selector — lives in the AppBar, to the
  // left of the refresh icon. Purely a display filter over the
  // already-loaded _requests; changing it issues no API request.
  Widget _buildDateDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.textSecondary.withValues(alpha: 0.3),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<_RequestDateFilter>(
          value: _dateFilter,
          isDense: true,
          icon: const Icon(
            Icons.keyboard_arrow_down,
            size: 18,
            color: AppColors.teal,
          ),
          borderRadius: BorderRadius.circular(12),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.teal,
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
      // Requests exist, just none match the filters — say which filters are
      // hiding them and offer the widest view instead of a bare message.
      final statusPart = _filter == _RequestFilter.all
          ? ''
          : '${_filter.label.toLowerCase()} ';
      final canWiden =
          _filter != _RequestFilter.all ||
          _dateFilter != _RequestDateFilter.month;
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(
                  color: AppColors.tealPale,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.filter_alt_off_outlined,
                  color: AppColors.teal,
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'No requests found',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'There are no ${statusPart}requests for '
                '${_dateFilter.label.toLowerCase()}.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
              if (canWiden) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => setState(() {
                    _filter = _RequestFilter.all;
                    _dateFilter = _RequestDateFilter.month;
                  }),
                  icon: const Icon(Icons.calendar_month_outlined, size: 18),
                  label: const Text('Show all this month'),
                ),
              ],
            ],
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
                onDeleted: _removeRequest,
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
  final ValueChanged<String> onDeleted;

  const _RequestCard({
    super.key,
    required this.request,
    required this.api,
    required this.onUpdated,
    required this.onActionFailed,
    required this.onDeleted,
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
      // The card keeps its State across the status change (same key),
      // so clear the spinner or the next button (e.g. Delete) stays stuck.
      setState(() => _acting = false);
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
      // The card keeps its State across the status change (same key),
      // so clear the spinner or the next button (e.g. Delete) stays stuck.
      setState(() => _acting = false);
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

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete request?'),
        content: Text(
          'Remove the request for ${widget.request.patientName} '
          '(${widget.request.rxNumber}) from this list? Its audit record '
          'and any alerts are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _acting = true);
    try {
      await widget.api.deleteCrossPharmacyRequest(widget.request.requestId);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Request deleted.')));
      widget.onDeleted(widget.request.requestId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _acting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: AppColors.danger,
        ),
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
      // The card keeps its State across the status change (same key),
      // so clear the spinner or the next button (e.g. Delete) stays stuck.
      setState(() => _acting = false);
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

    final submittedBy =
        'Submitted by ${request.dispensedBy ?? request.requestingStaffName}'
        '${_formatWhen(request.dispensedAt)}';

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.tealPale,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.local_pharmacy_outlined,
                  color: AppColors.teal,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.requestingPharmacyName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 14,
                      runSpacing: 4,
                      children: [
                        if (request.requestingPharmacyLocation.isNotEmpty)
                          _MetaItem(
                            icon: Icons.place_outlined,
                            text: request.requestingPharmacyLocation,
                          ),
                        if (request.requestingPharmacyLicense.isNotEmpty)
                          _MetaItem(
                            icon: Icons.verified_outlined,
                            text:
                                'FDA License No. ${request.requestingPharmacyLicense}',
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _StatusBadge(status: request.status),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.person_outline_rounded,
                        size: 18,
                        color: AppColors.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          request.patientName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Text(
                          request.rxNumber,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: AppColors.border),
                for (final m in request.medicines)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.medication_outlined,
                          size: 17,
                          color: AppColors.teal,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${m.name}'
                            '${m.brand.trim().isNotEmpty ? ' (${m.brand.trim()})' : ''}'
                            '${m.dosage.trim().isNotEmpty ? ' ${m.dosage.trim()}' : ''}',
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.tealPale,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '× ${m.quantity} claimed',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: AppColors.teal,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
              ],
            ),
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
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final submitted = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.badge_outlined,
                    size: 15,
                    color: AppColors.textFaint,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      submittedBy,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              );
              if (!isActionable) {
                return Row(
                  children: [
                    Expanded(child: submitted),
                    const SizedBox(width: 12),
                    _actionButton(
                      label: 'Delete',
                      icon: Icons.delete_outline_rounded,
                      color: AppColors.danger,
                      onPressed: _delete,
                      expand: false,
                    ),
                  ],
                );
              }
              final wide = constraints.maxWidth >= 620;
              final buttons = [
                _actionButton(
                  label: 'Reject',
                  icon: Icons.close_rounded,
                  color: AppColors.textSecondary,
                  onPressed: _reject,
                  expand: !wide,
                ),
                const SizedBox(width: 10),
                _actionButton(
                  label: 'Flag as risk',
                  icon: Icons.flag_outlined,
                  color: AppColors.danger,
                  onPressed: _flagAsRisk,
                  expand: !wide,
                ),
                const SizedBox(width: 10),
                _actionButton(
                  label: 'Approve',
                  icon: Icons.check_rounded,
                  color: AppColors.teal,
                  onPressed: _approve,
                  filled: true,
                  expand: !wide,
                ),
              ];
              if (wide) {
                return Row(
                  children: [
                    Expanded(child: submitted),
                    const SizedBox(width: 12),
                    ...buttons,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  submitted,
                  const SizedBox(height: 12),
                  Row(children: buttons),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  static String _formatWhen(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final parsed = DateTime.tryParse(raw);
    return ' · ${parsed != null ? formatPhilippineDateTime(parsed) : raw}';
  }

  Widget _actionButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
    required bool expand,
    bool filled = false,
  }) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    const padding = EdgeInsets.symmetric(horizontal: 16, vertical: 12);
    const textStyle = TextStyle(fontWeight: FontWeight.w700, fontSize: 13);
    final Widget child = _acting
        ? SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: filled ? Colors.white : color,
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: textStyle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          );
    final Widget button = filled
        ? ElevatedButton(
            onPressed: _acting ? null : onPressed,
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: padding,
              shape: shape,
            ),
            child: child,
          )
        : OutlinedButton(
            onPressed: _acting ? null : onPressed,
            style: OutlinedButton.styleFrom(
              foregroundColor: color,
              side: BorderSide(color: color.withValues(alpha: 0.6)),
              padding: padding,
              shape: shape,
            ),
            child: child,
          );
    return expand ? Expanded(child: button) : button;
  }
}

class _MetaItem extends StatelessWidget {
  final IconData icon;
  final String text;
  const _MetaItem({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppColors.textFaint),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12.5,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
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
