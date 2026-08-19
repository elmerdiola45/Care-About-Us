import 'package:flutter/material.dart';
import '../../../admin/data/admin_api_service.dart';
import '../../../admin/models/admin_models.dart';
import '../../../common/theme/app_colors.dart';

class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key});

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  final AdminApiService _api = AdminApiService();
  List<CrossPharmacyRequestResponse> _requests = [];
  List<CrossPharmacyRequestResponse> get _filteredRequests {
    if (_statusFilter == null) return _requests;
    return _requests.where((r) {
      if (_statusFilter == 'pending') return r.status == RequestStatus.pending;
      if (_statusFilter == 'approved') {
        return r.status == RequestStatus.approved;
      }
      if (_statusFilter == 'rejected') {
        return r.status == RequestStatus.rejected;
      }
      if (_statusFilter == 'dispensed') {
        return r.dispensingStatus != null && r.dispensingStatus!.isNotEmpty;
      }
      return true;
    }).toList();
  }

  bool _loading = true;
  String? _error;
  final Set<String> _processingIds = {};
  String? _statusFilter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final requests = await _api.fetchCrossPharmacyRequests();
      setState(() {
        _requests = requests;
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

  Future<void> _approve(CrossPharmacyRequestResponse request) async {
    final requestId = request.requestId;
    if (_processingIds.contains(requestId)) return;
    setState(() => _processingIds.add(requestId));
    try {
      final result = await _api.approveCrossPharmacyRequest(requestId);
      if (!mounted) return;
      setState(() {
        request.status = RequestStatus.approved;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.critical
                ? '${result.message} Review the over-dispense details for ${request.rxNumber}.'
                : 'Approved — ${request.requestingPharmacyName} can now dispense ${request.rxNumber}.',
          ),
          backgroundColor: result.critical
              ? AppColors.amber
              : AppColors.success,
        ),
      );
    } on CrossPharmacyApiException catch (e) {
      // Covers the "already fully dispensed" block (and any other backend
      // rejection) with the actual server message instead of a dumped raw
      // JSON body — see CrossPharmacyApiException.
      setState(() => _processingIds.remove(requestId));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    } catch (_) {
      setState(() => _processingIds.remove(requestId));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Failed to approve request. Check your connection and try again.',
            ),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    }
  }

  Future<void> _reject(CrossPharmacyRequestResponse request) async {
    final requestId = request.requestId;
    if (_processingIds.contains(requestId)) return;
    final reason = await _showRejectDialog(context);
    if (reason == null) return;

    setState(() => _processingIds.add(requestId));
    try {
      final result = await _api.rejectCrossPharmacyRequest(requestId, reason);
      if (!mounted) return;
      setState(() {
        request.status = RequestStatus.rejected;
        request.rejectionReason = reason;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message),
          backgroundColor: AppColors.success,
        ),
      );
    } on CrossPharmacyApiException catch (e) {
      setState(() => _processingIds.remove(requestId));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    } catch (_) {
      setState(() => _processingIds.remove(requestId));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Failed to reject request. Check your connection and try again.',
            ),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    }
  }

  Future<String?> _showRejectDialog(BuildContext context) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject Request'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Reason for rejection...',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final reason = controller.text.trim();
              if (reason.isEmpty) return;
              Navigator.pop(ctx, reason);
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text(
          'Requests',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: Column(
        children: [
          _buildFilterChips(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildFilterChips() {
    final chips = [
      ('All', null),
      ('Pending', 'pending'),
      ('Approved', 'approved'),
      ('Rejected', 'rejected'),
      ('Dispensed', 'dispensed'),
    ];
    return SizedBox(
      height: 40,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        scrollDirection: Axis.horizontal,
        children: chips.map((c) {
          final label = c.$1;
          final value = c.$2;
          final isSelected = _statusFilter == value;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(label),
              selected: isSelected,
              onSelected: (_) => setState(() => _statusFilter = value),
              selectedColor: AppColors.teal,
              labelStyle: TextStyle(
                color: isSelected ? Colors.white : AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }).toList(),
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
              const Icon(Icons.error_outline, size: 48, color: AppColors.red),
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
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
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

    if (_filteredRequests.isEmpty) {
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
                _statusFilter == null
                    ? 'No requests yet'
                    : 'No $_statusFilter requests',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: AppColors.textPrimary,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Cross-pharmacy submissions will appear here.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: AppColors.teal,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          ..._filteredRequests.map(
            (r) => _RequestCard(
              request: r,
              onApprove: () => _approve(r),
              onReject: () => _reject(r),
              isProcessing: _processingIds.contains(r.requestId),
            ),
          ),
        ],
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  final CrossPharmacyRequestResponse request;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final bool isProcessing;
  const _RequestCard({
    required this.request,
    required this.onApprove,
    required this.onReject,
    this.isProcessing = false,
  });

  @override
  Widget build(BuildContext context) {
    final isPending = request.status == RequestStatus.pending;
    final isApproved = request.status == RequestStatus.approved;
    final isRejected = request.status == RequestStatus.rejected;
    final dispensingStatus = request.dispensingStatus?.toLowerCase();

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
              if (isPending)
                _StatusBadge(status: request.status)
              else if (isApproved &&
                  dispensingStatus != null &&
                  dispensingStatus.isNotEmpty)
                _DispensingStatusBadge(status: dispensingStatus)
              else
                _StatusBadge(status: request.status),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            request.requestingPharmacyLocation,
            style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.background,
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
                      '${m.name} × ${m.quantity}',
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
            'Staff: ${request.requestingStaffName}',
            style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
          if (isPending && request.wouldExceedRemaining) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFDEEE8),
                borderRadius: BorderRadius.circular(10),
                border: Border(
                  left: BorderSide(color: AppColors.red, width: 3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('🚫', style: TextStyle(fontSize: 16)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'OVERDISPENSING RISK',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                            color: AppColors.red,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  for (final d in request.exceedDetails)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: RichText(
                        text: TextSpan(
                          style: TextStyle(
                            fontSize: 12,
                            color: const Color(0xFF7A3115),
                            height: 1.4,
                          ),
                          children: [
                            TextSpan(
                              text: '${d.medicine}: this request wants ',
                            ),
                            TextSpan(
                              text: '${d.requested}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (d.otherPending > 0) ...[
                              const TextSpan(
                                text: ', another pending request wants ',
                              ),
                              TextSpan(
                                text: '${d.otherPending}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                            const TextSpan(
                              text: ' — combined that\'s more than the ',
                            ),
                            TextSpan(
                              text: '${d.remaining} remaining',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const TextSpan(text: ' on this prescription.'),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    'Approving will record only the remaining amount and flag this request as a critical over-dispense attempt for audit.',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (isPending && request.fullyDispensed) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFDEEE8),
                borderRadius: BorderRadius.circular(10),
                border: Border(
                  left: BorderSide(color: AppColors.red, width: 3),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('🚫', style: TextStyle(fontSize: 16)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'ALREADY FULLY DISPENSED',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                            color: AppColors.red,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'This prescription has no remaining quantity left on any medicine. Approving this request will be blocked — reject it instead.',
                          style: TextStyle(
                            fontSize: 12,
                            color: const Color(0xFF7A3115),
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (isApproved &&
              dispensingStatus != null &&
              dispensingStatus.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color:
                    dispensingStatus == 'over_dispensing' ||
                        dispensingStatus == 'overdispensing'
                    ? AppColors.redLight
                    : dispensingStatus == 'fully_dispensed'
                    ? AppColors.greenLight
                    : AppColors.amberLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                dispensingStatus == 'over_dispensing' ||
                        dispensingStatus == 'overdispensing'
                    ? 'Overdispensing'
                    : dispensingStatus == 'fully_dispensed'
                    ? 'Fully Dispensed'
                    : dispensingStatus == 'partially_dispensed'
                    ? 'Partially Dispensed'
                    : 'Dispensed',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color:
                      dispensingStatus == 'over_dispensing' ||
                          dispensingStatus == 'overdispensing'
                      ? AppColors.red
                      : dispensingStatus == 'fully_dispensed'
                      ? AppColors.green
                      : AppColors.amber,
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          if (isPending) ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: isProcessing ? null : onReject,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.red,
                      side: const BorderSide(color: AppColors.red),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: isProcessing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.red,
                            ),
                          )
                        : const Text(
                            'Reject',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: isProcessing ? null : onApprove,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.teal,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      elevation: 0,
                    ),
                    child: isProcessing
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
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                  ),
                ),
              ],
            ),
          ] else if (isRejected && request.rejectionReason != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.redLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Rejected: ${request.rejectionReason}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.red,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
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
        fg = AppColors.amber;
        label = 'Pending';
        break;
      case RequestStatus.approved:
        bg = AppColors.greenLight;
        fg = AppColors.green;
        label = 'Approved';
        break;
      case RequestStatus.rejected:
        bg = AppColors.redLight;
        fg = AppColors.red;
        label = 'Rejected';
        break;
      case RequestStatus.dispensed:
        bg = AppColors.tealLight;
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

class _DispensingStatusBadge extends StatelessWidget {
  final String status;
  const _DispensingStatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    late Color bg;
    late Color fg;
    late String label;
    final s = status.toLowerCase();
    if (s == 'over_dispensing' || s == 'overdispensing') {
      bg = AppColors.redLight;
      fg = AppColors.red;
      label = 'Overdispensing';
    } else if (s == 'fully_dispensed') {
      bg = AppColors.greenLight;
      fg = AppColors.green;
      label = 'Fully Dispensed';
    } else if (s == 'partially_dispensed') {
      bg = AppColors.amberLight;
      fg = AppColors.amber;
      label = 'Partial';
    } else {
      bg = AppColors.background;
      fg = AppColors.textSecondary;
      label = 'Dispensed';
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
