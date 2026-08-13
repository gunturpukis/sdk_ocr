import 'dart:math' as math;
import 'dart:typed_data';

import 'inference_session.dart';

class DetectedBox {
  final int x;
  final int y;
  final int width;
  final int height;
  final double score;

  const DetectedBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.score,
  });
}

/// Postprocessing output model deteksi DB (Differentiable Binarization).
///
/// CATATAN PENTING: implementasi asli PaddleOCR memakai OpenCV
/// `findContours` + `minAreaRect` untuk dapat box yang bisa miring
/// (rotated rect), lalu "unclip" pakai Vatti clipping algorithm via
/// pyclipper. Versi ini disederhanakan jadi axis-aligned bounding box
/// (tidak mendukung teks miring) memakai connected-component labeling
/// manual, karena port pyclipper+minAreaRect ke Dart murni adalah task
/// tersendiri yang cukup besar. Cukup untuk dokumen yang di-scan relatif
/// lurus (kasus umum KTP/dokumen dengan guide frame di UI), tapi perlu
/// ditingkatkan kalau nanti banyak kasus teks miring signifikan.
class DetectionPostprocessor {
  static const _binaryThreshold = 0.3;
  static const _boxScoreThreshold = 0.5;
  static const _minBoxSize = 4; // px, dalam skala peta probabilitas
  static const _unclipRatio = 1.5;

  static List<DetectedBox> process(TensorOutput output, double resizeRatio) {
    final shape = output.shape; // [1, 1, H, W]
    final h = shape[shape.length - 2];
    final w = shape[shape.length - 1];
    final probMap = output.data;

    final visited = List<bool>.filled(h * w, false);
    final boxes = <DetectedBox>[];

    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final idx = y * w + x;
        if (visited[idx] || probMap[idx] < _binaryThreshold) continue;

        final component = _floodFill(probMap, visited, w, h, x, y);
        if (component.length < _minBoxSize * _minBoxSize) continue;

        final box = _boundingBoxFromComponent(component, w, probMap);
        if (box.score < _boxScoreThreshold) continue;

        boxes.add(_unclip(box, resizeRatio));
      }
    }

    return boxes;
  }

  static List<int> _floodFill(
    Float32List probMap,
    List<bool> visited,
    int w,
    int h,
    int startX,
    int startY,
  ) {
    final stack = <int>[startY * w + startX];
    final component = <int>[];
    visited[startY * w + startX] = true;

    while (stack.isNotEmpty) {
      final idx = stack.removeLast();
      component.add(idx);

      final x = idx % w;
      final y = idx ~/ w;

      const dx = [1, -1, 0, 0];
      const dy = [0, 0, 1, -1];

      for (var d = 0; d < 4; d++) {
        final nx = x + dx[d];
        final ny = y + dy[d];
        if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;

        final nIdx = ny * w + nx;
        if (visited[nIdx] || probMap[nIdx] < _binaryThreshold) continue;

        visited[nIdx] = true;
        stack.add(nIdx);
      }
    }

    return component;
  }

  static DetectedBox _boundingBoxFromComponent(
    List<int> component,
    int w,
    Float32List probMap,
  ) {
    var minX = 1 << 30, minY = 1 << 30, maxX = -1, maxY = -1;
    var scoreSum = 0.0;

    for (final idx in component) {
      final x = idx % w;
      final y = idx ~/ w;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      scoreSum += probMap[idx];
    }

    return DetectedBox(
      x: minX,
      y: minY,
      width: maxX - minX + 1,
      height: maxY - minY + 1,
      score: scoreSum / component.length,
    );
  }

  /// Perbesar box sedikit (unclip) — DB cenderung memprediksi area sedikit
  /// lebih kecil dari teks aslinya, jadi perlu di-expand supaya tidak
  /// terpotong saat crop untuk model rekognisi.
  static DetectedBox _unclip(DetectedBox box, double resizeRatio) {
    final area = box.width * box.height;
    final perimeter = 2 * (box.width + box.height);
    final expandDistance = area * _unclipRatio / math.max(perimeter, 1);

    final newX = ((box.x - expandDistance) / resizeRatio).round();
    final newY = ((box.y - expandDistance) / resizeRatio).round();
    final newW = ((box.width + 2 * expandDistance) / resizeRatio).round();
    final newH = ((box.height + 2 * expandDistance) / resizeRatio).round();

    return DetectedBox(
      x: math.max(0, newX),
      y: math.max(0, newY),
      width: math.max(1, newW),
      height: math.max(1, newH),
      score: box.score,
    );
  }
}
