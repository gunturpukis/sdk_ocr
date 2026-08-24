import 'dart:async';
import 'dart:typed_data';

import 'cloud/cloud_datasource.dart';
import 'engine/ocr_engine.dart';
import 'engine/paddle_ocr_engine.dart';
import 'models/ocr_result.dart';
import 'ocr_repository.dart';

enum OcrReadiness { onDeviceReady, cloudOnlyFallback }

/// Public API SDK — satu-satunya class yang perlu di-import consumer app.
///
/// ```dart
/// final client = OcrClient(
///   apiKey: 'xxx',
///   baseUrl: 'https://ocr-api.example.com',
///   modelManifestUrl: 'https://cdn.example.com/models/models.json',
/// );
/// await client.prepare();
/// final result = await client.scan(imageBytes);
/// ```
class OcrClient {
  final OcrRepository _repository;
  final Duration backgroundRetryDelay;

  OcrReadiness _readiness = OcrReadiness.cloudOnlyFallback;
  bool _backgroundRetryInProgress = false;

  OcrClient({
    required String apiKey,
    required String baseUrl,
    required String modelManifestUrl,
    double confidenceThreshold = 85.0,
    this.backgroundRetryDelay = const Duration(minutes: 5),
    OcrEngine? engineOverride, // untuk testing, inject mock engine
  }) : _repository = OcrRepository(
          engineOverride ?? PaddleOcrEngine(modelManifestUrl: modelManifestUrl),
          CloudDataSource(apiKey: apiKey, baseUrl: baseUrl),
          confidenceThreshold: confidenceThreshold,
        );

  OcrReadiness get readiness => _readiness;

  /// Siapkan on-device engine (download+load model). Kalau gagal setelah
  /// semua retry habis, TIDAK throw — otomatis masuk mode cloud-only
  /// supaya fitur scan tetap bisa dipakai (cuma butuh koneksi internet
  /// terus selama sesi itu).
  ///
  /// CATATAN SEJARAH: versi awal SDK ini skip on-device sepenuhnya di
  /// Web (waktu itu memang belum ada opsi on-device untuk Web). Setelah
  /// InferenceSession Web (ONNX Runtime Web via JS interop) dibangun,
  /// keputusan itu sudah usang — sekarang Web juga mencoba on-device
  /// dulu sama seperti mobile, baru fallback ke cloud kalau gagal.
  Future<OcrReadiness> prepare({
    void Function(double progress)? onProgress,
    void Function(int attempt, int maxAttempts)? onRetry,
  }) async {
    try {
      await _repository.initializeOnDevice(
        onModelDownloadProgress: onProgress,
        onRetry: onRetry,
      );
      _readiness = OcrReadiness.onDeviceReady;
    } catch (_) {
      _readiness = OcrReadiness.cloudOnlyFallback;
      _scheduleBackgroundRetry();
    }
    return _readiness;
  }

  /// [forceCloud] — pakai ini kalau consumer app SUDAH TAHU dokumen yang
  /// akan di-scan butuh model lebih besar/akurat daripada yang di-device
  /// (misal: NIB, dokumen dengan layout kompleks) — skip on-device sama
  /// sekali, langsung ke Cloud OCR API tanpa nunggu confidence rendah
  /// dulu. Kalau tidak di-set, behavior default tetap hybrid seperti
  /// biasa (coba on-device dulu, fallback ke cloud kalau confidence
  /// rendah atau on-device belum siap).
  Future<OcrResult> scan(Uint8List imageBytes, {bool forceCloud = false}) =>
      _repository.recognize(
        imageBytes,
        forceCloudOnly: forceCloud || _readiness == OcrReadiness.cloudOnlyFallback,
      );

  void _scheduleBackgroundRetry() {
    if (_backgroundRetryInProgress) return;
    _backgroundRetryInProgress = true;

    Future.delayed(backgroundRetryDelay, () async {
      try {
        await _repository.initializeOnDevice();
        _readiness = OcrReadiness.onDeviceReady;
      } catch (_) {
        // masih gagal — akan dicoba lagi lain kali prepare() dipanggil,
        // atau lewat retry background berikutnya kalau ingin di-loop
      } finally {
        _backgroundRetryInProgress = false;
      }
    });
  }

  Future<void> dispose() => _repository.dispose();
}
