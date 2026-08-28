import 'dart:async';

import 'package:flutter/material.dart';

import '../../common/models/dashboard_models.dart';
import '../../common/services/dashboard_repository.dart';
import '../../common/session.dart';
import '../../common/theme/app_colors.dart';
import '../../common/utils/ph_time.dart';
import '../../common/widgets/bottom_nav_bar.dart';
import '../../common/widgets/responsive_center.dart';
import '../data/saved_prescriptions_store.dart';
import '../models/prescription.dart';
import 'functional_qr_scanner_screen.dart';
import 'ocr_scan_screen.dart';
import 'saved_prescriptions_list_screen.dart';
import 'patient_adherence_screen.dart';
import 'dispense_screen.dart';
import '../../login_screen.dart';
import '../services/prescription_api_service.dart';
import 'alerts_dashboard_screen.dart';
import 'change_password_screen.dart';

class HomeDashboardScreen extends StatefulWidget {
  final String staffName;
  final String branchName;
  final String token;
  final String userType;

  const HomeDashboardScreen({
    super.key,
    this.staffName = '',
    this.branchName = '',
    this.token = '',
    this.userType = '',
  });

  @override
  State<HomeDashboardScreen> createState() => _HomeDashboardScreenState();
}

class _HomeDashboardScreenState extends State<HomeDashboardScreen> {
  int _navIndex = 0;

  // Saved Rx / Dispense / Patients (indices 2-4) used to be built
  // unconditionally in the IndexedStack below, so all three fired their own
  // network fetches the instant HomeDashboardScreen mounted — duplicating
  // work _loadAll() below was already doing concurrently, which is why the
  // dashboard was slow right after login. Deferring first construction
  // until a tab is actually visited fixes that; IndexedStack already keeps
  // every *built* child mounted permanently regardless of active index, so
  // once visited a tab stays cached for the rest of the session with no
  // extra keep-alive needed.
  final Set<int> _visitedTabs = {0};

  final DashboardRepository _repo = DashboardRepository();

  // Split from a single _isLoading bool so each dashboard section can
  // render as soon as its own fetch resolves, instead of the whole tab
  // waiting on the slowest of the three (fetchFromBackend(), which
  // internally awaits per-patient adherence data). No staff-loading flag
  // is needed — _buildHeader() already renders immediately from
  // widget.staffName/branchName while _staffProfile is still null, so
  // there's nothing for a staff section to gate on.
  bool _summaryLoading = true;
  bool _recentLoading = true;
  String? _errorMessage;

  DashboardSummary? _summary;
  StaffProfile? _staffProfile;
  // Staff profile doesn't change mid-shift — once fetched, silent 30s
  // polls skip re-fetching it; only a first load or explicit manual
  // refresh does.
  DateTime? _staffFetchedAt;

  String _selectedPeriod = 'month';
  DateTime? _dateFrom;
  DateTime? _dateTo;

  Timer? _pollTimer;

  // Transient post-login greeting: appears once the real name is known,
  // then fades out after ~1s. Never shows a "Pharmacist" placeholder.
  bool _welcomeStarted = false;
  bool _welcomeVisible = true;
  bool _welcomeMounted = true;

  // True only while a non-silent summary reload (initial load, manual
  // refresh, or a period-filter change) is in flight — drives a loading
  // indicator so a filter change never briefly shows stale/zeroed data
  // as if it were a real "no results" state.
  bool _summaryRefreshing = false;
  // A non-silent summary fetch finished but returned nothing — distinct
  // from a genuine zero so the UI can say "couldn't load" instead of "0".
  bool _summaryLoadFailed = false;

