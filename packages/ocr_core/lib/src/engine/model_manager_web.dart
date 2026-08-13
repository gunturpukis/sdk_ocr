import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:web/web.dart' as web;

import '../models/model_manifest.dart';
import 'model_manager.dart';
import 'retry_policy.dart';

/// Menyiapkan model PaddleOCR di Web lewat Cache Storage API. Berbeda dari
/// mobile: "path" model di Web adalah URL asli (bukan path filesystem) —
/// begitu URL sudah ter-cache, fetch() berikutnya ke URL yang sama
/// otomatis diambil dari cache oleh browser tanpa request jaringan baru.
class ModelManagerImpl implements ModelManager {
  static const _cacheName = 'ocr-models-v1';
  static const _versionKey = 'https://ocr-models.local/.version';

  final String manifestUrl;
  final RetryPolicy _retryPolicy;

  ModelManagerImpl({
    required this.manifestUrl,
    RetryPolicy? retryPolicy,
  }) : _retryPolicy = retryPolicy ?? const RetryPolicy(maxAttempts: 3);

  @override
  Future<ModelPaths> ensureModelsReady({
    void Function(double progress)? onProgress,
    void Function(int attempt, int maxAttempts)? onRetry,
  }) async {
    final manifest = await _retryPolicy.execute(
      _fetchManifest,
      retryIf: _isRetryableNetworkError,
      onRetry: onRetry,
    );

    final cache = await web.window.caches.open(_cacheName).toDart as web.Cache;
    final localVersion = await _readLocalVersion(cache);

    if (localVersion == manifest.version && await _allCached(cache, manifest)) {
      return _resolvePaths(manifest);
    }

    final entries = manifest.models.entries.toList();
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      await _retryPolicy.execute(
        () => _fetchAndCache(
          cache,
          entry.value,
          (fileProgress) => onProgress?.call((i + fileProgress) / entries.length),
        ),
        retryIf: _isRetryableNetworkError,
        onRetry: onRetry,
      );
    }

    await _writeLocalVersion(cache, manifest.version);
    return _resolvePaths(manifest);
  }

  Future<ModelManifest> _fetchManifest() async {
    final response = await web.window.fetch(manifestUrl.toJS).toDart as web.Response;
    if (response.status != 200) {
      throw OcrModelException('Gagal mengambil manifest model (HTTP ${response.status})');
    }
    final text = await response.text().toDart;
    return ModelManifest.fromJson(jsonDecode(text.toDart) as Map<String, dynamic>);
  }

  Future<void> _fetchAndCache(
    web.Cache cache,
    ModelEntry entry,
    void Function(double)? onProgress,
  ) async {
    final response = await web.window.fetch(entry.url.toJS).toDart as web.Response;
    if (response.status != 200) {
      throw OcrModelException('Gagal download ${entry.url} (HTTP ${response.status})');
    }

    final buffer = await response.clone().arrayBuffer().toDart;
    final bytes = buffer.toDart.asUint8List();
    onProgress?.call(1.0);

    final actualHash = sha256.convert(bytes).toString();
    if (actualHash != entry.sha256) {
      throw OcrModelException(
        'Checksum tidak cocok untuk ${entry.url} — file kemungkinan corrupt.',
      );
    }

    await cache.put(entry.url.toJS as web.RequestInfo, response).toDart;
  }

  Future<bool> _allCached(web.Cache cache, ModelManifest manifest) async {
    for (final entry in manifest.models.entries) {
      final match = await cache.match(entry.value.url.toJS as web.RequestInfo).toDart;
      if (match == null) return false;
    }
    return true;
  }

  Future<String?> _readLocalVersion(web.Cache cache) async {
    final match = await cache.match(_versionKey.toJS as web.RequestInfo).toDart;
    if (match == null) return null;
    final response = match as web.Response;
    return (await response.text().toDart).toDart;
  }

  Future<void> _writeLocalVersion(web.Cache cache, String version) async {
    final response = web.Response(version.toJS as web.BodyInit, web.ResponseInit(status: 200));
    await cache.put(_versionKey.toJS as web.RequestInfo, response).toDart;
  }

  ModelPaths _resolvePaths(ModelManifest manifest) => ModelPaths(
        det: manifest.models['det']!.url,
        rec: manifest.models['rec']!.url,
        dict: manifest.models['dict']!.url,
      );

  bool _isRetryableNetworkError(Object error) => error is OcrModelException;
}
