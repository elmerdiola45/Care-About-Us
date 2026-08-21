// ph_time.dart
//
// The Philippines observes a single, fixed UTC+8 offset year-round (no
// daylight saving time), so converting any instant to Philippine wall-clock
// time is a safe, deterministic +8h shift from UTC — unlike relying on
// DateTime.toLocal(), which reflects whatever timezone the current device
// happens to be set to (not necessarily Philippine time, e.g. an
// unconfigured tablet/phone), and can vary scan-to-scan.

/// Converts [dt] (any instant — local or UTC) to Philippine wall-clock time.
/// Read the year/month/day/hour/minute fields directly off the result;
/// do not call `.toLocal()` on it afterwards.
DateTime toPhilippineTime(DateTime dt) =>
    dt.toUtc().add(const Duration(hours: 8));

/// Formats [dt] as Philippine local date/time, e.g. "8/21/2026 · 3:45 PM".
String formatPhilippineDateTime(DateTime dt) {
  final d = toPhilippineTime(dt);
  final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final minute = d.minute.toString().padLeft(2, '0');
  final ampm = d.hour < 12 ? 'AM' : 'PM';
  return '${d.month}/${d.day}/${d.year} · $hour:$minute $ampm';
}
