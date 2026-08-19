import 'package:flutter/material.dart';
import '../../common/theme/app_colors.dart';
import '../../common/services/laravel_api_service.dart';
import '../../common/session.dart';
import '../models/dispense_alert.dart';

class AlertDetailScreen extends StatefulWidget {
  final String alertId;

  const AlertDetailScreen({super.key, required this.alertId});

  @override
  State<AlertDetailScreen> createState() => _AlertDetailScreenState();
}

class _AlertDetailScreenState extends State<AlertDetailScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  DispenseAlert? _alert;

  @override
  void initState() {
    super.initState();
    _loadAlert();
  }

  Future<void> _loadAlert() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final api = LaravelApiService(token: AppSession.instance.token);
      final alert = await api.fetchAlert(widget.alertId);
      if (mounted) {
        setState(() {
          _alert = alert;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to load alert: $e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: AppColors.teal),
                    )
                  : _errorMessage != null
                  ? _buildErrorState()
                  : _buildDetail(_alert!),
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
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 4),
          const Expanded(
            child: Text(
              'Alert Details',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
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
              _errorMessage!,
              style: const TextStyle(color: AppColors.danger),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: _loadAlert,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetail(DispenseAlert alert) {
    final isHigh = alert.priority == AlertPriority.high;
    final titleColor = isHigh ? AppColors.red : AppColors.amber;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isHigh
                  ? AppColors.red.withValues(alpha: 0.25)
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      alert.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: titleColor,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isHigh ? AppColors.redBg : AppColors.warningBg,
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
              const SizedBox(height: 12),
              Text(
                alert.description,
                style: const TextStyle(
                  fontSize: 13.5,
                  color: AppColors.textSecondary,
                  height: 1.5,
                ),
              ),
              if (alert.note.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  alert.note,
                  style: const TextStyle(
                    fontSize: 13.5,
                    color: AppColors.textPrimary,
                    height: 1.5,
                  ),
                ),
              ],
              const Divider(height: 28),
              _detailRow('RX Number', alert.rxNumber ?? 'N/A'),
              _detailRow('Patient ID', alert.patientId ?? 'N/A'),
              _detailRow('Prescription ID', alert.prescriptionId ?? 'N/A'),
              _detailRow('Attempted By', alert.attemptedBy ?? 'N/A'),
              _detailRow(
                'Attempting Pharmacy',
                alert.attemptingPharmacyId ?? 'N/A',
              ),
              _detailRow(
                'Original Pharmacy',
                alert.originalPharmacyId ?? 'N/A',
              ),
              _detailRow('Reported', _fmtDate(alert.createdAt)),
              _detailRow('Resolved', alert.resolved ? 'Yes' : 'No'),
              if (alert.resolved && alert.resolvedAt != null)
                _detailRow('Resolved At', _fmtDate(alert.resolvedAt!)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textFaint,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
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
