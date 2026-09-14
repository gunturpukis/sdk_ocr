import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'cloud/cloud_datasource.dart';
import 'engine/ocr_engine.dart';
import 'models/ocr_result.dart';

/// Kebijakan routing hybrid: gambar besar & padat teks dikenal paling
/// lambat DAN paling tidak akurat di jalur on-device (WASM single-thread,
/// hasil benchmark), jadi lebih menguntungkan langsung cloud-first.
class CloudFirstPolicy {
  final bool enabled;
  final int maxOnDeviceSide;

  const CloudFirstPolicy({
    this.enabled = false,
    this.maxOnDeviceSide = 1000,
  });

  ///true kalau gambar harus dirouting cloud-first berdasarkan
  /// dimensi header gambar (peek murah, tanpa full decode).
  bool shouldRouteCloudFirst(Uint8List imageBytes) {
    if (!enabled) return false;
    final dims = _peekDimensions(imageBytes);
    if (dims == null) return false; // format tak dikenal → biarkan on-device
    final longSide = math.max(dims.$1, dims.$2);
    return longSide > maxOnDeviceSide;
  }

  /// Baca dimensi dari header gambar tanpa decode penuh.
  static (int, int)? _peekDimensions(Uint8List bytes) {
    try {
      final decoder = img.findDecoderForData(bytes);
      if (decoder == null) return null;
      final info = decoder.startDecode(bytes);
      if (info == null) return null;
      return (info.width, info.height);
    } catch (_) {
      return null;
    }
  }
}

class OcrRepository {
  final OcrEngine _onDevice;
  final CloudDataSource _cloud;
  final double confidenceThreshold;
  final CloudFirstPolicy cloudFirstPolicy;
  final void Function(String message)? logger;

  bool _onDeviceReady = false;

  OcrRepository(
    this._onDevice,
    this._cloud, {
    this.confidenceThreshold = 85.0,
    this.cloudFirstPolicy = const CloudFirstPolicy(),
    this.logger,
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
    if (forceCloudOnly ||
        !_onDeviceReady ||
        cloudFirstPolicy.shouldRouteCloudFirst(imageBytes)) {
      return _cloud.recognize(imageBytes);
    }

    final onDeviceResult = await _onDevice.recognize(imageBytes);

    if (onDeviceResult.success && onDeviceResult.confidence >= confidenceThreshold) {
      return onDeviceResult;
    }

    logger?.call(
      'on-device gagal (code=${onDeviceResult.error?.code}, detail=${onDeviceResult.error?.detail}, '
      'success=${onDeviceResult.success}, confidence=${onDeviceResult.confidence.toStringAsFixed(1)}) '
      '→ fallback ke cloud',
    );
    return _cloud.recognize(imageBytes);
  }

  Future<void> dispose() => _onDevice.dispose();
}
