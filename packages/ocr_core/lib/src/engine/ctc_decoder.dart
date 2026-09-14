import 'dart:typed_data';

import 'inference_session.dart';

class RecognizedLine {
  final String text;
  final double confidence;

  const RecognizedLine({required this.text, required this.confidence});
}

class CtcDecoder {
  static const _blankIndex = 0; // konvensi PaddleOCR: index 0 = blank/CTC

  /// Decode output rec model untuk SATU gambar, shape [1, T, numClasses].
  static RecognizedLine decode(TensorOutput output, List<String> dict) {
    final shape = output.shape; // [1, T, numClasses]
    final timeSteps = shape[shape.length - 2];
    final numClasses = shape[shape.length - 1];
    return _decodePlane(output.data, 0, timeSteps, numClasses, numClasses, dict);
  }

  /// Decode output rec model untuk BATCH K gambar sekaligus (hasil
  /// session.run dengan input [K, 3, 48, 320]).
  ///
  /// Layout output bisa [K, T, C] (umum) atau [T, K, C] (beberapa export
  /// ONNX mentranspose) — dibedakan lewat [expectedCount] (jumlah strip
  /// yang dikirim). Element (t, k, c) dibaca tanpa copy antar-plane.
  static List<RecognizedLine> decodeBatch(
    TensorOutput output,
    int expectedCount,
    List<String> dict,
  ) {
    final shape = output.shape;
    if (shape.length != 3) {
      throw ArgumentError('Output batch rec harus rank-3, dapat: $shape');
    }

    final data = output.data;
    final lines = <RecognizedLine>[];

    if (shape[0] == expectedCount) {
      // [K, T, C]: plane k mulai di k*T*C, baris t stride C.
      final k = shape[0], t = shape[1], c = shape[2];
      for (var b = 0; b < k; b++) {
        lines.add(_decodePlane(data, b * t * c, t, c, c, dict));
      }
    } else if (shape[1] == expectedCount) {
      // [T, K, C]: plane k mulai di k*C, baris t stride K*C.
      final t = shape[0], k = shape[1], c = shape[2];
      for (var b = 0; b < k; b++) {
        lines.add(_decodePlane(data, b * c, t, c, k * c, dict));
      }
    } else {
      throw ArgumentError(
        'Output batch rec tidak cocok: shape=$shape, expectedCount=$expectedCount',
      );
    }

    return lines;
  }

  /// Decode satu plane CTC. Element (t, c) = data[offset + t * rowStride + c].
  /// Argmax per timestep, skip blank + run duplikat (aturan CTC standar).
  static RecognizedLine _decodePlane(
    Float32List data,
    int offset,
    int timeSteps,
    int numClasses,
    int rowStride,
    List<String> dict,
  ) {
    final chars = <String>[];
    final confidences = <double>[];
    var lastIndex = -1;

    for (var t = 0; t < timeSteps; t++) {
      final rowBase = offset + t * rowStride;
      var bestIndex = 0;
      var bestProb = double.negativeInfinity;

      for (var c = 0; c < numClasses; c++) {
        final prob = data[rowBase + c];
        if (prob > bestProb) {
          bestProb = prob;
          bestIndex = c;
        }
      }

      final isDuplicate = bestIndex == lastIndex;
      lastIndex = bestIndex;

      if (bestIndex == _blankIndex || isDuplicate) continue;

      final charIndex = bestIndex - 1; // geser karena index 0 dipakai blank
      if (charIndex >= 0 && charIndex < dict.length) {
        chars.add(dict[charIndex]);
        confidences.add(bestProb);
      }
    }

    final text = chars.join();
    final avgConfidence =
        confidences.isEmpty ? 0.0 : confidences.reduce((a, b) => a + b) / confidences.length;

    return RecognizedLine(text: text, confidence: avgConfidence);
  }
}