  @override
  void initState() {
    super.initState();
    // Mirror of the guard in AdminDashboardPage.initState() — nothing
    // currently routes a Pharmacist-table session here (login_screen.dart
    // decides by which tab was tapped, not by the server's real user_type),
    // but nothing prevented it either. Client-side only, not server-side
    // role enforcement.
    if (AppSession.instance.userType == 'pharmacist') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
        );
      });
      return;
    }
    _setDefaultMonthRange();
    _loadAll();
    _startPolling();
  }

  void _setDefaultMonthRange() {
    final now = DateTime.now();
    _dateFrom = DateTime(now.year, now.month, 1);
    _dateTo = DateTime(now.year, now.month + 1, 0);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _loadAll(silent: true);
    });
  }

  Future<void> _loadAll({bool silent = false, bool forceStaff = false}) async {
    if (!silent) {
      setState(() {
        _summaryLoading = true;
        _recentLoading = true;
        _errorMessage = null;
      });
    }

    final fromStr = _dateFrom != null ? _formatDateForApi(_dateFrom!) : null;
    final toStr = _dateTo != null ? _formatDateForApi(_dateTo!) : null;

    final summaryFuture =
        _safeCall(
          () => _repo.fetchSummary(
            period: _selectedPeriod,
            dateFrom: fromStr,
            dateTo: toStr,
          ),
        ).then((value) {
          if (!mounted) return;
          setState(() {
            // Keep the previous numbers on a failed fetch instead of
            // dropping to null (which renders as "0" everywhere and reads
            // like a real empty period). _summaryLoadFailed lets the row
            // show an explicit "couldn't load" only when there was never
            // any data to keep.
            if (value != null) {
              _summary = value;
              _summaryLoadFailed = false;
            } else {
              _summaryLoadFailed = _summary == null;
            }
            _summaryLoading = false;
            _summaryRefreshing = false;
          });
        });

    // Profile is static mid-session (see _staffFetchedAt) — skip the
    // network call entirely on a silent poll once it's already been
    // fetched once, instead of re-fetching all three every 30s.
    final shouldFetchStaff = forceStaff || _staffFetchedAt == null;
    final staffFuture = shouldFetchStaff
        ? _safeCall(() => _repo.fetchStaffProfile()).then((value) {
            if (!mounted || value == null) return;
            setState(() {
              _staffProfile = value;
              _staffFetchedAt = DateTime.now();
            });
          })
        : Future<void>.value();

    // Also used by the "Recent Prescriptions" section below — reuses the
    // same store/fetch already used by dispense_screen.dart and
    // saved_prescriptions_list_screen.dart rather than a new endpoint.
    // force: !silent so the initial load and a manual pull-to-refresh
    // always bypass the store's own TTL guard, while the 30s background
    // poll respects it.
    final recentFuture =
        _safeCall<void>(
          () => SavedPrescriptionsStore.instance.fetchFromBackend(
            force: !silent,
          ),
        ).then((_) {
          if (!mounted) return;
          setState(() => _recentLoading = false);
        });

    await Future.wait([summaryFuture, staffFuture, recentFuture]);
  }

  Future<T?> _safeCall<T>(Future<T> Function() call) async {
    try {
      return await call();
    } catch (_) {
      return null;
    }
  }

  Future<void> _onRefresh() async {
    setState(() => _errorMessage = null);
    await _loadAll(forceStaff: true);
  }

  String _getGreeting() {
    return 'Welcome';
  }

  /// The real staff name if we know it yet — from the just-completed
  /// login (AppSession) first, refined by the staff-profile fetch when it
  /// lands. Never a "Pharmacist" placeholder: returns null until a real
  /// name is available.
  String? get _resolvedName {
    final fromProfile = _staffProfile?.name.trim() ?? '';
    if (fromProfile.isNotEmpty) return fromProfile;
    final fromSession = (widget.staffName.isNotEmpty
            ? widget.staffName
            : (AppSession.instance.staffName ?? ''))
        .trim();
    return fromSession.isNotEmpty ? fromSession : null;
  }

  /// Kicks off the one-shot fade of the post-login greeting the first
  /// time a real name is available. Safe to call from build().
  void _maybeScheduleWelcomeFade() {
    if (_welcomeStarted || _resolvedName == null) return;
    _welcomeStarted = true;
    Future.delayed(const Duration(milliseconds: 1000), () {
      if (!mounted) return;
      setState(() => _welcomeVisible = false);
      Future.delayed(const Duration(milliseconds: 450), () {
        if (!mounted) return;
        setState(() => _welcomeMounted = false);
      });
    });
  }

  Widget _buildWelcomeBanner() {
    final name = _resolvedName;
    if (!_welcomeMounted || name == null) return const SizedBox.shrink();
    return AnimatedOpacity(
      opacity: _welcomeVisible ? 1 : 0,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.tealPale,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Icon(Icons.waving_hand_outlined,
                  size: 16, color: AppColors.teal),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Welcome, $name',
                  style: const TextStyle(
                    color: AppColors.teal,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _logout() async {
    AppSession.instance.clear();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  // Shift-assignment display removed: the backend never sends
  // shift_start/shift_end, so this always fell back to a hardcoded
  // placeholder ("8:00 AM – 5:00 PM") rather than real data.
  // String _getShiftLabel() {
  //   final profile = _staffProfile;
  //   if (profile != null &&
  //       profile.shiftStart.isNotEmpty &&
  //       profile.shiftEnd.isNotEmpty) {
  //     return 'Shift: ${profile.shiftStart} – ${profile.shiftEnd}';
  //   }
  //   return 'Shift: 8:00 AM – 5:00 PM';
  // }

  String _getTodaySubtitle() {
    final months = [
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
    final now = DateTime.now();
    final dayName = [
      'Sunday',
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
    ][now.weekday % 7];
    // Shift suffix removed along with _getShiftLabel() (see above).
    return '$dayName, ${now.day} ${months[now.month - 1]} ${now.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: IndexedStack(
          index: _navIndex,
          children: [
            _buildHomeTab(),
            // Built (and its camera started) only while this tab is
            // actually selected; switching away disposes it and stops
            // the camera. Swapping in a lightweight placeholder for the
            // other indices means the widget type changes and the old
            // scanner state — and its MobileScannerController — is torn
            // down, rather than sitting active off-screen forever.
            _navIndex == 1
                ? const FunctionalQrScannerScreen(showBackButton: false)
                : const SizedBox.shrink(),
            _visitedTabs.contains(2)
                ? const SavedPrescriptionsListScreen()
                : const SizedBox.shrink(),
            _visitedTabs.contains(3)
                ? const DispenseScreen()
                : const SizedBox.shrink(),
            _visitedTabs.contains(4)
                ? const PatientAdherenceScreen()
                : const SizedBox.shrink(),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildHomeTab() {
    _maybeScheduleWelcomeFade();
    return RefreshIndicator(
      onRefresh: _onRefresh,
      color: AppColors.teal,
      child: ResponsiveCenter.dashboard(
        padding: EdgeInsets.zero,
        // Nothing has ever loaded (all three fetches failed on first
        // load) — everything else is progressive, per-section loading
        // below, not a single whole-tab gate.
        child:
            _errorMessage != null &&
                _summary == null &&
                _staffProfile == null &&
                SavedPrescriptionsStore.instance.items.isEmpty
            ? _buildErrorState()
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                children: [
                  _buildWelcomeBanner(),
                  _buildHeader(),
                  const SizedBox(height: 10),
                  _buildPeriodToggle(),
                  const SizedBox(height: 14),
                  _buildStatRow(),
                  const SizedBox(height: 16),
                  _buildSectionLabel('PRESCRIPTION SCANNING'),
                  const SizedBox(height: 8),
                  _buildScanCardsRow(),
                  const SizedBox(height: 20),
                  _buildRecentPrescriptions(),
                  const SizedBox(height: 18),
                ],
              ),
      ),
    );
  }

  Widget _statShimmer() {
    return Row(
      children: List.generate(2, (_) {
        return Expanded(
          child: Container(
            height: 80,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        );
      }),
    );
  }

  Widget _recentShimmer() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 20,
          width: 120,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        const SizedBox(height: 10),
        Container(
          height: 160,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 44, color: AppColors.danger),
            const SizedBox(height: 10),
            Text(
              _errorMessage ?? 'Something went wrong',
              style: const TextStyle(color: AppColors.danger, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _onRefresh,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.teal,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    // Never a "Pharmacist" placeholder — _resolvedName is null until a
    // real name is known, and the greeting simply omits the name until
    // then ("Welcome" rather than "Welcome, Pharmacist").
    final name = _resolvedName;
    final greeting = name == null ? _getGreeting() : '${_getGreeting()}, $name';
    final branch = _staffProfile?.branchName ?? widget.branchName;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                branch,
                style: const TextStyle(
                  color: AppColors.textFaint,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                greeting,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _getTodaySubtitle(),
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
        PopupMenuButton<String>(
          offset: const Offset(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          icon: Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.teal.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.person_outline,
              color: AppColors.teal,
              size: 20,
            ),
          ),
          itemBuilder: (context) => [
            PopupMenuItem<String>(
              enabled: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name ?? 'Signed in',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    'Pharmacy Assistant',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  Text(
                    branch,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: 'change_password',
              child: Row(
                children: [
                  Icon(Icons.lock_outline, size: 18, color: AppColors.teal),
                  SizedBox(width: 10),
                  Text('Change Password'),
                ],
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: 'logout',
              child: Row(
                children: [
                  Icon(Icons.logout, size: 18, color: Colors.red),
                  SizedBox(width: 10),
                  Text(
                    'Log Out',
                    style: TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
          onSelected: (value) {
            if (value == 'logout') _logout();
            if (value == 'change_password') {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ChangePasswordScreen()),
              );
            }
          },
        ),
      ],
    );
  }

  Widget _buildStatRow() {
    // Show the loading state for the first load AND for a period-filter
    // change / manual refresh — never leave stale or zeroed numbers on
    // screen while a new range is being fetched.
    if (_summaryLoading || _summaryRefreshing) {
      return _statShimmer();
    }
    if (_summary == null && _summaryLoadFailed) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.cloud_off_outlined,
              size: 18,
              color: AppColors.textFaint,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "Couldn't load stats for this period — pull down to refresh.",
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final rxLabel = switch (_selectedPeriod) {
      'today' => 'Rx Today',
      'week' => 'Rx This Week',
      'month' => 'Rx This Month',
      _ => 'Rx Today',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _statCard(
                icon: Icons.description_outlined,
                iconColor: AppColors.teal,
                iconBg: AppColors.tealPale,
                value: '${_summary?.rxCount ?? 0}',
                valueColor: AppColors.teal,
                label: rxLabel,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _statCard(
                icon: Icons.warning_amber_rounded,
                iconColor: AppColors.danger,
                iconBg: AppColors.dangerBg,
                value: '${_summary?.activeAlerts ?? 0}',
                valueColor: AppColors.danger,
                label: 'Active Alerts',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AlertsDashboardScreen(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPeriodToggle() {
    final periods = [
      {'value': 'today', 'label': 'Today'},
      {'value': 'week', 'label': 'This Week'},
      {'value': 'month', 'label': 'This Month'},
    ];

    return Align(
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: periods.map((p) {
          final selected = _selectedPeriod == p['value'];
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              onTap: () => _onPeriodChanged(p['value'] as String),
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: selected ? AppColors.teal : AppColors.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: selected ? AppColors.teal : AppColors.border,
                    width: 0.5,
                  ),
                ),
                child: Text(
                  p['label']!,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? Colors.white : AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Future<void> _onPeriodChanged(String value) async {
    if (value == _selectedPeriod) return;
    setState(() {
      _summaryRefreshing = true;
      _selectedPeriod = value;
      final now = DateTime.now();
      if (value == 'today') {
        _dateFrom = DateTime(now.year, now.month, now.day);
        _dateTo = DateTime(now.year, now.month, now.day, 23, 59, 59);
      } else if (value == 'week') {
        _dateFrom = now.subtract(Duration(days: now.weekday % 7));
        _dateTo = _dateFrom!.add(const Duration(days: 6));
      } else {
        _dateFrom = DateTime(now.year, now.month, 1);
        _dateTo = DateTime(now.year, now.month + 1, 0);
      }
    });
    await _loadAll(silent: true);
  }

  String _formatDateForApi(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Widget _statCard({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String value,
    required Color valueColor,
    required String label,
    VoidCallback? onTap,
  }) {
    final card = Container(
      padding: const EdgeInsets.all(10),
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
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: iconColor),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: valueColor,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return card;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: card,
    );
  }

  Widget _buildSectionLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.textFaint,
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    );
  }

  Widget _buildScanCardsRow() {
    return Row(
      children: [
        Expanded(
          child: _scanCard(
            icon: Icons.qr_code_2,
            title: 'Home Scan',
            subtitle: 'Your branch prescriptions',
            highlighted: true,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const FunctionalQrScannerScreen(),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _scanCard(
            icon: Icons.camera_alt_outlined,
            title: 'OCR Scan',
            subtitle: 'Capture handwritten Rx',
            highlighted: false,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => OCRScanScreen(
                  pharmacyId: AppSession.instance.pharmacyId ?? '',
                  onSave: (prescription, ocrCode, {confirmNew = false}) =>
                      PrescriptionApiService.save(
                        prescription,
                        ocrCode,
                        confirmNew: confirmNew,
                      ),
                  onViewSavedList: () {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (_) => const SavedPrescriptionsListScreen(),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _scanCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool highlighted,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: highlighted ? AppColors.teal : AppColors.border,
            width: highlighted ? 1.6 : 1,
          ),
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
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.tealPale,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 18, color: AppColors.teal),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 11.5,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentPrescriptions() {
    if (_recentLoading && SavedPrescriptionsStore.instance.items.isEmpty) {
      return _recentShimmer();
    }

    final recent = SavedPrescriptionsStore.instance.items.take(3).toList();
    if (recent.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _buildSectionLabel('RECENT PRESCRIPTIONS'),
            const Spacer(),
            GestureDetector(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SavedPrescriptionsListScreen(),
                ),
              ),
              child: const Text(
                'View All',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.teal,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final entry in recent) ...[
          _recentPrescriptionRow(entry),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _recentPrescriptionRow(PrescriptionEntry entry) {
    final p = entry.prescription;
    final medCount = p.medicines.length;
    final dt = toPhilippineTime(p.dateTime);
    final dateLabel = '${dt.month}/${dt.day}/${dt.year}';

    final (statusColor, statusLabel) = switch (p.dispensingStatus) {
      DispensingStatus.fullyDispensed => (AppColors.teal, 'Dispensed'),
      DispensingStatus.partiallyDispensed => (Colors.orange, 'Partial'),
      DispensingStatus.overDispensing => (AppColors.danger, 'Over-dispensed'),
      DispensingStatus.pending => (AppColors.textFaint, 'Pending'),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.patientName.isEmpty ? 'Unknown patient' : p.patientName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$medCount medicine(s) · $dateLabel',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            statusLabel,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: statusColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomNav() {
    return BottomNavBar(
      currentIndex: _navIndex,
      onTap: (i) => setState(() {
        _navIndex = i;
        _visitedTabs.add(i);
      }),
      items: BottomNavBar.pharmacistItems,
    );
  }
}
