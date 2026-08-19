/// Merges two OCR.space engine outputs of the SAME photo line-by-line,
/// instead of picking one engine's whole result and discarding the
/// other entirely.
///
/// Why this matters: Engine 3 and Engine 2 don't fail the same way on
/// the same handwriting. It's common for Engine 3 to read line 2
/// correctly while mangling line 4, and Engine 2 to do the opposite on
/// the same photo. Comparing whole-result quality (as the earlier
/// scorer-based fallback did) means you keep ONE engine's mistakes on
/// every line it got wrong, even when the other engine happened to get
/// that specific line right. Merging per line lets you keep the best of
/// both without a third API call.
///
/// Known limitation: this aligns lines by INDEX (line 1 vs line 1, line
/// 2 vs line 2, ...), not by geometric position on the page. That's a
/// simplification, not a false claim of perfection — if one engine
/// merges two lines into one or splits a line the other engine kept
/// whole, the indices drift and alignment gets worse past that point.
/// A more robust version would align using OCR.space's overlay/bounding
/// box data (`isOverlayRequired=true`) instead of raw line index — worth
/// upgrading to if you see misalignment in practice on real scans.
class LineEnsembleService {
  static String merge(String textA, String textB) {
    final linesA = textA.split(RegExp(r'\r\n|\r|\n'));
    final linesB = textB.split(RegExp(r'\r\n|\r|\n'));

    final maxLen = linesA.length > linesB.length
        ? linesA.length
        : linesB.length;
    final merged = <String>[];

    for (var i = 0; i < maxLen; i++) {
      final lineA = i < linesA.length ? linesA[i] : '';
      final lineB = i < linesB.length ? linesB[i] : '';

      if (lineA.trim().isEmpty) {
        merged.add(lineB);
        continue;
      }
      if (lineB.trim().isEmpty) {
        merged.add(lineA);
        continue;
      }

      merged.add(_scoreLine(lineA) >= _scoreLine(lineB) ? lineA : lineB);
    }

    return merged.join('\n');
  }

  /// Cheap, self-contained plausibility score for a single OCR line —
  /// deliberately simpler than [PrescriptionResultScorer] (which needs a
  /// fully parsed result) since this runs per-line, on raw text, before
  /// parsing happens at all.
  static double _scoreLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return 0;

    double score = 0;

    // A line with a recognizable dosage/unit is much more likely to be
    // a correctly-read medicine line than one without.
    if (RegExp(
      r'\d+\s?(mg|mcg|g|ml|iu|%)',
      caseSensitive: false,
    ).hasMatch(trimmed)) {
      score += 3;
    }

    // Frequency abbreviations are another strong "this line reads
    // cleanly" signal.
    if (RegExp(
      r'\b(od|bid|tid|qid|prn|hs|ac|pc|stat)\b',
      caseSensitive: false,
    ).hasMatch(trimmed)) {
      score += 1;
    }

    // Garbled OCR output tends to produce short runs of letters mixed
    // with stray punctuation/symbols rather than clean words — reward
    // lines that look like real, longer words.
    final letterRuns = RegExp(r'[A-Za-z]{3,}').allMatches(trimmed).length;
    score += letterRuns * 0.5;

    // Penalize lines that are mostly non-alphanumeric noise — a common
    // shape for a badly misread line.
    final alnumCount = trimmed.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').length;
    final noiseRatio = 1 - (alnumCount / trimmed.length);
    if (noiseRatio > 0.5) score -= 2;

    return score;
  }
}
