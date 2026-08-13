import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'inference_session.dart';

/// Wrapper tipis di atas package `flutter_onnxruntime` (native binding
/// Android + iOS ke ONNX Runtime resmi Microsoft). Model PaddleOCR di sini
/// dibaca dari file lokal yang sudah disiapkan ModelManager, bukan asset
/// bundled — karena model didownload dinamis, bukan ikut APK/IPA.
class InferenceSessionImpl implements InferenceSession {
  final _ort = OnnxRuntime();
  OrtSession? _session;

  @override
  Future<void> load(String modelPath) async {
    _session = await _ort.createSessionFromAsset(modelPath);
  }

  @override
  Future<TensorOutput> run(TensorInput input) async {
    final session = _session;
    if (session == null) {
      throw StateError('InferenceSession belum di-load(). Panggil load() dulu.');
    }

    final inputNames = session.inputNames;
    final ortInput = await OrtValue.fromList(input.data, input.shape);

    final outputs = await session.run({inputNames.first: ortInput});
    final outputTensor = outputs.values.first;

    final rawData = await outputTensor.asFlattenedList();

    return TensorOutput(
      data: Float32List.fromList(rawData.cast<double>()),
      shape: outputTensor.shape,
    );
  }

  @override
  Future<void> dispose() async {
    await _session?.close();
  }
}
