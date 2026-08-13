
import '../models/model_manifest.dart';
import 'model_manager.dart';
import 'retry_policy.dart';
 
class ModelManagerImpl implements ModelManager {
  ModelManagerImpl({
    required String manifestUrl,
    RetryPolicy? retryPolicy,
  });
 
  @override
  Future<ModelPaths> ensureModelsReady({
    void Function(double progress)? onProgress,
    void Function(int attempt, int maxAttempts)? onRetry,
  }) {
    throw const OcrModelException(
      'Platform tidak didukung — ModelManager cuma punya implementasi '
      'untuk mobile (io) dan web (html).',
    );
  }
}
 






