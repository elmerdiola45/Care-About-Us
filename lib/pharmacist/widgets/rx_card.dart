import 'package:flutter/material.dart';

class RxCard extends StatelessWidget {
  final String rxNo;
  final String patientName;
  final String prescriber;
  final String issuedDate;
  final bool isVerifiedQrData;

  const RxCard({
    super.key,
    required this.rxNo,
    required this.patientName,
    required this.prescriber,
    required this.issuedDate,
    this.isVerifiedQrData = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.receipt_long_outlined, color: Color(0xFF0B7B77)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    rxNo,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                ),
                if (isVerifiedQrData)
                  const Chip(
                    label: Text('QR data verified', style: TextStyle(fontSize: 10)),
                    avatar: Icon(Icons.verified, size: 15, color: Color(0xFF0B7B77)),
                  ),
              ],
            ),
            const Divider(height: 22),
            Text(
              patientName,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            const SizedBox(height: 4),
            Text(
              'Prescriber: $prescriber\nIssued: $issuedDate',
              style: const TextStyle(color: Color(0xFF60756E), height: 1.5),
            ),
            if (!isVerifiedQrData)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  'Unrecognized QR format — demo prescription loaded.',
                  style: TextStyle(color: Color(0xFF9A6700), fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
