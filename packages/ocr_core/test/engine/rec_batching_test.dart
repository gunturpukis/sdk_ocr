import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ocr_core/src/engine/ctc_decoder.dart';
import 'package:ocr_core/src/engine/image_preprocessing.dart';
import 'package:ocr_core/src/engine/inference_session.dart';
import 'package:ocr_core/src/engine/model_manager.dart';
import 'package:ocr_core/src/engine/paddle_ocr_engine.dart';
import 'package:ocr_core/src/models/model_manifest.dart';

void main() {
  group('CtcDecoder.decodeBatch', () {
    // Dict: class 1='A', 2='B', 3='C' (class 0 = blank CTC).
    const dict = ['A', 'B', 'C'];

    /// Strip 0 → 'AB' (t0=A 0.9, t1=dup, t2=blank, t3=B 0.8)
    /// Strip 1 → 'C'  (t1=C 0.7, sisanya blank)
    Float32List buildData() {
      final data = Float32List(2 * 5 * 4);
      data[0 * 5 * 4 + 0 * 4 + 1] = 0.9; // k0,t0,'A'
      data[0 * 5 * 4 + 1 * 4 + 1] = 0.9; // k0,t1,'A' duplikat → dilewati
      data[0 * 5 * 4 + 3 * 4 + 2] = 0.8; // k0,t3,'B'
      data[1 * 5 * 4 + 1 * 4 + 3] = 0.7; // k1,t1,'C'
      return data;
    }

    test('layout [K,T,C] ter-decode urut per strip', () {
      final lines = CtcDecoder.decodeBatch(
        TensorOutput(data: buildData(), shape: [2, 5, 4]),
        2,
        dict,
      );
      expect(lines, hasLength(2));
      expect(lines[0].text, 'AB');
      expect(lines[0].confidence, closeTo((0.9 + 0.8) / 2, 1e-6));
      expect(lines[1].text, 'C');
      expect(lines[1].confidence, closeTo(0.7, 1e-6));
    });

    test('layout [T,K,C] (transposed export) ter-decode sama', () {
      final src = buildData();
      final data = Float32List(2 * 5 * 4);
      for (var k = 0; k < 2; k++) {
        for (var t = 0; t < 5; t++) {
          for (var c = 0; c < 4; c++) {
            data[t * 2 * 4 + k * 4 + c] = src[k * 5 * 4 + t * 4 + c];
          }
        }
      }
      final lines = CtcDecoder.decodeBatch(
        TensorOutput(data: data, shape: [5, 2, 4]),
        2,
        dict,
      );
      expect(lines, hasLength(2));
      expect(lines[0].text, 'AB');
      expect(lines[1].text, 'C');
    });

    test('shape tidak cocok dengan expectedCount melempar ArgumentError', () {
      expect(
        () => CtcDecoder.decodeBatch(
          TensorOutput(data: Float32List(3 * 5 * 4), shape: [3, 5, 4]),
          2,
          dict,
        ),
        throwsArgumentError,
      );
    });
  });

  group('RecognitionPreprocessor.concatBatch', () {
    TensorInput makeInput(double fill) {
      final data = Float32List(3 * 48 * 320);
      for (var i = 0; i < data.length; i++) {
        data[i] = fill;
      }
      return TensorInput(data: data, shape: [1, 3, 48, 320]);
    }

    test('satu input dikembalikan apa adanya', () {
      final input = makeInput(1.0);
      expect(identical(RecognitionPreprocessor.concatBatch([input]), input), isTrue);
    });

    test('K input jadi tensor [K,3,48,320] urut', () {
      final batch = RecognitionPreprocessor.concatBatch(
        [makeInput(1.0), makeInput(2.0), makeInput(3.0)],
      );
      expect(batch.shape, [3, 3, 48, 320]);
      expect(batch.data.length, 3 * 3 * 48 * 320);
      expect(batch.data[0], 1.0);
      expect(batch.data[3 * 48 * 320], 2.0);
      expect(batch.data[2 * 3 * 48 * 320], 3.0);
    });

    test('shape berbeda melempar ArgumentError', () {
      final a = makeInput(1.0);
      final b = TensorInput(data: Float32List(2 * 3 * 48 * 320), shape: [2, 3, 48, 320]);
      expect(() => RecognitionPreprocessor.concatBatch([a, b]), throwsArgumentError);
    });
  });

  group('PaddleOcrEngine batched recognition (fake sessions)', () {
    late Directory tempDir;
    late String dictPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ocr_dict');
      dictPath = '${tempDir.path}/dict.txt';
      File(dictPath).writeAsStringSync('A\nB\nC\n');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    img.Image twoLineImage() {
      final image = img.Image(width: 480, height: 400);
      img.fill(image, color: img.ColorRgb8(255, 255, 255));
      img.drawString(image, 'LINE ONE', font: img.arial24, x: 50, y: 42);
      img.drawString(image, 'LINE TWO', font: img.arial24, x: 50, y: 210);
      return image;
    }

    Future<PaddleOcrEngine> buildEngine(_FakeRecSession rec, _FakeDetSession det) async {
      var created = 0;
      final engine = PaddleOcrEngine(
        modelManifestUrl: 'unused',
        modelManager: _FakeModelManager(dictPath),
        sessionFactory: () {
          created++;
          return created == 1 ? det : rec;
        },
      );
      await engine.initialize();
      return engine;
    }

    test('2 box → 1 panggilan run() dengan batch K=2, hasil urut', () async {
      final rec = _FakeRecSession();
      final det = _FakeDetSession(416, 480);
      final engine = await buildEngine(rec, det);

      final result = await engine.recognize(
        Uint8List.fromList(img.encodeJpg(twoLineImage())),
      );

      // Dua baris teks → dua strip → HARUS satu panggilan batch k=2.
      expect(rec.batchSizes, [2]);
      expect(result.success, isTrue);
      expect(result.rawText, 'AB\nAB');
      expect(result.confidence, closeTo(85.0, 0.1));

      await engine.dispose();
    });

    test('model tanpa dynamic batch → fallback per-strip, hasil identik', () async {
      final rec = _FakeRecSession(failBatch: true);
      final det = _FakeDetSession(416, 480);
      final engine = await buildEngine(rec, det);

      final result = await engine.recognize(
        Uint8List.fromList(img.encodeJpg(twoLineImage())),
      );

      // Batch gagal → fallback: setiap run() hanya 1 strip.
      expect(rec.batchSizes, everyElement(1));
      expect(result.success, isTrue);
      expect(result.rawText, 'AB\nAB');

      await engine.dispose();
    });
  });
}

