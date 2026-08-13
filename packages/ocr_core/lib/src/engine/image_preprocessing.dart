import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'inference_session.dart';

/// Preprocessing gambar untuk model deteksi teks PaddleOCR (algoritma DB).
/// Model DB butuh input dengan dimensi kelipatan 32, dinormalisasi dengan
/// mean/std standar ImageNet (dipakai PaddleOCR untuk training).
class DetectionPreprocessor {
  static const _mean = [0.485, 0.456, 0.406];
  static const _std = [0.229, 0.224, 0.225];
  static const _maxSide = 960; // batas ukuran supaya inference tidak lambat

  /// Return tensor input + faktor resize (dibutuhkan untuk map koordinat
  /// box hasil deteksi balik ke ukuran gambar asli).
  static (TensorInput, double) process(img.Image original) {
    final longSide = original.width > original.height ? original.width : original.height;
    final ratio = longSide > _maxSide ? _maxSide / longSide : 1.0;

    var targetW = (original.width * ratio).round();
    var targetH = (original.height * ratio).round();

    // bulatkan ke kelipatan 32 (requirement arsitektur model DB)
    targetW = _roundToMultiple(targetW, 32);
    targetH = _roundToMultiple(targetH, 32);

    final resized = img.copyResize(original, width: targetW, height: targetH);
    final data = Float32List(3 * targetH * targetW);

    // susun ke layout NCHW: channel-major, bukan pixel-major
    for (var y = 0; y < targetH; y++) {
      for (var x = 0; x < targetW; x++) {
        final pixel = resized.getPixel(x, y);
        final r = pixel.r / 255.0;
        final g = pixel.g / 255.0;
        final b = pixel.b / 255.0;

        final idx = y * targetW + x;
        data[idx] = (r - _mean[0]) / _std[0];
        data[targetH * targetW + idx] = (g - _mean[1]) / _std[1];
        data[2 * targetH * targetW + idx] = (b - _mean[2]) / _std[2];
      }
    }

    final tensor = TensorInput(data: data, shape: [1, 3, targetH, targetW]);
    return (tensor, ratio);
  }

  static int _roundToMultiple(int value, int multiple) {
    final remainder = value % multiple;
    if (remainder == 0) return value == 0 ? multiple : value;
    return value + (multiple - remainder);
  }
}

/// Preprocessing crop hasil deteksi untuk model rekognisi teks. Model rec
/// PaddleOCR butuh tinggi tetap (biasanya 48px), lebar mengikuti aspect
/// ratio (dengan batas maksimum + padding).
class RecognitionPreprocessor {
  static const _targetHeight = 48;
  static const _maxWidth = 320;

  static TensorInput process(img.Image crop) {
    final ratio = _targetHeight / crop.height;
    var targetW = (crop.width * ratio).round().clamp(1, _maxWidth);

    final resized = img.copyResize(crop, width: targetW, height: _targetHeight);
    final data = Float32List(3 * _targetHeight * _maxWidth); // padded ke max width

    for (var y = 0; y < _targetHeight; y++) {
      for (var x = 0; x < _maxWidth; x++) {
        double r = 0.5, g = 0.5, b = 0.5; // padding = abu-abu netral (0 setelah normalisasi)

        if (x < targetW) {
          final pixel = resized.getPixel(x, y);
          r = pixel.r / 255.0;
          g = pixel.g / 255.0;
          b = pixel.b / 255.0;
        }

        final idx = y * _maxWidth + x;
        // PaddleOCR rec model biasanya normalisasi sederhana: (px - 0.5) / 0.5
        data[idx] = (r - 0.5) / 0.5;
        data[_targetHeight * _maxWidth + idx] = (g - 0.5) / 0.5;
        data[2 * _targetHeight * _maxWidth + idx] = (b - 0.5) / 0.5;
      }
    }

    return TensorInput(data: data, shape: [1, 3, _targetHeight, _maxWidth]);
  }
}
