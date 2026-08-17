
import 'dart:convert';
import 'dart:io';
 
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
 
import '../models/model_manifest.dart';
import 'model_manager.dart';
import 'retry_policy.dart';
 
/// Menyiapkan model PaddleOCR di Android/iOS: fetch manifest, download
/// tiap file model kalau versi lokal beda atau file corrupt, verifikasi
/// SHA256, simpan ke application support directory.
class ModelManagerImpl implements ModelManager {
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
 
    final dir = await getApplicationSupportDirectory();
    final modelDir = Directory('${dir.path}/ocr_models');
    final localVersion = await _readLocalVersion(modelDir);
 
    if (localVersion == manifest.version && await _allValid(modelDir, manifest)) {
      return _resolvePaths(modelDir, manifest);
    }
 
    await modelDir.create(recursive: true);
 
    final entries = manifest.models.entries.toList();
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      // Nama file lokal HARUS mempertahankan ekstensi asli dari URL
      // (.ort/.onnx/.txt) — ONNX Runtime menentukan format model dari
      // ekstensi file (.ort ditebak sebagai ORT format/FlatBuffers,
      // tanpa ekstensi ditebak sebagai .onnx/protobuf, walau isinya
      // sebenarnya .ort). Simpan tanpa ekstensi = "Protobuf parsing failed".
      final file = File('${modelDir.path}/${entry.key}${_extensionOf(entry.value.url)}');
 
      await _retryPolicy.execute(
        () => _downloadAndVerify(
          entry.value,
          file,
          (fileProgress) => onProgress?.call((i + fileProgress) / entries.length),
        ),
        retryIf: _isRetryableNetworkError,
        onRetry: onRetry,
      );
    }
 
    await _writeLocalVersion(modelDir, manifest.version);
    return _resolvePaths(modelDir, manifest);
  }
 
  Future<ModelManifest> _fetchManifest() async {
    final response = await http.get(Uri.parse(manifestUrl));
    if (response.statusCode != 200) {
      throw OcrModelException(
        'Gagal mengambil manifest model (HTTP ${response.statusCode})',
      );
    }
    return ModelManifest.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }
 
  Future<void> _downloadAndVerify(
    ModelEntry entry,
    File dest,
    void Function(double)? onProgress,
  ) async {
    final request = http.Request('GET', Uri.parse(entry.url));
    final response = await http.Client().send(request);
 
    if (response.statusCode != 200) {
      throw OcrModelException(
        'Gagal download ${entry.url} (HTTP ${response.statusCode})',
      );
    }
 
    final total = response.contentLength ?? entry.sizeBytes;
    var received = 0;
    final sink = dest.openWrite();
 
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress?.call(received / total);
    }
    await sink.close();
 
    final bytes = await dest.readAsBytes();
    final actualHash = sha256.convert(bytes).toString();
 
    if (actualHash != entry.sha256) {
      await dest.delete();
      throw OcrModelException(
        'Checksum tidak cocok untuk ${entry.url} — file kemungkinan '
        'corrupt saat download. Akan dicoba ulang.',
      );
    }
  }
 
  Future<bool> _allValid(Directory dir, ModelManifest manifest) async {
    for (final entry in manifest.models.entries) {
      final file = File('${dir.path}/${entry.key}${_extensionOf(entry.value.url)}');
      if (!await file.exists()) return false;
      final bytes = await file.readAsBytes();
      final hash = sha256.convert(bytes).toString();
      if (hash != entry.value.sha256) return false;
    }
    return true;
  }
 
  /// Ambil ekstensi file dari URL (termasuk titiknya, misal ".ort").
  /// Kalau URL tidak punya ekstensi jelas, kembalikan string kosong
  /// (fallback ke perilaku lama, tanpa ekstensi).
  String _extensionOf(String url) {
    final path = Uri.parse(url).path;
    final lastDot = path.lastIndexOf('.');
    final lastSlash = path.lastIndexOf('/');
    if (lastDot == -1 || lastDot < lastSlash) return '';
    return path.substring(lastDot);
  }
 
  Future<String?> _readLocalVersion(Directory dir) async {
    final versionFile = File('${dir.path}/.version');
    if (!await versionFile.exists()) return null;
    return versionFile.readAsString();
  }
 
  Future<void> _writeLocalVersion(Directory dir, String version) async {
    final versionFile = File('${dir.path}/.version');
    await versionFile.writeAsString(version);
  }
 
  ModelPaths _resolvePaths(Directory dir, ModelManifest manifest) => ModelPaths(
        det: '${dir.path}/det${_extensionOf(manifest.models['det']!.url)}',
        rec: '${dir.path}/rec${_extensionOf(manifest.models['rec']!.url)}',
        dict: '${dir.path}/dict${_extensionOf(manifest.models['dict']!.url)}',
      );
 
  bool _isRetryableNetworkError(Object error) {
    if (error is OcrModelException) return true; // termasuk checksum mismatch
    if (error is SocketException) return true;
    if (error is HttpException) return true;
    return false;
  }
}