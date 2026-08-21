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
/// Callback logger — consumer app hook ini ke Crashlytics/Sentry/console
/// sendiri. SDK tidak pernah `print()` langsung supaya tidak flooding
/// console production dan supaya error observability jadi keputusan
/// consumer, bukan dipaksa dari dalam SDK.
typedef OcrLogger = void Function(String message, {Object? error, StackTrace? stackTrace});

class OcrClient {
  final OcrRepository _repository;
  final Duration backgroundRetryDelay;
  final OcrLogger? _logger;

  OcrReadiness _readiness = OcrReadiness.cloudOnlyFallback;
  bool _backgroundRetryInProgress = false;
  bool _disposed = false;

  OcrClient({
    required String apiKey,
    required String baseUrl,
    required String modelManifestUrl,
    double confidenceThreshold = 85.0,
    this.backgroundRetryDelay = const Duration(minutes: 5),
    OcrEngine? engineOverride, // untuk testing, inject mock engine
    OcrLogger? logger,
  })  : _logger = logger,
        _repository = OcrRepository(
          engineOverride ?? PaddleOcrEngine(modelManifestUrl: modelManifestUrl),
          CloudDataSource(apiKey: apiKey, baseUrl: baseUrl),
          confidenceThreshold: confidenceThreshold,
        );

  OcrReadiness get readiness => _readiness;

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
    } catch (e, stack) {
      _logger?.call('OcrClient.prepare() gagal, fallback ke cloud-only', error: e, stackTrace: stack);
      _readiness = OcrReadiness.cloudOnlyFallback;
      _scheduleBackgroundRetry();
    }
    return _readiness;
  }

  Future<OcrResult> scan(Uint8List imageBytes) {
    if (_disposed) {
      throw StateError('OcrClient sudah di-dispose(). Buat instance baru untuk scan lagi.');
    }
    return _repository.recognize(
      imageBytes,
      forceCloudOnly: _readiness == OcrReadiness.cloudOnlyFallback,
    );
  }

  void _scheduleBackgroundRetry() {
    if (_backgroundRetryInProgress || _disposed) return;
    _backgroundRetryInProgress = true;

    Future.delayed(backgroundRetryDelay, () async {
      // Instance bisa saja sudah di-dispose() sebelum timer ini jalan
      // (mis. user keluar dari halaman scan) — jangan sentuh repository lagi.
      if (_disposed) {
        _backgroundRetryInProgress = false;
        return;
      }
      try {
        await _repository.initializeOnDevice();
        _readiness = OcrReadiness.onDeviceReady;
      } catch (e, stack) {
        _logger?.call('Background retry initializeOnDevice() masih gagal', error: e, stackTrace: stack);
        // akan dicoba lagi lain kali prepare() dipanggil manual
      } finally {
        _backgroundRetryInProgress = false;
      }
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    await _repository.dispose();
  }
}
