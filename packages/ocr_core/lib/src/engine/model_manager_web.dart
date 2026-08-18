
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
 
import 'package:crypto/crypto.dart';
import 'package:web/web.dart' as web;
 
import '../models/model_manifest.dart';
import 'model_manager.dart';
import 'retry_policy.dart';
 
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
    final versionMatches = localVersion == manifest.version;
 
    final entries = manifest.models.entries.toList();
    final bytesByKey = <String, Uint8List>{};
 
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
 
      Uint8List? cachedBytes;
      if (versionMatches) {
        cachedBytes = await _readFromCache(cache, entry.value);
      }
 
      if (cachedBytes != null) {
        bytesByKey[entry.key] = cachedBytes;
        onProgress?.call((i + 1) / entries.length);
        continue;
      }
 
      final bytes = await _retryPolicy.execute(
        () => _fetchVerifyAndCache(
          cache,
          entry.value,
          (fileProgress) => onProgress?.call((i + fileProgress) / entries.length),
        ),
        retryIf: _isRetryableNetworkError,
        onRetry: onRetry,
      );
      bytesByKey[entry.key] = bytes;
    }
 
    if (!versionMatches) {
      await _writeLocalVersion(cache, manifest.version);
    }
 
    return ModelPaths(
      det: _createBlobUrl(bytesByKey['det']!),
      rec: _createBlobUrl(bytesByKey['rec']!),
      dict: manifest.models['dict']!.url,
    );
  }
 
  Future<ModelManifest> _fetchManifest() async {
    final response = await _fetchWithNgrokHeader(manifestUrl);
    if (response.status != 200) {
      throw OcrModelException('Gagal mengambil manifest model (HTTP ${response.status})');
    }
    final text = await response.text().toDart;
    return ModelManifest.fromJson(jsonDecode(text.toDart) as Map<String, dynamic>);
  }
 
  Future<Uint8List> _fetchVerifyAndCache(
    web.Cache cache,
    ModelEntry entry,
    void Function(double)? onProgress,
  ) async {
    final response = await _fetchWithNgrokHeader(entry.url);
    if (response.status != 200) {
      throw OcrModelException('Gagal download ${entry.url} (HTTP ${response.status})');
    }
 
    final buffer = await response.clone().arrayBuffer().toDart;
    final bytes = buffer.toDart.asUint8List();
    onProgress?.call(1.0);
 
    final actualHash = sha256.convert(bytes).toString();
    if (actualHash != entry.sha256) {
      throw OcrModelException(
        'Checksum tidak cocok untuk ${entry.url} -- file kemungkinan corrupt.',
      );
    }
 
    await cache.put(entry.url.toJS as web.RequestInfo, response).toDart;
    return bytes;
  }
  
  Future<web.Response> _fetchWithNgrokHeader(String url) async {
    final headers = web.Headers();
    headers.set('ngrok-skip-browser-warning', 'true');
    final init = web.RequestInit(headers: headers);
    return await web.window.fetch(url.toJS, init).toDart as web.Response;
  }
 
  Future<Uint8List?> _readFromCache(web.Cache cache, ModelEntry entry) async {
    final match = await cache.match(entry.url.toJS as web.RequestInfo).toDart;
    if (match == null) return null;
 
    final response = match as web.Response;
    final buffer = await response.arrayBuffer().toDart;
    final bytes = buffer.toDart.asUint8List();
 
    final actualHash = sha256.convert(bytes).toString();
    if (actualHash != entry.sha256) return null; // cache corrupt, perlu fetch ulang
 
    return bytes;
  }
 
  String _createBlobUrl(Uint8List bytes) {
    final blobParts = [bytes.toJS].toJS;
    final blob = web.Blob(blobParts);
    return web.URL.createObjectURL(blob);
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
 
  bool _isRetryableNetworkError(Object error) => error is OcrModelException;
}