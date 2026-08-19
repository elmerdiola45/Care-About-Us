import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Fast resize-only preprocessing. No filters, no B&W, no sharpen.
///
/// Downsizes to fit comfortably under OCR.space's 1MB free-tier limit
/// while keeping the image large enough for readable OCR text.

const int _kMaxDim = 1200;
const int _kJpegQuality = 75;

Uint8List preprocessForGemini(Uint8List bytes) {
  return _resizeIfNeeded(bytes);
}

Uint8List preprocessForOcrSpace(Uint8List bytes) {
  return _resizeIfNeeded(bytes);
}

Uint8List _resizeIfNeeded(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null) return bytes;

  if (image.width <= _kMaxDim && image.height <= _kMaxDim) {
    return bytes;
  }

  final scale = _kMaxDim / (image.width > image.height ? image.width : image.height);
  final w = (image.width * scale).round();
  final h = (image.height * scale).round();
  final resized = img.copyResize(image, width: w, height: h);

  return Uint8List.fromList(img.encodeJpg(resized, quality: _kJpegQuality));
}
