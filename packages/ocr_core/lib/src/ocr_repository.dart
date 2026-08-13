import 'dart:typed_data';

import 'cloud/cloud_datasource.dart';
import 'engine/ocr_engine.dart';
import 'models/ocr_result.dart';

class OcrRepository {
  final OcrEngine _onDevice;
  final CloudDataSource _cloud;
  final double confidenceThreshold;

  bool _onDeviceReady = false;

  OcrRepository(
    this._onDevice,
    this._cloud, {
    this.confidenceThreshold = 85.0,
  });

  bool get isOnDeviceReady => _onDeviceReady;

  Future<void> initializeOnDevice({
    void Function(double progress)? onModelDownloadProgress,
    void Function(int attempt, int maxAttempts)? onRetry,
  }) async {
    await _onDevice.initialize(
      onModelDownloadProgress: onModelDownloadProgress,
      onRetry: onRetry,
    );
    _onDeviceReady = true;
  }

  /// [forceCloudOnly] di-pass eksplisit dari OcrClient (bukan baca state
  /// global di sini) supaya OcrRepository gampang di-unit-test — cukup
  /// inject true/false langsung tanpa perlu mock proses initializeOnDevice()
  /// yang async dan ada network call.
  Future<OcrResult> recognize(
    Uint8List imageBytes, {
    bool forceCloudOnly = false,
  }) async {
    if (forceCloudOnly || !_onDeviceReady) {
      return _cloud.recognize(imageBytes);
    }

    final onDeviceResult = await _onDevice.recognize(imageBytes);

    if (onDeviceResult.success && onDeviceResult.confidence >= confidenceThreshold) {
      return onDeviceResult;
    }

    return _cloud.recognize(imageBytes);
  }

  Future<void> dispose() => _onDevice.dispose();
}
