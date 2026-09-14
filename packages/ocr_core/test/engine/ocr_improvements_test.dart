import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ocr_core/src/engine/detection_postprocessing.dart';
import 'package:ocr_core/src/engine/image_preprocessing.dart';
import 'package:ocr_core/src/engine/input_normalizer.dart';
import 'package:ocr_core/src/ocr_repository.dart';

void main() {
  group('DetectionPostprocessor.mergeSameLine', () {
    DetectedBox box(int x, int y, int w, int h, [double score = 0.9]) =>
        DetectedBox(x: x, y: y, width: w, height: h, score: score);

    test('dua fragmen sebaris & berdekatan digabung menjadi satu box', () {
      final merged = DetectionPostprocessor.mergeSameLine([
        box(10, 20, 60, 24),
        box(90, 22, 70, 24), // gap 20px, tinggi rata 24 → <= 2x → merge
      ]);
      expect(merged, hasLength(1));
      expect(merged.first.x, 10);
      expect(merged.first.y, 20);
      expect(merged.first.width, 150);
      expect(merged.first.height, 26);
    });

    test('box di baris berbeda tidak digabung', () {
      final merged = DetectionPostprocessor.mergeSameLine([
        box(10, 20, 60, 24),
        box(10, 100, 60, 24), // jarak vertikal jauh
      ]);
      expect(merged, hasLength(2));
    });

    test('box sebaris tapi jarak antar-kolom jauh tidak digabung', () {
      final merged = DetectionPostprocessor.mergeSameLine([
        box(10, 20, 60, 24),
        box(400, 22, 70, 24), // gap 330px >> 2x tinggi
      ]);
      expect(merged, hasLength(2));
    });

    test('merge berantai: tiga fragmen sebaris jadi satu box', () {
      final merged = DetectionPostprocessor.mergeSameLine([
        box(10, 20, 40, 24),
        box(70, 21, 40, 24),
        box(130, 22, 40, 24),
      ]);
      expect(merged, hasLength(1));
      expect(merged.first.width, 160);
      expect(merged.first.score, closeTo(0.9, 1e-9));
    });

    test('box tunggal & list kosong tidak berubah', () {
      expect(DetectionPostprocessor.mergeSameLine([]), isEmpty);
      expect(DetectionPostprocessor.mergeSameLine([box(1, 2, 3, 4)]), hasLength(1));
    });
  });

  group('RecognitionPreprocessor.processMulti', () {
    img.Image textImage(int w, int h) {
      final image = img.Image(width: w, height: h);
      img.fill(image, color: img.ColorRgb8(255, 255, 255));
      img.drawString(image, 'ABCDEF', font: img.arial24, x: 4, y: h ~/ 2 - 12);
      return image;
    }

    test('crop dengan aspect dalam batas menghasilkan satu tensor', () {
      final inputs = RecognitionPreprocessor.processMulti(textImage(200, 48));
      expect(inputs, hasLength(1));
      expect(inputs.first.shape, [1, 3, 48, 320]);
    });

    test('crop lebar dipecah menjadi strip tanpa squash', () {
      // Aspect 2000x48 = 41.7 >> 320/48 = 6.67 → harus dipecah >= 7 strip.
      final inputs = RecognitionPreprocessor.processMulti(textImage(2000, 48));
      expect(inputs.length, greaterThanOrEqualTo(7));
      for (final t in inputs) {
        expect(t.shape[2], 48);
        expect(t.shape[3], 320);
      }
    });
  });

  group('InputNormalizer', () {
    test('PNG 1-bit dari fixture berhasil di-decode (sebelumnya exception)', () {
      final bytes = File('test/fixtures/phototest_1bit.png').readAsBytesSync();
      final image = InputNormalizer.process(Uint8List.fromList(bytes));
      expect(image, isNotNull);
      expect(image!.numChannels, 3);
      expect(image.format, img.Format.uint8);
      expect(image.width, 640);
      expect(image.height, 480);
      // Latar harus putih penuh (bukan nilai 0/1 sisa Format.uint1).
      expect(image.getPixel(0, 0).r.toInt(), greaterThan(200));
    });

    test('JPEG 8-bit normal tetap bisa di-decode', () {
      final bytes = File('test/fixtures/phototest_8bit.jpg').readAsBytesSync();
      final image = InputNormalizer.process(Uint8List.fromList(bytes));
      expect(image, isNotNull);
    });

    test('bytes bukan gambar mengembalikan null', () {
      expect(InputNormalizer.process(Uint8List.fromList([1, 2, 3, 4])), isNull);
    });

    test('gambar full-range tidak di-stretch', () {
      final image = img.Image(width: 64, height: 64);
      img.fill(image, color: img.ColorRgb8(0, 0, 0));
      img.drawString(image, 'A', font: img.arial24, x: 8, y: 8, color: img.ColorRgb8(255, 255, 255));
      final out = InputNormalizer.process(Uint8List.fromList(img.encodePng(image)));
      // Titik hitam 0 → tidak memenuhi syarat "faded", tidak boleh berubah.
      expect(out!.getPixel(0, 0).r, 0);
    });

    test('gambar pudar di-stretch ke full range', () {
      final image = img.Image(width: 64, height: 64);
      img.fill(image, color: img.ColorRgb8(220, 220, 220));
      img.drawString(image, 'A', font: img.arial24, x: 8, y: 8, color: img.ColorRgb8(60, 60, 60));
      final out = InputNormalizer.process(Uint8List.fromList(img.encodePng(image)));
      // Setelah stretch 2%-98%: teks gelap mendekati 0, latar terang
      // mendekati 255. Cek rentang penuh supaya tidak bergantung posisi
      // stroke glyph.
      var minR = 255, maxR = 0;
      for (final p in out!) {
        final r = p.r.toInt();
        if (r < minR) minR = r;
        if (r > maxR) maxR = r;
      }
      expect(minR, lessThan(40));
      expect(maxR, greaterThan(200));
    });
  });

  group('CloudFirstPolicy', () {
    Uint8List jpegOfSize(int w, int h) {
      final image = img.Image(width: w, height: h);
      img.fill(image, color: img.ColorRgb8(255, 255, 255));
      return Uint8List.fromList(img.encodeJpg(image));
    }

    test('gambar kecil tidak dirouting cloud-first', () {
      const policy = CloudFirstPolicy(enabled: true, maxOnDeviceSide: 1000);
      expect(policy.shouldRouteCloudFirst(jpegOfSize(640, 480)), isFalse);
    });

    test('gambar besar (sisi panjang > batas) dirouting cloud-first', () {
      const policy = CloudFirstPolicy(enabled: true, maxOnDeviceSide: 1000);
      expect(policy.shouldRouteCloudFirst(jpegOfSize(1600, 1200)), isTrue);
    });

    test('policy disabled tidak pernah routing cloud-first', () {
      const policy = CloudFirstPolicy(enabled: false, maxOnDeviceSide: 100);
      expect(policy.shouldRouteCloudFirst(jpegOfSize(1600, 1200)), isFalse);
    });
  });
}
