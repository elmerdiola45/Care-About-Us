import 'package:flutter/material.dart';
import '../../../admin/data/admin_api_service.dart';
import '../../../admin/models/admin_models.dart';
import '../../../common/theme/app_colors.dart';
import '../../../common/widgets/responsive_center.dart';

class OverDispensingScreen extends StatefulWidget {
  final String prescriptionId;
  const OverDispensingScreen({super.key, required this.prescriptionId});

  @override
  State<OverDispensingScreen> createState() => _OverDispensingScreenState();
}

class _OverDispensingScreenState extends State<OverDispensingScreen> {
  final AdminApiService _api = AdminApiService();
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _prescription;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.prescriptionId;
    if (id.isEmpty) {
      setState(() {
        _loading = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final prescription = await _api.fetchPrescription(id);
      if (!mounted) return;
      setState(() {
        _prescription = prescription as Map<String, dynamic>?;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _retry() => _load();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _RedHeader(),
            Expanded(
              child: ResponsiveCenter.dashboard(
                padding: EdgeInsets.zero,
                child: _buildBody(),
              ),
            ),
          ],
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

    return _prescription != null ? _buildPrescription() : _buildNoData();
  }

  Widget _buildNoData() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'No prescription data available.',
          style: TextStyle(fontSize: 14, color: AppColors.textFaint),
        ),
      ),
    );
  }

  Widget _buildPrescription() {
    final rx = _prescription!;
    final patientName = rx['patient_name']?.toString() ?? 'Unknown';
    final patientAge = rx['patient_age'];
    final patientGender = rx['patient_gender']?.toString() ?? '';
    final doctorName = rx['doctor_name']?.toString() ?? '';
    final rxNumber = rx['prescription_id']?.toString() ?? widget.prescriptionId;
    final totalPrice = rx['total_price'] ?? 0;
    final status = rx['status']?.toString() ?? 'pending';
    final dispensingStatus = rx['dispensing_status']?.toString() ?? 'pending';
    final dateIssued = rx['date_issued']?.toString();
    final dateExpiry = rx['date_expiry']?.toString();
    final items = safeList(rx['items']);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        _InfoCard(title: 'Rx Number', value: rxNumber),
        const SizedBox(height: 12),
        _InfoCard(
          title: 'Patient',
          value:
              '$patientName ${patientAge != null ? '· Age $patientAge' : ''} ${patientGender.isNotEmpty ? '· $patientGender' : ''}',
        ),
        const SizedBox(height: 12),
        _InfoCard(title: 'Doctor', value: doctorName),
        const SizedBox(height: 12),
        _InfoCard(title: 'Total Price', value: '₱$totalPrice'),
        const SizedBox(height: 12),
        _InfoCard(
          title: 'Status',
          value:
              '${status.toUpperCase()} · Dispensing: ${dispensingStatus.replaceAll('_', ' ').toUpperCase()}',
        ),
        if (dateIssued != null) ...[
          const SizedBox(height: 12),
          _InfoCard(title: 'Date Issued', value: dateIssued),
        ],
        if (dateExpiry != null) ...[
          const SizedBox(height: 12),
          _InfoCard(title: 'Date Expiry', value: dateExpiry),
        ],
        const SizedBox(height: 16),
        Text(
          'Medications (${items.length})',
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        ...items.map<Widget>((item) {
          final im = safeMap(item) ?? {};
          final name = im['name']?.toString() ?? 'Unknown';
          final qty = safeInt(im['quantity'], 1);
          final dosage = im['dosage']?.toString();
          final dispensed = safeInt(
            im['disposed_quantity'] ?? im['dispatched_quantity'],
          );
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
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
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      if (dosage != null && dosage.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          dosage,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textFaint,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Text(
                  '×$qty',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: AppColors.teal,
                  ),
                ),
                if (dispensed > 0) ...[
                  const SizedBox(width: 12),
                  Text(
                    'Dispensed: $dispensed',
                    style: TextStyle(fontSize: 11, color: AppColors.textFaint),
                  ),
                ],
              ],
            ),
          );
        }),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.redLight,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.danger.withValues(alpha: 0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'OVER-DISPENSING ALERT',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.danger,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'This prescription has been flagged for over-dispensing review.',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.redDark,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: Navigator.of(context).maybePop,
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RedHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.danger,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                tooltip: 'Back',
              ),
            ],
          ),
          Center(
            child: Column(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.cancel,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'TRANSACTION BLOCKED',
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Over-Dispensing Detected',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.shield_outlined,
                  color: Colors.white,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Controlled Substance — Schedule III (RA 9165)',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String title;
  final String value;
  const _InfoCard({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
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
          Text(
            title,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppColors.textFaint,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
