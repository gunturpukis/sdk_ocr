import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Normalisasi input gambar SEBELUM pipeline deteksi/rekognisi.
///
/// Latar belakang (hasil benchmark, lihat catatan repo): `package:image`
/// gagal membaca PNG 1-bit (palette) — `decodeImage()` melempar exception
/// sehingga scan selalu fallback ke cloud. Selain itu, scan pudar dengan
/// rentang tonal sempit menghasilkan deteksi lemah.
///
/// Normalisasi yang dilakukan (murah, sekali per scan):
/// 1. Ekspansi palette/1-bit/gray → RGB 8-bit penuh.
/// 2. Contrast stretch persentil (2%–98%) — HANYA jika rentang tonal
///    sempit dan polaritas normal (teks gelap di atas terang), supaya
///    dokumen dark-mode / inverted tidak dipecahkan secara keliru.
class InputNormalizer {
  /// Batas jumlah sampel luminance untuk estimasi persentil — sampling
  /// grid supaya gambar besar tidak mahal (262k sampel ≈ 512×512).
  static const _maxSamples = 262144;

  /// Rentang persentil untuk stretch. 0.5%/99.5% (bukan 2%/98%): teks
  /// pada dokumen biasanya < 2% dari total pixel, jadi persentil 2% bisa
  /// jatuh di latar dan melewatkan deteksi pudar. 0.5% dari 262k sampel
  /// = ~1300 pixel — cukup robust terhadap outlier tunggal namun tetap
  /// menangkap kehadiran teks.
  static const _lowPercentile = 0.005;
  static const _highPercentile = 0.995;

  /// Stretch hanya diterapkan kalau rentang terdeteksi "pudar": titik
  /// hitam tidak terlalu dekat 0 dan titik putih tidak menyentuh 255,
  /// tapi gap hitam-putih masih jelas (polaritas normal). Dokumen sudah
  /// full-range atau dark-mode tidak diubah.
  static const _fadedBlackMax = 64;
  static const _fadedWhiteMin = 190;
  static const _minPolarGap = 120;

  /// Decode + normalisasi. Return null kalau bytes bukan gambar yang
  /// dikenali (pemanggil melaporkan INVALID_IMAGE).
  static img.Image? process(Uint8List imageBytes) {
    img.Image image;
    try {
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) return null;
      image = decoded;
    } catch (_) {
      // PNG 1-bit (palette) dkk yang membuat decoder lempar exception:
      // coba sekali lagi lewat jalur paksa-decode PNG sebelum menyerah.
      try {
        final decoded = img.decodePng(imageBytes);
        if (decoded == null) return null;
        image = decoded;
      } catch (_) {
        return null;
      }
    }

    // Ekspansi ke RGB 8-bit: PNG 1-bit/gray/palette perlu di-konversi
    // supaya pixel.r/g/b yang dibaca preprocessor punya nilai penuh.
    // PENTING: harus set format: uint8 secara eksplisit — PNG 1-bit
    // decode sebagai Format.uint1, dan convert(numChannels: 3) tanpa
    // format tetap menyimpan nilai 0/1 (bukan 0/255) sehingga seluruh
    // gambar terlihat hitam oleh model deteksi (NO_TEXT_DETECTED).
    if (image.hasPalette || image.numChannels < 3 || image.format != img.Format.uint8) {
      image = image.convert(format: img.Format.uint8, numChannels: 3);
    }

    return _maybeContrastStretch(image);
  }

  static img.Image _maybeContrastStretch(img.Image image) {
    // Sampling grid: langkah disesuaikan agar total sampel <= _maxSamples.
    final totalPixels = image.width * image.height;
    final step = totalPixels <= _maxSamples ? 1 : (totalPixels / _maxSamples).ceil();

    final samples = <int>[];
    for (var y = 0; y < image.height; y += step) {
      for (var x = 0; x < image.width; x += step) {
        samples.add(image.getPixel(x, y).luminance.round());
      }
    }
    if (samples.length < 2) return image;

    samples.sort();
    final lo = samples[(samples.length * _lowPercentile).floor().clamp(0, samples.length - 1)];
    final hi = samples[(samples.length * _highPercentile).floor().clamp(0, samples.length - 1)];

    final isFaded = lo > 0 && lo <= _fadedBlackMax && hi >= _fadedWhiteMin && hi < 255;
    final hasPolarGap = (hi - lo) >= _minPolarGap;
    if (!isFaded || !hasPolarGap) return image;

    final range = math_max(hi - lo, 1);
    for (final pixel in image) {
      final lum = pixel.luminance.toDouble();
      final stretched = ((lum - lo) * 255.0 / range).round().clamp(0, 255);
      // Skala semua channel dengan rasio yang sama supaya hue tetap.
      final scale = lum <= 0 ? 0.0 : stretched / lum;
      pixel
        ..r = (pixel.r * scale).round().clamp(0, 255)
        ..g = (pixel.g * scale).round().clamp(0, 255)
        ..b = (pixel.b * scale).round().clamp(0, 255);
    }
    return image;
  }

  static int math_max(int a, int b) => a > b ? a : b;
}
