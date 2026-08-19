//dispensing_summary_screen.dart
import 'package:flutter/material.dart';
import '../models/prescription.dart' show DispensingStatus;

class SummaryColors {
  static const green = Color(0xFF0F766E);
  static const greenDark = Color(0xFF0B4F4A);
  static const greenLight = Color(0xFFE6F5F3);
  static const background = Color(0xFFF3F6F5);
  static const text = Color(0xFF1F2937);
  static const muted = Color(0xFF6B7280);
}

class DispensedMedicine {
  final String name;
  final String genericName;
  final String brand;
  final String unitLabel;
  final int quantity;
  final double pricePerUnit;
  final int stockBefore;
  final int stockAfter;
  final bool isSeniorCitizen;

  const DispensedMedicine({
    required this.name,
    this.genericName = '',
    this.brand = '',
    required this.unitLabel,
    required this.quantity,
    required this.pricePerUnit,
    required this.stockBefore,
    required this.stockAfter,
    this.isSeniorCitizen = false,
  });

  double get grossTotal => quantity * pricePerUnit;
  double get discountAmount => isSeniorCitizen ? grossTotal * 0.20 : 0.0;
  double get lineTotal => grossTotal - discountAmount;
  int get deducted => stockBefore - stockAfter;
}

class DispensingTransaction {
  final String pharmacyName;
  final int fillNumber;
  final int totalFills;
  final DateTime dateTime;
  final String patientName;
  final int? patientAge;
  final String? patientSex;
  final String rxNumber;
  final String dispensedBy;
  final String dispensedByRole;
  final String authorizedBy;
  final String authorizedByTitle;
  final List<DispensedMedicine> medicines;
  final bool isSenior;
  final String? oscaId;
  final DispensingStatus dispensingStatus;

  const DispensingTransaction({
    required this.pharmacyName,
    required this.fillNumber,
    required this.totalFills,
    required this.dateTime,
    required this.patientName,
    this.patientAge,
    this.patientSex,
    required this.rxNumber,
    required this.dispensedBy,
    required this.dispensedByRole,
    required this.authorizedBy,
    required this.authorizedByTitle,
    required this.medicines,
    this.isSenior = false,
    this.oscaId,
    required this.dispensingStatus,
  });

  String get fillStatusLabel {
    switch (dispensingStatus) {
      case DispensingStatus.fullyDispensed:
        return 'Fill $fillNumber of $totalFills — Complete';
      case DispensingStatus.overDispensing:
        return 'Fill $fillNumber of $totalFills — Overdispensed';
      case DispensingStatus.partiallyDispensed:
      case DispensingStatus.pending:
        return 'Fill $fillNumber of $totalFills — Partially Filled';
    }
  }

  double get grossTotal =>
      medicines.fold<double>(0, (t, m) => t + m.grossTotal);
  double get totalDiscount =>
      medicines.fold<double>(0, (t, m) => t + m.discountAmount);
  double get totalCollected => grossTotal - totalDiscount;

  String get patientDisplay {
    final details = <String>[];
    if (patientAge != null) details.add('$patientAge years old');
    if (patientSex != null && patientSex!.isNotEmpty) details.add(patientSex!);
    return details.isEmpty
        ? patientName
        : '$patientName · ${details.join(' · ')}';
  }
}

class DispensingSummaryScreen extends StatelessWidget {
  final DispensingTransaction transaction;

