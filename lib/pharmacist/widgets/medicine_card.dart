import 'package:flutter/material.dart';

import '../../common/widgets/tap_target.dart';

class MedicineCard extends StatefulWidget {
  final String medicineName;
  final String strength;
  final int stock;
  final double unitPrice;
  final int prescribedQuantity;
  final int initialQuantity;
  final ValueChanged<int>? onChanged;

  const MedicineCard({
    super.key,
    required this.medicineName,
    required this.strength,
    required this.stock,
    required this.unitPrice,
    required this.prescribedQuantity,
    this.initialQuantity = 0,
    this.onChanged,
  });

  @override
  State<MedicineCard> createState() => _MedicineCardState();
}

class _MedicineCardState extends State<MedicineCard> {
  late int quantity;

  @override
  void initState() {
    super.initState();
    quantity = widget.initialQuantity > 0
        ? widget.initialQuantity
        : widget.prescribedQuantity;
  }

  double get subtotal => quantity * widget.unitPrice;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.medicineName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        widget.strength,
                        style: const TextStyle(color: Color(0xFF60756E)),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text(
                      'Per fill',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$quantity tabs',
                      style: const TextStyle(
                        color: Color(0xFF0B7B77),
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Row(
              children: [
                Expanded(
                  child: Text(
                    'Dispensing qty',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ),
                Text(
                  'Current stock',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _qtyButton(Icons.remove, 'Decrease quantity', () {
                  if (quantity > 0) {
                    setState(() => quantity--);
                  }
                }),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    quantity.toString(),
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                _qtyButton(Icons.add, 'Increase quantity', () {
                  if (quantity < widget.stock) {
                    setState(() => quantity++);
                  }
                }),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${widget.stock} units',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'After: ${widget.stock - quantity}',
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Subtotal',
                    style: const TextStyle(color: Colors.grey, fontSize: 14),
                  ),
                ),
                Text(
                  '₱${subtotal.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: Color(0xFF0B7B77),
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _qtyButton(IconData icon, String label, VoidCallback onTap) {
    return TapTarget(
      onTap: () {
        onTap();
        widget.onChanged?.call(quantity);
      },
      semanticLabel: label,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: const Color(0xFFEAF5F5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: const Color(0xFF0B7B77)),
      ),
    );
  }
}
