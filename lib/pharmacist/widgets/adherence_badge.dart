import 'package:flutter/material.dart';
import '../../common/theme/app_colors.dart';
import '../models/adherence.dart';

class AdherenceBadge extends StatelessWidget {
  final AdherenceTier tier;
  final String label;
  final bool compact;

  const AdherenceBadge({
    super.key,
    required this.tier,
    this.label = '',
    this.compact = false,
  });

  factory AdherenceBadge.fromStatus(String? status) {
    return AdherenceBadge(
      tier: tierFor(status),
      label: status ?? 'Unknown',
    );
  }

  (Color, Color, String) get _style {
    switch (tier) {
      case AdherenceTier.good:
        return (AppColors.green, AppColors.greenBg, 'Good');
      case AdherenceTier.atRisk:
        return (AppColors.amber, AppColors.amberBg, 'At Risk');
      case AdherenceTier.critical:
        return (AppColors.red, AppColors.redBg, 'Critical');
      case AdherenceTier.overDispensing:
        return (AppColors.red, AppColors.redBg, 'Overdispensing');
      case AdherenceTier.fullyDispensed:
        return (Color(0xFF4B5563), Color(0xFFF3F4F6), 'Fully Dispensed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final (fg, bg, defaultLabel) = _style;
    final displayLabel = label.isEmpty ? defaultLabel : label;

    if (compact) {
      return Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(
        displayLabel,
        style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 12.5),
      ),
    );
  }
}
