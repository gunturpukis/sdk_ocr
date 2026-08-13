import '../models/model_manifest.dart';

export 'model_manager_stub.dart'
    if (dart.library.io) 'model_manager_mobile.dart'
    if (dart.library.html) 'model_manager_web.dart';

/// Kontrak untuk menyiapkan model PaddleOCR (download, cache, verifikasi
/// checksum). Implementasi berbeda total antara mobile (filesystem) dan
/// Web (Cache Storage API) — lihat model_manager_mobile.dart / _web.dart.
abstract class ModelManager {
  Future<ModelPaths> ensureModelsReady({
    void Function(double progress)? onProgress,
    void Function(int attempt, int maxAttempts)? onRetry,
  });
}
