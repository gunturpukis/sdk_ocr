import 'dart:typed_data';

import '../models/ocr_result.dart';

abstract class OcrEngine {
  Future<void> initialize({
    void Function(double progress)? onModelDownloadProgress,
    void Function(int attempt, int maxAttempts)? onRetry,
  });

  Future<OcrResult> recognize(Uint8List imageBytes);

  Future<void> dispose();
}