/// Det session palsu: prob map 416x480 berisi dua rectangle terang (dua
/// baris teks) — meniru output model DB untuk gambar dua baris.
class _FakeDetSession implements InferenceSession {
  final int mapH;
  final int mapW;
  _FakeDetSession(this.mapH, this.mapW);

  @override
  Future<void> load(String modelPath) async {}

  @override
  Future<TensorOutput> run(TensorInput input) async {
    final data = Float32List(mapH * mapW);
    void rect(int y0, int y1, int x0, int x1) {
      for (var y = y0; y <= y1; y++) {
        for (var x = x0; x <= x1; x++) {
          data[y * mapW + x] = 1.0;
        }
      }
    }

    rect(40, 69, 50, 249);
    rect(200, 229, 50, 349);
    return TensorOutput(data: data, shape: [1, 1, mapH, mapW]);
  }

  @override
  Future<void> dispose() async {}
}

/// Rec session palsu: setiap strip menghasilkan CTC 'AB' (class 1 lalu 2).
/// Mencatat ukuran batch tiap run() untuk assert; [failBatch] mensimulasikan
/// model tanpa dukungan dynamic batch.
class _FakeRecSession implements InferenceSession {
  final bool failBatch;
  final List<int> batchSizes = [];
  _FakeRecSession({this.failBatch = false});

  @override
  Future<void> load(String modelPath) async {}

  @override
  Future<TensorOutput> run(TensorInput input) async {
    final k = input.shape[0];
    if (k > 1 && failBatch) {
      throw StateError('dynamic batch tidak didukung (simulasi)');
    }
    batchSizes.add(k);
    final data = Float32List(k * 3 * 4);
    for (var b = 0; b < k; b++) {
      final base = b * 3 * 4;
      data[base + 0 * 4 + 1] = 0.9; // 'A'
      data[base + 2 * 4 + 2] = 0.8; // 'B'
    }
    return TensorOutput(data: data, shape: [k, 3, 4]);
  }

  @override
  Future<void> dispose() async {}
}

class _FakeModelManager implements ModelManager {
  final String dictPath;
  _FakeModelManager(this.dictPath);

  @override
  Future<ModelPaths> ensureModelsReady({
    void Function(double progress)? onProgress,
    void Function(int attempt, int maxAttempts)? onRetry,
  }) async {
    return ModelPaths(det: 'det.onnx', rec: 'rec.onnx', dict: dictPath);
  }
}
