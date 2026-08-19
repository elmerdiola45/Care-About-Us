import 'package:flutter/material.dart';

class FillRecord {
  final String label;
  final String date;
  final String subtitle;
  final bool isCompleted;
  final String? statusLabel;
  final List<MapEntry<String, String>> medicines;

  const FillRecord({
    required this.label,
    required this.date,
    required this.subtitle,
    this.isCompleted = true,
    this.statusLabel,
    this.medicines = const [],
  });
}

class HistoryCard extends StatelessWidget {
  final List<FillRecord> records;

  const HistoryCard({super.key, required this.records});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            for (int i = 0; i < records.length; i++) ...[
              _buildRecordTile(records[i]),
              if (i != records.length - 1) const Divider(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRecordTile(FillRecord record) {
    final icon = record.isCompleted
        ? Icon(Icons.check, color: const Color(0xFF0B7B77))
        : const Icon(Icons.schedule, color: Color(0xFF73877F));
    final iconBg = record.isCompleted
        ? const Color(0xFFE3F5F2)
        : const Color(0xFFF0F4F2);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(backgroundColor: iconBg, child: icon),
      title: Text(
        record.label,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 15,
          color: record.isCompleted ? null : const Color(0xFFBFC6CE),
        ),
      ),
      subtitle: Text(record.subtitle),
      trailing: record.statusLabel != null
          ? Text(
              record.statusLabel!,
              style: TextStyle(
                color: record.isCompleted ? const Color(0xFF0B7B77) : const Color(0xFFBFC6CE),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            )
          : null,
    );
  }
}
