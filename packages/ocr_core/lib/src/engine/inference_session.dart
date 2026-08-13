import 'dart:typed_data';

export 'inference_session_stub.dart'
    if (dart.library.io) 'inference_session_mobile.dart'
    if (dart.library.html) 'inference_session_web.dart';

/// Input tensor generik — bentuk NCHW (batch, channel, height, width)
/// dengan data float32 yang sudah dinormalisasi.
class TensorInput {
  final Float32List data;
  final List<int> shape;

  const TensorInput({required this.data, required this.shape});
}

class TensorOutput {
  final Float32List data;
  final List<int> shape;

  const TensorOutput({required this.data, required this.shape});
}

/// Kontrak tipis di atas ONNX Runtime — beda implementasi native per
/// platform (flutter_onnxruntime di mobile, onnxruntime-web via JS
/// interop di Web), tapi caller (PaddleOcrEngine) tidak perlu tahu itu.
abstract class InferenceSession {
  Future<void> load(String modelPath);
  Future<TensorOutput> run(TensorInput input);
  Future<void> dispose();
}
