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
      print('❌ PREPARE GAGAL (WEB): $e');
      print(stack.toString());
      _readiness = OcrReadiness.cloudOnlyFallback;
      _scheduleBackgroundRetry();
    }
    return _readiness;
  }

  Future<OcrResult> scan(Uint8List imageBytes) => _repository.recognize(
        imageBytes,
        forceCloudOnly: _readiness == OcrReadiness.cloudOnlyFallback,
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
