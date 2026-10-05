// Tests for what the vision-model OCR path receives and returns: the
// color image prepared for Gemini/Groq, and the per-line `lines` array
// the backend sends back.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pharmacy_management_system/pharmacist/models/prescription_scan_result.dart';
import 'package:pharmacy_management_system/pharmacist/services/image_preprocessor_service.dart';

Uint8List _jpeg(img.Image image) => Uint8List.fromList(img.encodeJpg(image));

void main() {
  group('prepareForVision', () {
    test('caps the longest edge at 2000px and keeps the aspect ratio', () {
      final out = img.decodeImage(
        ImagePreprocessorService.prepareForVision(
          _jpeg(img.Image(width: 3000, height: 4000)),
        ),
      )!;

      expect(out.height, 2000);
      expect(out.width, 1500);
    });

    test('keeps color instead of binarizing', () {
      final source = img.Image(width: 200, height: 200)
        ..clear(img.ColorRgb8(30, 60, 200));
      final out = img.decodeImage(
        ImagePreprocessorService.prepareForVision(_jpeg(source)),
      )!;
      final p = out.getPixel(100, 100);

      expect(p.b, greaterThan(150));
      expect(p.r, lessThan(80));
    });

    test('rotates a photo according to its EXIF orientation', () {
      final source = img.Image(width: 400, height: 100);
      source.exif.imageIfd.orientation = 6; // rotate 90° clockwise
      final out = img.decodeImage(
        ImagePreprocessorService.prepareForVision(_jpeg(source)),
      )!;

      expect(out.width, 100);
      expect(out.height, 400);
    });

    test('fallback variant returns the input unchanged on garbage bytes', () {
      final garbage = Uint8List.fromList([1, 2, 3]);

      expect(
        ImagePreprocessorService.prepareForVisionOrFallback(garbage),
        same(garbage),
      );
    });
  });

  group('OcrLine.listFrom', () {
    test('parses section and legibility', () {
      final lines = OcrLine.listFrom([
        {'text': 'Amoxicilin 500mg #21', 'section': 'medicine', 'legibility': 'partial'},
        {'text': 'Sig: 1 cap TID', 'section': 'instruction', 'legibility': 'clear'},
      ]);

      expect(lines, hasLength(2));
      expect(lines.first.section, 'medicine');
      expect(lines.first.isUncertain, isTrue);
      expect(lines.last.isUncertain, isFalse);
    });

    test('skips malformed entries and tolerates a missing array', () {
      expect(OcrLine.listFrom(null), isEmpty);
      expect(OcrLine.listFrom('nope'), isEmpty);
      expect(
        OcrLine.listFrom([
          'not a map',
          {'text': '   '},
          {'text': 'Losartan 50mg'},
        ]).single.legibility,
        'partial',
      );
    });
  });
}
