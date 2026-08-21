import 'dart:async';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import '../data/admin_api_service.dart';
import '../models/admin_models.dart';
import '../../../common/theme/app_colors.dart';
import '../../../common/models/dashboard_models.dart';
import '../../../common/services/laravel_api_service.dart';
import '../../common/session.dart';
import '../../common/widgets/bottom_nav_bar.dart';
import '../../common/widgets/tap_target.dart';
import 'add_staff_sheet.dart';
import 'admin_patient_adherence_page.dart';
import 'reset_staff_password_sheet.dart';
import 'qr_ocr_records_screen.dart';
import 'requests_screen.dart';
import '../../login_screen.dart';
import 'price_list_page.dart';
import '../../pharmacist/pages/alerts_dashboard_screen.dart';
import '../../pharmacist/pages/change_password_screen.dart';

class AdminDashboardPage extends StatefulWidget {
  final String token;
  final String userType;

  const AdminDashboardPage({super.key, this.token = '', this.userType = ''});

  @override
  State<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends State<AdminDashboardPage> {
  int _topTab = 0;
  int _navIndex = 0;
  // Records/Requests/Patients (indices 1-3) built only once visited, same
  // lazy-construction pattern as the pharmacist side's HomeDashboardScreen —
  // avoids all three firing their network fetches before they're ever seen.
  final Set<int> _visitedTabs = {0};
  final AdminApiService _api = AdminApiService();
  String? _adminName; // ADD
  String? _adminRole;
  // Raw role key (not _adminRole's display label) — AppSession.userType
  // only distinguishes dispenser/pharmacist broadly, not admin-vs-
  // pharmacist-in-charge within the pharmacist role, so this is the only
  // reliable client-side signal for gating admin-only actions like staff
  // password reset. Defaults false until fetchMe() resolves.
  bool _isAdmin = false;

  // Notification badge state — polls the same GET /alerts endpoint the
  // dispenser side already uses (AlertsDashboardScreen), no new backend
  // work. "Seen" tracking is in-memory only (resets on reload) since
  // there's no unread/seen field on dispense_alerts to persist against.
  int _unresolvedAlertCount = 0;
  final Set<String> _seenAlertIds = {};
  bool _alertsSeeded = false;
  Timer? _alertPollTimer;

  @override
  void initState() {
    super.initState();
    // Nothing currently routes a Dispenser session here (login_screen.dart
    // decides by which tab was tapped, not by the server's real user_type),
    // but nothing prevented it either — this closes that gap client-side.
    // Not server-side role enforcement; see the fix plan for why that's a
    // deliberately separate, larger change.
    if (AppSession.instance.userType == 'dispenser') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
        );
      });
      return;
    }
    _loadMe();
    _startAlertPolling();
  }

  @override
  void dispose() {
    _alertPollTimer?.cancel();
    super.dispose();
  }

  void _startAlertPolling() {
    _pollAlerts();
    _alertPollTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _pollAlerts(),
    );
  }

  Future<void> _pollAlerts() async {
    try {
      final api = LaravelApiService(token: AppSession.instance.token);
      final alerts = await api.fetchAlerts(unresolvedOnly: true);
      if (!mounted) return;

      final currentIds = alerts.map((a) => a.alertId).toSet();

      if (_alertsSeeded) {
        final newIds = currentIds.difference(_seenAlertIds);
        if (newIds.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                newIds.length == 1
                    ? '1 new dispensing alert'
                    : '${newIds.length} new dispensing alerts',
              ),
              backgroundColor: AppColors.warning,
              action: SnackBarAction(
                label: 'View',
                textColor: Colors.white,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AlertsDashboardScreen(),
                  ),
                ),
              ),
            ),
          );
        }
      }

      setState(() {
        _unresolvedAlertCount = alerts.length;
        _seenAlertIds
          ..clear()
          ..addAll(currentIds);
        _alertsSeeded = true;
      });
    } catch (_) {
      // Silent — a failed poll shouldn't interrupt the dashboard; it just
      // retries on the next 30s tick.
    }
  }

  Future<void> _loadMe() async {
    try {
      final data = await _api.fetchMe();
      final user = safeMap(data['user']);
      if (mounted && user != null) {
        setState(() {
          _adminName = user['name']?.toString();
          _adminRole = user['role_display']?.toString();
          _isAdmin = user['role']?.toString() == 'admin';
        });
      }
    } catch (_) {
      // silent fail — header just won't show name
    }
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

  void _handleNav(int index) {
    setState(() {
      _navIndex = index;
      _visitedTabs.add(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: IndexedStack(
          index: _navIndex,
          children: [
            Column(
              children: [
                _buildHeader(),
                _buildTopTabs(),
                Expanded(
                  child: IndexedStack(
                    index: _topTab,
                    children: [
                      _OverviewTab(api: _api),
                      _UsersTab(api: _api, isAdmin: _isAdmin),
                      _ReportsTab(api: _api),
                    ],
                  ),
                ),
              ],
            ),
            _visitedTabs.contains(1)
                ? const QrOcrRecordsScreen()
                : const SizedBox.shrink(),
            _visitedTabs.contains(2)
                ? const RequestsScreen()
                : const SizedBox.shrink(),
            _visitedTabs.contains(3)
                ? const AdminPatientAdherencePage()
                : const SizedBox.shrink(),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavBar(
        currentIndex: _navIndex,
        onTap: _handleNav,
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppSession.instance.branchName ?? 'Care About Us Pharmacy',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Admin Dashboard',
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          TapTarget(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AlertsDashboardScreen()),
            ),
            semanticLabel: 'Dispensing alerts',
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 42,
              height: 42,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.teal.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.notifications_outlined,
                      color: AppColors.teal,
                      size: 20,
                    ),
                  ),
                  if (_unresolvedAlertCount > 0)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        constraints: const BoxConstraints(minWidth: 18),
                        decoration: BoxDecoration(
                          color: AppColors.danger,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: Text(
                          _unresolvedAlertCount > 99
                              ? '99+'
                              : '$_unresolvedAlertCount',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(width: 8), // ADD
          PopupMenuButton<String>(
            // ADD
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
                      _adminName ?? 'Admin',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      _adminRole ?? '',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
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
                  MaterialPageRoute(
                    builder: (_) => const ChangePasswordScreen(),
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTopTabs() {
    const labels = ['Overview', 'Users', 'Reports'];
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: List.generate(labels.length, (i) {
          final selected = _topTab == i;
          return Expanded(
            child: TapTarget(
              onTap: () => setState(() => _topTab = i),
              semanticLabel: labels[i],
              child: Container(
                padding: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: selected ? AppColors.teal : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  labels[i],
                  style: TextStyle(
                    color: selected ? AppColors.teal : Colors.grey.shade500,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 14.5,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

enum OverviewPeriod { today, week, month }

class _OverviewTab extends StatefulWidget {
  final AdminApiService api;
  const _OverviewTab({required this.api});

  @override
  State<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<_OverviewTab> {
  DashboardSummary? _summary;
  List<DispensingTrendPoint> _trend = [];
  bool _loading = true;
  // True while re-fetching a period that's already showing cached data —
  // drives a small inline indicator instead of blanking the whole tab.
  bool _refreshing = false;
  String? _error;
  OverviewPeriod _period = OverviewPeriod.today;

  // Last-fetched summary/trend per period, so switching back to an
  // already-viewed period shows instantly instead of re-blocking on the
  // network every tap.
  final Map<
    OverviewPeriod,
    ({DashboardSummary summary, List<DispensingTrendPoint> trend})
  >
  _cache = {};

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData({OverviewPeriod? period}) async {
    final selected = period ?? _period;
    final cached = _cache[selected];

    setState(() {
      _period = selected;
      _error = null;
      if (cached != null) {
        _summary = cached.summary;
        _trend = cached.trend;
        _loading = false;
        _refreshing = true;
      } else {
        _loading = true;
      }
    });
    try {
      final periodString = switch (selected) {
        OverviewPeriod.today => 'today',
        OverviewPeriod.week => 'week',
        OverviewPeriod.month => 'month',
      };
      final summary = await widget.api.fetchDashboardSummary(
        period: periodString,
      );
      final parsedSummary = DashboardSummary.fromJson(summary);
      // Trend is already in the dashboard summary response under the `data` wrapper.
      final dataMap = summary['data'] is Map
          ? Map<String, dynamic>.from(summary['data'] as Map)
          : summary;
      final trend = safeList(dataMap['dispensing_trend']);
      final parsedTrend = trend.map((e) {
        final m = safeMap(e) ?? {};
        return DispensingTrendPoint(
          day: m['day']?.toString() ?? '',
          count: safeInt(m['count']),
          value: safeDouble(m['value']),
        );
      }).toList();

      _cache[selected] = (summary: parsedSummary, trend: parsedTrend);

      if (mounted) {
        setState(() {
          _summary = parsedSummary;
          _trend = parsedTrend;
          _loading = false;
          _refreshing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _refreshing = false;
          // Keep showing cached data on a background-refresh failure rather
          // than replacing it with an error screen; only surface the error
          // when there was nothing cached to fall back to.
          if (cached == null) {
            _error = e.toString();
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 48,
                color: AppColors.danger,
              ),
              const SizedBox(height: 12),
              Text(
                'Couldn\'t reach the backend',
                style: TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => _loadData(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final periodLabel = switch (_period) {
      OverviewPeriod.today => 'Today',
      OverviewPeriod.week => 'This Week',
      OverviewPeriod.month => 'This Month',
    };

    final rxLabel = switch (_period) {
      OverviewPeriod.today => 'RX Today',
      OverviewPeriod.week => 'RX This Week',
      OverviewPeriod.month => 'RX This Month',
    };

    final dateSubtitle =
        _summary != null &&
            _summary!.dateFrom.isNotEmpty &&
            _summary!.dateTo.isNotEmpty
        ? '${_formatShortDate(_summary!.dateFrom)} – ${_formatShortDate(_summary!.dateTo)}'
        : '';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '$periodLabel, ${_formatDate(DateTime.now())}',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              ),
              const Spacer(),
              if (_refreshing) ...[
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.teal,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              _PeriodSelector(
                selected: _period,
                onChanged: (p) {
                  if (p != _period) {
                    _loadData(period: p);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  value: '${_summary?.rxCount ?? 0}',
                  label: rxLabel,
                  color: AppColors.teal,
                  subtitle: dateSubtitle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  value: '${_summary?.odFlagsLogged ?? 0}',
                  label: 'OD Flags Logged',
                  color: AppColors.danger,
                  subtitle: dateSubtitle,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  value: '${_summary?.activeAlerts ?? 0}',
                  label: 'Active Alerts',
                  color: AppColors.warning,
                  subtitle: 'Current snapshot',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatCard(
                  value: '${_summary?.avgAdherence ?? 0}%',
                  label: 'Avg. Adherence',
                  color: AppColors.success,
                  subtitle: dateSubtitle,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TapTarget(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const QrOcrRecordsScreen()),
            ),
            semanticLabel: 'QR and OCR records log',
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.tealPale,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.description_outlined,
                      color: AppColors.teal,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'QR & OCR Records Log',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'View today\'s scan activity',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward,
                    color: Colors.grey.shade400,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          TapTarget(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => PriceListPage()),
            ),
            semanticLabel: 'Medicine price list',
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.tealPale,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.sell_outlined,
                      color: AppColors.teal,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Medicine Price List',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Edit prices or upload a price list file',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward,
                    color: Colors.grey.shade400,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
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
                const Text(
                  'Dispensing Trend',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Divider(color: Colors.grey.shade200),
                const SizedBox(height: 14),
                _DispensingChart(
                  points: _trend.isEmpty ? _defaultTrend() : _trend,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<DispensingTrendPoint> _defaultTrend() => const [
    DispensingTrendPoint(day: 'Mon', count: 0, value: 0),
    DispensingTrendPoint(day: 'Tue', count: 0, value: 0),
    DispensingTrendPoint(day: 'Wed', count: 0, value: 0),
    DispensingTrendPoint(day: 'Thu', count: 0, value: 0),
    DispensingTrendPoint(day: 'Fri', count: 0, value: 0),
    DispensingTrendPoint(day: 'Sat', count: 0, value: 0),
    DispensingTrendPoint(day: 'Sun', count: 0, value: 0),
  ];

  String _formatDate(DateTime dt) {
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
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  String _formatShortDate(String dateStr) {
    if (dateStr.isEmpty) return '';
    final dt = DateTime.tryParse(dateStr);
    if (dt == null) return dateStr;
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
    return '${months[dt.month - 1]} ${dt.day}';
  }
}

class _PeriodSelector extends StatelessWidget {
  final OverviewPeriod selected;
  final ValueChanged<OverviewPeriod> onChanged;
  const _PeriodSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          _PeriodButton(
            label: 'Today',
            selected: selected == OverviewPeriod.today,
            onTap: () => onChanged(OverviewPeriod.today),
          ),
          _PeriodButton(
            label: 'Week',
            selected: selected == OverviewPeriod.week,
            onTap: () => onChanged(OverviewPeriod.week),
          ),
          _PeriodButton(
            label: 'Month',
            selected: selected == OverviewPeriod.month,
            onTap: () => onChanged(OverviewPeriod.month),
          ),
        ],
      ),
    );
  }
}

class _PeriodButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _PeriodButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? AppColors.teal : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : AppColors.textFaint,
          ),
        ),
      ),
    );
  }
}

class _DispensingChart extends StatefulWidget {
  final List<DispensingTrendPoint> points;
  const _DispensingChart({required this.points});

  @override
  State<_DispensingChart> createState() => _DispensingChartState();
}

class _DispensingChartState extends State<_DispensingChart> {
  int? _selectedIndex;

  @override
  Widget build(BuildContext context) {
    final points = widget.points;
    if (points.isEmpty) return const SizedBox(height: 168);
    final maxCount = points.map((p) => p.count).reduce((a, b) => a > b ? a : b);
    return SizedBox(
      height: 168,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(points.length, (i) {
          final point = points[i];
          final isSelected = _selectedIndex == i;
          final barHeight = maxCount > 0
              ? (100 * (point.value / maxCount)).toDouble().clamp(10.0, 100.0)
              : 5.0;
          return Expanded(
            child: TapTarget(
              onTap: () =>
                  setState(() => _selectedIndex = isSelected ? null : i),
              semanticLabel: '${point.day}: ${point.count} prescriptions',
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SizedBox(
                    height: 28,
                    child: isSelected
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.tealDark,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '${point.count} Rx',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              CustomPaint(
                                size: const Size(8, 5),
                                painter: _TrianglePainter(
                                  color: AppColors.tealDark,
                                ),
                              ),
                            ],
                          )
                        : null,
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: 22,
                    height: barHeight,
                    decoration: BoxDecoration(
                      color: isSelected ? AppColors.tealDark : AppColors.teal,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(6),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    point.day,
                    style: TextStyle(
                      fontSize: 11,
                      color: isSelected
                          ? AppColors.tealDark
                          : Colors.grey.shade500,
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final Color color;
  const _TrianglePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _TrianglePainter oldDelegate) =>
      oldDelegate.color != color;
}

class _StatCard extends StatelessWidget {
  final String value;
  final String label;
  final Color color;
  final String? subtitle;

  const _StatCard({
    required this.value,
    required this.label,
    required this.color,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
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
          Text(
            value,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade500,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _UsersTab extends StatefulWidget {
  final AdminApiService api;
  final bool isAdmin;
  const _UsersTab({required this.api, required this.isAdmin});

  @override
  State<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<_UsersTab> {
  List<StaffAccount> _staff = [];
  bool _loading = true;
  String? _error;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final staff = await widget.api.fetchStaff();
      if (mounted) {
        setState(() {
          _staff = staff;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  List<StaffAccount> get _filteredStaff {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return _staff;
    return _staff
        .where(
          (s) =>
              s.name.toLowerCase().contains(q) ||
              s.email.toLowerCase().contains(q) ||
              s.role.toLowerCase().contains(q),
        )
        .toList();
  }

  Future<void> _openAddStaffSheet() async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddStaffSheet(
        defaultPharmacyId: AppSession.instance.pharmacyId ?? '',
      ),
    );
    if (result == true && mounted) _loadData();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _loadData,
      child: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.teal),
            )
          : _error != null
          ? _buildError()
          : _buildContent(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppColors.danger),
            const SizedBox(height: 12),
            const Text(
              'Couldn\'t reach the backend',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _loadData,
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.teal),
              child: const Text('Retry', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Staff Accounts',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            ElevatedButton.icon(
              onPressed: _openAddStaffSheet,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.teal,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
              icon: const Icon(Icons.add, size: 16, color: Colors.white),
              label: const Text(
                'Add User',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: TextField(
            controller: _searchController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search staff by name or email',
              hintStyle: TextStyle(color: AppColors.textFaint, fontSize: 13.5),
              prefixIcon: const Icon(
                Icons.search,
                color: AppColors.textFaint,
                size: 20,
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
            style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
          ),
        ),
        const SizedBox(height: 16),
        if (_filteredStaff.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 32),
            child: Center(
              child: Text(
                'No staff members found',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
          )
        else
          ..._filteredStaff.map(
            (s) =>
                _StaffCard(staff: s, api: widget.api, isAdmin: widget.isAdmin),
          ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final StaffStatus status;
  final VoidCallback? onTap;

  const _StatusBadge({required this.status, this.onTap});

  (Color bg, Color fg, String label) get _style {
    switch (status) {
      case StaffStatus.active:
        return (AppColors.successBg, AppColors.success, 'Active');
      case StaffStatus.onLeave:
        return (AppColors.warningBg, AppColors.warning, 'On Leave');
      case StaffStatus.inactive:
        return (AppColors.dangerBg, AppColors.danger, 'Inactive');
    }
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg, label) = _style;
    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withValues(alpha: 0.2), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg),
      ),
    );
    if (onTap == null) {
      return content;
    }
    return TapTarget(
      onTap: onTap!,
      semanticLabel: label,
      borderRadius: BorderRadius.circular(999),
      child: content,
    );
  }
}

class _StaffCard extends StatefulWidget {
  final StaffAccount staff;
  final AdminApiService api;
  final bool isAdmin;
  const _StaffCard({
    required this.staff,
    required this.api,
    required this.isAdmin,
  });

  @override
  State<_StaffCard> createState() => _StaffCardState();
}

class _StaffCardState extends State<_StaffCard> {
  bool _updating = false;
  late StaffAccount _staff;

  @override
  void initState() {
    super.initState();
    _staff = widget.staff;
  }

  @override
  void didUpdateWidget(covariant _StaffCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.staff.id != oldWidget.staff.id) {
      _staff = widget.staff;
    }
  }

  Color _avatarColor(StaffStatus status) {
    switch (status) {
      case StaffStatus.active:
        return AppColors.teal;
      case StaffStatus.onLeave:
        return AppColors.warning;
      case StaffStatus.inactive:
        return Colors.grey.shade500;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _staff;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: _avatarColor(s.status),
            child: Text(
              s.initials,
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
                Text(
                  s.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  s.roleLabel,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Last: ${s.lastActive}',
                  style: TextStyle(fontSize: 11.5, color: AppColors.textFaint),
                ),
              ],
            ),
          ),
          if (_updating)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.teal,
              ),
            )
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Admin-only, matching the backend's own enforcement in
                // AdminStaffController::resetPassword() — hidden (not just
                // disabled) for a pharmacist-in-charge viewer so the UI
                // doesn't offer an action that would just 403.
                if (widget.isAdmin) ...[
                  IconButton(
                    icon: const Icon(
                      Icons.lock_reset,
                      size: 20,
                      color: AppColors.teal,
                    ),
                    tooltip: 'Reset Password',
                    onPressed: _openResetPasswordSheet,
                  ),
                  const SizedBox(width: 2),
                ],
                _StatusBadge(status: s.status, onTap: _openStatusMenu),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _openResetPasswordSheet() async {
    await ResetStaffPasswordSheet.show(context, staff: _staff, api: widget.api);
  }

  void _openStatusMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Set Staff Status',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              ...StaffStatus.values.map(
                (st) => ListTile(
                  leading: CircleAvatar(
                    radius: 10,
                    backgroundColor: _avatarColor(st),
                  ),
                  title: Text(
                    _statusLabel(st),
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  trailing: _staff.status == st
                      ? const Icon(Icons.check, color: AppColors.teal, size: 18)
                      : null,
                  onTap: () => _changeStatus(st),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  String _statusLabel(StaffStatus status) {
    switch (status) {
      case StaffStatus.active:
        return 'Active';
      case StaffStatus.onLeave:
        return 'On Leave';
      case StaffStatus.inactive:
        return 'Inactive';
    }
  }

  Future<void> _changeStatus(StaffStatus newStatus) async {
    Navigator.of(context).pop();
    setState(() => _updating = true);
    try {
      await widget.api.updateStaffStatus(_staff.id, newStatus);
      if (mounted) {
        setState(() {
          _staff = _staff.copyWith(status: newStatus);
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Failed to update status',
              style: TextStyle(color: Colors.white),
            ),
            backgroundColor: AppColors.danger,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }
}

class _ReportsTab extends StatefulWidget {
  final AdminApiService api;
  const _ReportsTab({required this.api});

  @override
  State<_ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<_ReportsTab> {
  ReportType _reportType = ReportType.dispensing;
  DateTimeRange? _dateRange;
  List<DispensingReportRow> _dispensingRows = [];
  List<SeniorCitizenReportRow> _seniorCitizenRows = [];
  bool _loadingPreview = false;
  bool _exportingPdf = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Reports',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 16),
        _ReportTypeSelector(
          selected: _reportType,
          onChanged: (type) {
            setState(() {
              _reportType = type;
              _error = null;
              _dispensingRows = [];
              _seniorCitizenRows = [];
            });
          },
        ),
        const SizedBox(height: 16),
        _DateRangeField(
          dateRange: _dateRange,
          onPick: () async {
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2020),
              lastDate: DateTime.now(),
            );
            if (picked != null) {
              setState(() {
                _dateRange = picked;
                _error = null;
                _dispensingRows = [];
                _seniorCitizenRows = [];
              });
            }
          },
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _loadingPreview ? null : _loadPreview,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.teal,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: _loadingPreview
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(
                        Icons.visibility_outlined,
                        size: 18,
                        color: Colors.white,
                      ),
                label: Text(
                  _loadingPreview ? 'Loading...' : 'Preview',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _exportingPdf ? null : _exportPdf,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.danger,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: _exportingPdf
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(
                        Icons.picture_as_pdf_outlined,
                        size: 18,
                        color: Colors.white,
                      ),
                label: Text(
                  _exportingPdf ? 'Exporting...' : 'Export as PDF',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.dangerBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppColors.danger.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 18,
                  color: AppColors.danger,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: AppColors.danger,
                      fontSize: 12.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        if (_reportType == ReportType.dispensing) ...[
          _DispensingPreviewTable(rows: _dispensingRows),
        ] else ...[
          _SeniorCitizenPreviewTable(rows: _seniorCitizenRows),
        ],
      ],
    );
  }

  Future<void> _loadPreview() async {
    if (_dateRange == null) {
      setState(() => _error = 'Please select a date range first');
      return;
    }

    setState(() {
      _loadingPreview = true;
      _error = null;
    });

    try {
      if (_reportType == ReportType.dispensing) {
        final rows = await widget.api.fetchDispensingReport(
          from: _dateRange!.start,
          to: _dateRange!.end,
        );
        if (mounted) {
          setState(() {
            _dispensingRows = rows;
            _loadingPreview = false;
          });
        }
      } else {
        final rows = await widget.api.fetchSeniorCitizenReport(
          from: _dateRange!.start,
          to: _dateRange!.end,
        );
        if (mounted) {
          setState(() {
            _seniorCitizenRows = rows;
            _loadingPreview = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loadingPreview = false;
        });
      }
    }
  }

  Future<void> _exportPdf() async {
    if (_dateRange == null) {
      setState(() => _error = 'Please select a date range first');
      return;
    }

    setState(() => _exportingPdf = true);

    try {
      final bytes = _reportType == ReportType.dispensing
          ? await widget.api.exportDispensingReportPdf(
              from: _dateRange!.start,
              to: _dateRange!.end,
            )
          : await widget.api.exportSeniorCitizenReportPdf(
              from: _dateRange!.start,
              to: _dateRange!.end,
            );

      if (!mounted) return;

      await Printing.sharePdf(
        bytes: bytes,
        filename: _reportType == ReportType.dispensing
            ? 'dispensing-report.pdf'
            : 'senior-citizen-report.pdf',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('PDF exported successfully'),
            backgroundColor: AppColors.teal700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Failed to export PDF: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: AppColors.danger,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _exportingPdf = false);
      }
    }
  }
}

class _ReportTypeSelector extends StatelessWidget {
  final ReportType selected;
  final ValueChanged<ReportType> onChanged;
  const _ReportTypeSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ReportTypeButton(
              label: 'Dispensing Report',
              selected: selected == ReportType.dispensing,
              onTap: () => onChanged(ReportType.dispensing),
            ),
          ),
          Expanded(
            child: _ReportTypeButton(
              label: 'Senior Citizen Discount',
              selected: selected == ReportType.seniorCitizenDiscount,
              onTap: () => onChanged(ReportType.seniorCitizenDiscount),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportTypeButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ReportTypeButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TapTarget(
      onTap: onTap,
      semanticLabel: label,
      borderRadius: BorderRadius.circular(11),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? AppColors.teal : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : AppColors.textFaint,
          ),
        ),
      ),
    );
  }
}

class _DateRangeField extends StatelessWidget {
  final DateTimeRange? dateRange;
  final VoidCallback onPick;
  const _DateRangeField({required this.dateRange, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final label = dateRange == null
        ? 'Select date range'
        : '${_formatDate(dateRange!.start)} — ${_formatDate(dateRange!.end)}';

    return InkWell(
      onTap: onPick,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.calendar_today_outlined,
              size: 18,
              color: AppColors.textFaint,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  color: dateRange == null
                      ? AppColors.textFaint
                      : AppColors.textSecondary,
                  fontWeight: dateRange == null
                      ? FontWeight.w500
                      : FontWeight.w600,
                ),
              ),
            ),
            if (dateRange != null)
              IconButton(
                onPressed: onPick,
                icon: const Icon(
                  Icons.edit_outlined,
                  size: 16,
                  color: AppColors.textFaint,
                ),
                tooltip: 'Change date range',
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

class _DispensingPreviewTable extends StatelessWidget {
  final List<DispensingReportRow> rows;
  const _DispensingPreviewTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: const Center(
          child: Text(
            'No dispensing records found for the selected date range.',
            style: TextStyle(color: AppColors.textFaint),
          ),
        ),
      );
    }

    // Below ~700px a 10-column DataTable is unusable even with horizontal
    // scroll (reading one field at a time via swipe), so it's replaced with
    // a stacked card per record — the DataTable itself is unchanged for
    // tablet/desktop widths where it's actually readable.
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 700) {
          return Column(
            children: rows
                .map((row) => _DispensingRecordCard(row: row))
                .toList(),
          );
        }
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: DataTable(
              headingRowColor: WidgetStateProperty.all(AppColors.tealPale),
              columns: const [
                DataColumn(
                  label: Text(
                    'Date Dispensed',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                DataColumn(
                  label: Text(
                    'RX No.',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                DataColumn(
                  label: Text(
                    'Physician',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                DataColumn(
                  label: Text(
                    'Patient Name',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                DataColumn(
                  label: Text(
                    'Generic Name',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                DataColumn(
                  label: Text(
                    'Brand Name',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                DataColumn(
                  label: Text(
                    'Lot No.',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                DataColumn(
                  label: Text(
                    'Expiry Date',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                DataColumn(
                  label: Text(
                    'Qty Served',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                DataColumn(
                  label: Text(
                    'Remarks',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
              ],
              rows: rows.map((row) {
                final isFully = row.remarks.toLowerCase().contains('fully');
                final tagColor = isFully
                    ? AppColors.success
                    : AppColors.warning;
                final tagBg = isFully
                    ? AppColors.successBg
                    : AppColors.warningBg;
                return DataRow(
                  cells: [
                    DataCell(
                      Text(
                        row.dateDispensed,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    DataCell(
                      Text(
                        row.rxNumber,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    DataCell(
                      Text(
                        row.physicianName,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    DataCell(
                      Text(
                        row.patientName,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    DataCell(
                      Text(
                        row.genericName,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    DataCell(
                      Text(
                        row.brandName,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    DataCell(
                      Text(row.lotNo, style: const TextStyle(fontSize: 12.5)),
                    ),
                    DataCell(
                      Text(
                        row.expiryDate,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    DataCell(
                      Text(
                        '${row.quantityServed}',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    DataCell(
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: tagBg,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          row.remarks,
                          style: TextStyle(
                            color: tagColor,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
        );
      },
    );
  }
}

class _DispensingRecordCard extends StatelessWidget {
  final DispensingReportRow row;
  const _DispensingRecordCard({required this.row});

  @override
  Widget build(BuildContext context) {
    final isFully = row.remarks.toLowerCase().contains('fully');
    final tagColor = isFully ? AppColors.success : AppColors.warning;
    final tagBg = isFully ? AppColors.successBg : AppColors.warningBg;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  row.patientName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: tagBg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  row.remarks,
                  style: TextStyle(
                    color: tagColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'RX ${row.rxNumber} · ${row.dateDispensed}',
            style: const TextStyle(color: AppColors.textFaint, fontSize: 12),
          ),
          const Divider(height: 16, color: AppColors.border),
          _cardRow('Physician', row.physicianName),
          _cardRow('Generic Name', row.genericName),
          _cardRow('Brand Name', row.brandName),
          _cardRow('Lot No.', row.lotNo),
          _cardRow('Expiry Date', row.expiryDate),
          _cardRow('Qty Served', '${row.quantityServed}'),
        ],
      ),
    );
  }

  Widget _cardRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: const TextStyle(color: AppColors.textFaint, fontSize: 12),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    ),
  );
}

class _SeniorCitizenPreviewTable extends StatelessWidget {
  final List<SeniorCitizenReportRow> rows;
  const _SeniorCitizenPreviewTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: const Center(
          child: Text(
            'No senior citizen discount records found for the selected date range.',
            style: TextStyle(color: AppColors.textFaint),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 700) {
          return Column(
            children: rows
                .map((row) => _SeniorCitizenRecordCard(row: row))
                .toList(),
          );
        }
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: DataTable(
              headingRowColor: WidgetStateProperty.all(AppColors.tealPale),
              columns: const [
                DataColumn(
                  label: Text(
                    'Date',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                DataColumn(
                  label: Text(
                    'Senior Citizen Name',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                DataColumn(
                  label: Text(
                    'OSCA ID No.',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                DataColumn(
                  label: Text(
                    'Drug Name',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                DataColumn(
                  label: Text(
                    'Gross Cost',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                DataColumn(
                  label: Text(
                    '% Discount',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                DataColumn(
                  label: Text(
                    'Net Cost',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                DataColumn(
                  label: Text(
                    'OR No.',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
              ],
              rows: rows.map((row) {
                return DataRow(
                  cells: [
                    DataCell(
                      Text(row.date, style: const TextStyle(fontSize: 12.5)),
                    ),
                    DataCell(
                      Text(
                        row.seniorCitizenName,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    DataCell(
                      Text(row.oscaId, style: const TextStyle(fontSize: 12.5)),
                    ),
                    DataCell(
                      Text(
                        row.drugName,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    DataCell(
                      Text(
                        '₱${row.grossCost.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    DataCell(
                      Text(
                        '${row.discountPercent.toStringAsFixed(0)}%',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    DataCell(
                      Text(
                        '₱${row.netCost.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                    DataCell(
                      Text(
                        row.orNumber,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
        );
      },
    );
  }
}

class _SeniorCitizenRecordCard extends StatelessWidget {
  final SeniorCitizenReportRow row;
  const _SeniorCitizenRecordCard({required this.row});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            row.seniorCitizenName,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
          ),
          const SizedBox(height: 2),
          Text(
            '${row.date} · OSCA ${row.oscaId}',
            style: const TextStyle(color: AppColors.textFaint, fontSize: 12),
          ),
          const Divider(height: 16, color: AppColors.border),
          _cardRow('Drug Name', row.drugName),
          _cardRow('Gross Cost', '₱${row.grossCost.toStringAsFixed(2)}'),
          _cardRow('% Discount', '${row.discountPercent.toStringAsFixed(0)}%'),
          _cardRow('Net Cost', '₱${row.netCost.toStringAsFixed(2)}'),
          _cardRow('OR No.', row.orNumber),
        ],
      ),
    );
  }

  Widget _cardRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: const TextStyle(color: AppColors.textFaint, fontSize: 12),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    ),
  );
}