  const DispensingSummaryScreen({super.key, required this.transaction});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SummaryColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                children: [
                  _transactionCard(),
                  const SizedBox(height: 16),
                  _medicinesCard(),
                  const SizedBox(height: 16),
                  _inventoryCard(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: () =>
                      Navigator.of(context).popUntil((route) => route.isFirst),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SummaryColors.green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  child: const Text('Done'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [SummaryColors.greenDark, SummaryColors.green],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(26)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 45,
                height: 45,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .18),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.check_circle_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'HOME PHARMACY DISPENSING',
                  style: TextStyle(
                    color: Color(0xFFD2F8F0),
                    letterSpacing: 1.1,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const Text(
            'Dispensing Summary',
            style: TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.graphic_eq_rounded,
                  color: Color(0xFF8EF0DD),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Inventory updated · ${transaction.pharmacyName} · Fill ${transaction.fillNumber} of ${transaction.totalFills} recorded',
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

  Widget _transactionCard() => _card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('TRANSACTION DETAILS', style: _sectionStyle),
        const SizedBox(height: 10),
        _detailRow('Date & Time', _formatDateTime(transaction.dateTime)),
        _line(),
        _detailRow('Patient', transaction.patientDisplay),
        if (transaction.isSenior) ...[
          _line(),
          _detailRow(
            'Patient Type',
            'Senior Citizen (SC)',
            valueColor: const Color(0xFFD97706),
          ),
          if (transaction.oscaId != null && transaction.oscaId!.isNotEmpty) ...[
            _line(),
            _detailRow('OSCA ID', transaction.oscaId!),
          ],
        ],
        _line(),
        _detailRow('RX Number', transaction.rxNumber),
        _line(),
        _detailRow(
          'Dispensed by',
          '${transaction.dispensedBy}\n${transaction.dispensedByRole}',
        ),
        _line(),
        _detailRow(
          'Authorized by',
          '${transaction.authorizedBy}\n${transaction.authorizedByTitle}',
        ),
        _line(),
        _detailRow(
          'Fill Status',
          transaction.fillStatusLabel,
          valueColor:
              transaction.dispensingStatus == DispensingStatus.fullyDispensed
              ? SummaryColors.green
              : transaction.dispensingStatus == DispensingStatus.overDispensing
              ? const Color(0xFFDC2626)
              : const Color(0xFFD97706),
        ),
      ],
    ),
  );

  Widget _medicinesCard() => _card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('MEDICINES DISPENSED', style: _sectionStyle),
            ),
            if (transaction.isSenior)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7E6),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(
                      Icons.elderly_rounded,
                      size: 13,
                      color: Color(0xFFD97706),
                    ),
                    SizedBox(width: 4),
                    Text(
                      'SC 20% OFF',
                      style: TextStyle(
                        color: Color(0xFFD97706),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < transaction.medicines.length; i++) ...[
          _medicineRow(transaction.medicines[i]),
          if (i < transaction.medicines.length - 1) _line(),
        ],
        const Divider(height: 26),
        if (transaction.isSenior) ...[
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Subtotal',
                  style: TextStyle(color: SummaryColors.muted, fontSize: 13.5),
                ),
              ),
              Text(
                _peso(transaction.grossTotal),
                style: const TextStyle(
                  color: SummaryColors.muted,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(
                Icons.elderly_rounded,
                size: 14,
                color: Color(0xFFD97706),
              ),
              const SizedBox(width: 4),
              const Expanded(
                child: Text(
                  'Senior Citizen Discount (20%)',
                  style: TextStyle(
                    color: Color(0xFFD97706),
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '−${_peso(transaction.totalDiscount)}',
                style: const TextStyle(
                  color: Color(0xFFD97706),
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const Divider(height: 18),
        ],
        Row(
          children: [
            const Expanded(
              child: Text(
                'Total Collected',
                style: TextStyle(
                  color: SummaryColors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Text(
              _peso(transaction.totalCollected),
              style: const TextStyle(
                color: SummaryColors.green,
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _inventoryCard() => _card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('INVENTORY UPDATE', style: _sectionStyle),
            ),
            _badge(
              'Auto-updated ✓',
              SummaryColors.greenLight,
              SummaryColors.green,
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < transaction.medicines.length; i++) ...[
          _inventoryRow(transaction.medicines[i]),
          if (i < transaction.medicines.length - 1) _line(),
        ],
      ],
    ),
  );

  Widget _medicineRow(DispensedMedicine medicine) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                medicine.name,
                style: const TextStyle(
                  color: SummaryColors.text,
                  fontWeight: FontWeight.w800,
                  fontSize: 14.5,
                ),
              ),
              if (medicine.brand.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  'Brand: ${medicine.brand}',
                  style: const TextStyle(
                    color: SummaryColors.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 3),
              Text(
                '${medicine.quantity} ${medicine.unitLabel} × ${_peso(medicine.pricePerUnit)}',
                style: const TextStyle(
                  color: SummaryColors.muted,
                  fontSize: 12.5,
                ),
              ),
              if (medicine.isSeniorCitizen) ...[
                const SizedBox(height: 2),
                Text(
                  'SC discount: −${_peso(medicine.discountAmount)}',
                  style: const TextStyle(
                    color: Color(0xFFD97706),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (medicine.isSeniorCitizen)
              Text(
                _peso(medicine.grossTotal),
                style: const TextStyle(
                  color: SummaryColors.muted,
                  fontSize: 12.5,
                  decoration: TextDecoration.lineThrough,
                ),
              ),
            Text(
              _peso(medicine.lineTotal),
              style: const TextStyle(
                color: SummaryColors.green,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _inventoryRow(DispensedMedicine medicine) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Icon(Icons.check_circle, color: SummaryColors.green, size: 19),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                medicine.name,
                style: const TextStyle(
                  color: SummaryColors.text,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${medicine.stockBefore} → ${medicine.stockAfter} units (−${medicine.deducted})',
                style: const TextStyle(
                  color: SummaryColors.muted,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
        _badge('Updated', const Color(0xFFE6F5F3), SummaryColors.green),
      ],
    ),
  );

  Widget _detailRow(
    String label,
    String value, {
    Color valueColor = SummaryColors.text,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 108,
          child: Text(
            label,
            style: const TextStyle(color: SummaryColors.muted, fontSize: 12.5),
          ),
        ),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: valueColor,
              fontWeight: FontWeight.w700,
              fontSize: 13.2,
              height: 1.35,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _badge(String label, Color background, Color foreground) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: foreground,
        fontSize: 10.5,
        fontWeight: FontWeight.w800,
      ),
    ),
  );

  Widget _card({required Widget child}) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: .04),
          blurRadius: 10,
          offset: const Offset(0, 3),
        ),
      ],
    ),
    child: child,
  );

  Widget _line() => const Divider(height: 1, color: Color(0xFFE8ECEA));
}

const _sectionStyle = TextStyle(
  color: SummaryColors.muted,
  fontSize: 11.5,
  letterSpacing: .7,
  fontWeight: FontWeight.w800,
);

String _peso(double value) => '₱${value.toStringAsFixed(2)}';

String _formatDateTime(DateTime value) {
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
  final hour = value.hour == 0
      ? 12
      : (value.hour > 12 ? value.hour - 12 : value.hour);
  final minute = value.minute.toString().padLeft(2, '0');
  final period = value.hour >= 12 ? 'PM' : 'AM';
  return '${months[value.month - 1]} ${value.day}, ${value.year} · $hour:$minute $period';
}
