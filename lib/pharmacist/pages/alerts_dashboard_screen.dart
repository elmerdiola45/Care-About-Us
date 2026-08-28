import 'dart:async';

import 'package:flutter/material.dart';
import '../../common/theme/app_colors.dart';
import '../../common/services/laravel_api_service.dart';
import '../../common/services/alert_tracker.dart';
import '../../common/session.dart';
import '../../common/widgets/responsive_center.dart';
import '../models/dispense_alert.dart';
import 'alert_detail_screen.dart';

class AlertsDashboardScreen extends StatefulWidget {
  const AlertsDashboardScreen({super.key});

  @override
  State<AlertsDashboardScreen> createState() => _AlertsDashboardScreenState();
}

class _AlertsDashboardScreenState extends State<AlertsDashboardScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  final List<DispenseAlert> _alerts = [];
  AlertPriority? _selectedPriority;
  Timer? _pollingTimer;
  static const _pollingInterval = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();

    // Show whatever the dashboard's 30s alert poll (or a previous visit)
    // last fetched, so revisiting this screen doesn't flash a full-screen
    // spinner every time. It's at most ~30s old and is immediately
    // refreshed in the background below — never shown as the final state.
    final cached = AlertTracker.instance.latestAlerts;
    if (cached.isNotEmpty) {
      _alerts.addAll(cached);
      _isLoading = false;
    }
    _loadAlerts(silent: cached.isNotEmpty);
    _startPolling();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(_pollingInterval, (_) {
      if (mounted && !_isLoading) {
        _loadAlerts(silent: true);
      }
    });
  }

  Future<void> _loadAlerts({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _errorMessage = null;
      });
    }

    try {
      final api = LaravelApiService(token: AppSession.instance.token);
      // Always fetch the full unresolved set — the priority chips filter
      // it locally via `_filtered` (below), so there's no need to refetch
      // from the network every time the selected chip changes.
      final alerts = await api.fetchAlerts(unresolvedOnly: true);
      AlertTracker.instance.processAlerts(alerts);

      if (mounted) {
        setState(() {
          _alerts.clear();
          _alerts.addAll(alerts);
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (!silent) {
            _errorMessage = 'Failed to load alerts: $e';
          }
          _isLoading = false;
        });
      }
    }
  }

  List<DispenseAlert> get _filtered {
    if (_selectedPriority == null) return _alerts;
    return _alerts.where((a) => a.priority == _selectedPriority).toList();
  }

  @override
  Widget build(BuildContext context) {
    // Scaffold (not a bare Container) — this screen is pushed as its own
    // full route via MaterialPageRoute (see home_dashboard_screen.dart),
    // so it needs its own Material ancestor. Without it, the ChoiceChip
    // filter in _buildFilterChips() throws "No Material widget found" on
    // every rebuild, which hangs the whole page.
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildFilterChips(),
            const SizedBox(height: 8),
            Expanded(
              child: ResponsiveCenter.dashboard(
                padding: EdgeInsets.zero,
                child: _isLoading && _alerts.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: AppColors.teal),
                            SizedBox(height: 16),
                            Text(
                              'Loading alerts...',
                              style: TextStyle(color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      )
                    : _errorMessage != null && _alerts.isEmpty
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
                                onPressed: _loadAlerts,
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
                            _buildAlertCard(_filtered[index]),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 20, 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 4),
          const Expanded(
            child: Text(
              'Dispensing Alerts',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.textPrimary),
            tooltip: 'Refresh',
            onPressed: _loadAlerts,
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChips() {
    final chips = <(String, AlertPriority?)>[
      ('All', null),
      ('Normal', AlertPriority.normal),
      ('High', AlertPriority.high),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
      child: Row(
        children: chips.map((chip) {
          final (label, value) = chip;
          final isSelected = _selectedPriority == value;
          return Padding(
            padding: const EdgeInsets.only(right: 10),
            child: ChoiceChip(
              label: Text(label),
              selected: isSelected,
              onSelected: (_) {
                setState(() => _selectedPriority = value);
              },
              showCheckmark: false,
              labelStyle: TextStyle(
                color: isSelected ? Colors.white : AppColors.textSecondary,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
              backgroundColor: const Color(0xFFEDF1F1),
              selectedColor: _selectedPriority == AlertPriority.high
                  ? AppColors.danger
                  : AppColors.teal,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide.none,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildAlertCard(DispenseAlert alert) {
    final isHigh = alert.priority == AlertPriority.high;
    final icon = _alertIcon(alert.alertType);
    final bg = isHigh ? AppColors.dangerBg : AppColors.warningBg;
    final titleColor = isHigh ? AppColors.danger : AppColors.warning;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        if (!alert.isRead && !AlertTracker.instance.isRead(alert.alertId)) {
          AlertTracker.instance.markAsRead(alert.alertId);
          LaravelApiService(token: AppSession.instance.token)
              .markAlertAsRead(alert.alertId)
              .catchError((_) => AlertTracker.instance.unmarkAsRead(alert.alertId));
        }
        if (mounted) {
          Navigator.of(context)
              .push(
            MaterialPageRoute(
              builder: (_) => AlertDetailScreen(alertId: alert.alertId),
            ),
          )
              .then((_) {
            if (mounted) _loadAlerts(silent: true);
          });
        }
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isHigh
                ? AppColors.danger.withValues(alpha: 0.25)
                : AppColors.border,
          ),
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
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: titleColor, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    alert.title,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    alert.note,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                      height: 1.4,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_fmtDate(alert.createdAt)} · RX: ${alert.rxNumber ?? 'N/A'}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textFaint,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isHigh ? AppColors.dangerBg : AppColors.warningBg,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                isHigh ? 'High' : 'Normal',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: titleColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(
              Icons.check_circle_outline,
              size: 44,
              color: AppColors.success,
            ),
            SizedBox(height: 10),
            Text(
              'No active alerts',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _alertIcon(AlertType type) {
    switch (type) {
      case AlertType.overDispense:
        return Icons.warning_amber_rounded;
      case AlertType.earlyRefill:
        return Icons.access_time_rounded;
      case AlertType.duplicateDispense:
        return Icons.copy_rounded;
      case AlertType.crossPharmacyDuplicate:
        return Icons.store_rounded;
      case AlertType.crossPharmacyDispense:
        return Icons.sync_alt_rounded;
      case AlertType.duplicateOcrScan:
        return Icons.document_scanner_outlined;
      case AlertType.crossPharmacyOverlapRisk:
        return Icons.block_rounded;
    }
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
