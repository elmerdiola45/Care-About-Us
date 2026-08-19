import '../models/prescription_scan_result.dart';

/// Judges how good a [PrescriptionScanResult] actually looks, without
/// needing a "correct answer" to compare against. Used to decide
/// whether it's worth spending a second OCR.space call on a different
/// engine, and (if so) which of the two results to keep.
///
/// Higher score = more structured, plausible-looking data was
/// successfully extracted. This isn't a guarantee of correctness — it's
/// a proxy: a result with 3 medicines that each have a dosage and a
/// fuzzy-matched drug name is far more likely to be a good read than
/// one with no medicines or only bare unstructured text.
class PrescriptionResultScorer {
  static double score(PrescriptionScanResult result) {
    if (!result.success) return 0;

    double points = 0;

    if (result.patientName != null && result.patientName!.isNotEmpty) {
      points += 1;
    }
    if (result.doctorName != null && result.doctorName!.isNotEmpty) {
      points += 1;
    }

    for (final med in result.medicines) {
      // A medicine line found at all is worth something, but one with
      // a recognizable dosage/frequency/quantity attached is much more
      // likely to be a genuinely correct read rather than noise that
      // happened to fuzzy-match a drug name.
      points += 1;
      if (med.dosage.isNotEmpty) points += 1;
      if (med.frequency.isNotEmpty) points += 0.5;
      if (med.quantity.isNotEmpty) points += 0.5;
    }

    return points;
  }

  /// Below this, a result is treated as "weak enough to be worth a
  /// second OCR.space call on the other engine" — e.g. nothing but a
  /// patient name, or zero medicines detected at all.
  ///
  /// SPEED-FIRST (post-audit): lowered from 2.0 to 1.0. At 2.0, a scan
  /// that found exactly one medicine with no dosage/frequency/quantity
  /// attached (1 point) still triggered a full second OCR.space call —
  /// in practice a meaningful share of otherwise-fine scans. At 1.0,
  /// any single medicine found (or a patient/doctor name alone) is
  /// accepted as-is instead of paying for a retry, so the double-OCR
  /// path is reserved for genuinely empty/near-empty reads. Trade-off:
  /// some borderline scans that a retry would have improved now go
  /// through with fewer fields filled in — acceptable given speed is
  /// the priority and accuracy can follow (e.g. via manual correction).
  static const double weakResultThreshold = 1.0;

  static bool isWeak(PrescriptionScanResult result) =>
      score(result) < weakResultThreshold;
}
