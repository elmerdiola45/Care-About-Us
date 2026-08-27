import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Cleans up a prescription photo *before* it's sent to OCR.space —
/// runs entirely on-device, no extra API call, no extra quota.
///
/// PERFORMANCE NOTE (post-audit): this used to run as three sequential
/// full-image passes — adjust, sharpen, binarize — each allocating its
/// own full-resolution buffer via `img.Image.from()`. That's now fused
/// into a SINGLE pixel pass: for every output pixel, the 3x3
/// neighborhood needed for sharpening is computed by applying the
/// color-adjustment formula directly to the ORIGINAL image's pixels
/// (as a pure function, not a stored intermediate buffer), then
/// thresholded straight to black/white in the same loop. Net effect:
/// one output allocation instead of three, ~3x fewer full-image
/// traversals, lower peak memory during preprocessing.
class ImagePreprocessorService {
  static Uint8List preprocess(Uint8List originalBytes) {
    final decoded = img.decodeImage(originalBytes);
    if (decoded == null) {
      throw const FormatException('Could not decode image for preprocessing.');
    }

    // Capped to keep the post-binarization JPEG under the backend's 5MB
    // upload limit (PrescriptionController::store, 'image' => max:5120) on
    // full-resolution modern camera photos, while staying well above what
    // OCR needs for legible handwriting.
    final capped =
        decoded.width > 2000 ? img.copyResize(decoded, width: 2000) : decoded;

    final result = _fusedSharpenAndBinarize(capped);
    // SPEED-FIRST (post-audit): quality dropped 88 -> 75. The output here
    // is already binarized to pure black/white, so JPEG artifacts from a
    // lower quality setting are far less visible than they'd be on a
    // photo with real color/gradient content — this mainly just shrinks
    // the upload payload without a meaningfully worse OCR read.
    return Uint8List.fromList(img.encodeJpg(result, quality: 75));
  }

  /// Same as [preprocess], but never throws — returns the original bytes
  /// unchanged if preprocessing fails for any reason, so a bad/unsupported
  /// image never blocks the scan.
  static Uint8List preprocessOrFallback(Uint8List originalBytes) {
    try {
      return preprocess(originalBytes);
    } catch (_) {
      return originalBytes;
    }
  }

  /// Pure function version of the old multi-pass adjustment step —
  /// exposure, contrast, highlight/shadow/white/black correction. Takes
  /// raw r/g/b in, returns adjusted r/g/b out, with NO buffer allocation.
  /// Called per-neighbor-pixel inside the single fused pass below, so the
  /// "adjust" step never needs its own full-image copy.
  static List<int> _adjustPixel(int r, int g, int b) {
    r = (r + 15).clamp(0, 255);
    g = (g + 15).clamp(0, 255);
    b = (b + 14).clamp(0, 255);

    r = ((r - 128) * 1.25 + 128).round().clamp(0, 255);
    g = ((g - 128) * 1.25 + 128).round().clamp(0, 255);
    b = ((b - 128) * 1.25 + 128).round().clamp(0, 255);

    if (r > 180) r = (r - 40).clamp(0, 255);
    if (g > 180) g = (g - 40).clamp(0, 255);
    if (b > 180) b = (b - 40).clamp(0, 255);

    if (r < 80) r = (r + 15).clamp(0, 255);
    if (g < 80) g = (g + 15).clamp(0, 255);
    if (b < 80) b = (b + 15).clamp(0, 255);

    if (r > 220) r = (r - 20).clamp(0, 255);
    if (g > 220) g = (g - 20).clamp(0, 255);
    if (b > 220) b = (b - 20).clamp(0, 255);

    if (r < 60) r = (r + 30).clamp(0, 255);
    if (g < 60) g = (g + 30).clamp(0, 255);
    if (b < 60) b = (b + 30).clamp(0, 255);

    final luminance = (0.299 * r + 0.587 * g + 0.114 * b).round();
    r = (luminance + (r - luminance) * 0.85).round().clamp(0, 255);
    g = (luminance + (g - luminance) * 0.85).round().clamp(0, 255);
    b = (luminance + (b - luminance) * 0.85).round().clamp(0, 255);

    return [r, g, b];
  }

  /// Single fused pass using a 3-row sliding cache of ADJUSTED pixels.
  /// Naively recomputing [_adjustPixel] for all 9 neighbors of every
  /// output pixel would call it ~9x more than necessary (each pixel is
  /// a neighbor of up to 9 different output pixels). Instead, this keeps
  /// only the 3 most recent rows of already-adjusted values in memory —
  /// each source pixel gets adjusted exactly ONCE as the scan advances,
  /// then reused for every output pixel that needs it as a neighbor.
  /// Net result: one full-image traversal, one output allocation, and
  /// O(width) extra memory for the row cache — not O(width*height).
  static img.Image _fusedSharpenAndBinarize(img.Image src) {
    final width = src.width;
    final height = src.height;
    final out = img.Image(width: width, height: height);

    const kernel = [0, -1, 0, -1, 5, -1, 0, -1, 0];

    // rows[i] holds the adjusted [r,g,b] triples for one source row.
    final rows = List<List<List<int>>>.generate(
      3,
      (_) => List.generate(width, (_) => const [0, 0, 0]),
    );

    List<List<int>> adjustRow(int y) {
      final row = List<List<int>>.generate(width, (x) {
        final p = src.getPixel(x, y);
        return _adjustPixel(p.r.toInt(), p.g.toInt(), p.b.toInt());
      });
      return row;
    }

    // Seed the cache with the first two rows (y=0 duplicated as the
    // "row above" for the top edge, then y=0, y=1).
    rows[0] = adjustRow(0);
    rows[1] = rows[0];
    if (height > 1) rows[2] = adjustRow(1);

    for (var y = 0; y < height; y++) {
      // rows[0] = y-1 (or y if y==0), rows[1] = y, rows[2] = y+1 (or y if last row)
      for (var x = 0; x < width; x++) {
        if (x == 0 || y == 0 || x == width - 1 || y == height - 1) {
          final adj = rows[1][x];
          final lum = (0.299 * adj[0] + 0.587 * adj[1] + 0.114 * adj[2])
              .round();
          final bw = lum > 128 ? 255 : 0;
          out.setPixelRgb(x, y, bw, bw, bw);
          continue;
        }

        var r = 0, g = 0, b = 0;
        var ki = 0;
        for (var ry = 0; ry < 3; ry++) {
          for (var dx = -1; dx <= 1; dx++) {
            final adj = rows[ry][x + dx];
            r += adj[0] * kernel[ki];
            g += adj[1] * kernel[ki];
            b += adj[2] * kernel[ki];
            ki++;
          }
        }

        final rc = r.clamp(0, 255);
        final gc = g.clamp(0, 255);
        final bc = b.clamp(0, 255);
        final lum = (0.299 * rc + 0.587 * gc + 0.114 * bc).round();
        final bw = lum > 128 ? 255 : 0;
        out.setPixelRgb(x, y, bw, bw, bw);
      }

      // Slide the window down by one row for the next iteration.
      if (y + 2 < height) {
        rows[0] = rows[1];
        rows[1] = rows[2];
        rows[2] = adjustRow(y + 2);
      }
    }

    return out;
  }
}
