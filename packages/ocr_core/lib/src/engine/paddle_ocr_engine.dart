import 'dart:typed_data';
 
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
 
import '../models/ocr_result.dart';
import 'ctc_decoder.dart';
import 'detection_postprocessing.dart';
import 'image_preprocessing.dart';
import 'inference_session.dart';
import 'local_text_reader.dart';
import 'model_manager.dart';
import 'ocr_engine.dart';

class PaddleOcrEngine implements OcrEngine {
  final ModelManager _modelManager;
  final InferenceSession Function() _createSession;
 
  InferenceSession? _detSession;
  InferenceSession? _recSession;
  List<String> _dict = [];
  bool _ready = false;
 
  PaddleOcrEngine({
    required String modelManifestUrl,
    ModelManager? modelManager,
    InferenceSession Function()? sessionFactory,
  })  : _modelManager = modelManager ?? ModelManagerImpl(manifestUrl: modelManifestUrl),
        _createSession = sessionFactory ?? InferenceSessionImpl.new;
 
  @override
  Future<void> initialize({
    void Function(double progress)? onModelDownloadProgress,
    void Function(int attempt, int maxAttempts)? onRetry,
  }) async {
    final paths = await _modelManager.ensureModelsReady(
      onProgress: onModelDownloadProgress,
      onRetry: onRetry,
    );
 
    _detSession = _createSession();
    await _detSession!.load(paths.det);
 
    _recSession = _createSession();
    await _recSession!.load(paths.rec);
 
    _dict = await _loadDict(paths.dict);
    _ready = true;
  }
 
  Future<List<String>> _loadDict(String dictPathOrUrl) async {
    return DictLoader.load(dictPathOrUrl);
  }
 
  @override
  Future<OcrResult> recognize(Uint8List imageBytes) async {
    if (!_ready || _detSession == null || _recSession == null) {
      return const OcrResult(
        success: false,
        source: OcrSource.onDevice,
        confidence: 0,
        rawText: '',
        error: OcrError(
          code: 'ENGINE_NOT_INITIALIZED',
          detail: 'Panggil initialize() sebelum recognize()',
        ),
      );
    }
 
    final stopwatch = Stopwatch()..start();
 
    final image = img.decodeImage(imageBytes);
    if (image == null) {
      return const OcrResult(
        success: false,
        source: OcrSource.onDevice,
        confidence: 0,
        rawText: '',
        error: OcrError(code: 'INVALID_IMAGE', detail: 'Gagal decode gambar'),
      );
    }
 
    final (detInput, resizeRatio) = DetectionPreprocessor.process(image);
    final detOutput = await _detSession!.run(detInput);
    final boxes = DetectionPostprocessor.process(detOutput, resizeRatio);
 
    if (boxes.isEmpty) {
      return OcrResult(
        success: false,
        source: OcrSource.onDevice,
        confidence: 0,
        rawText: '',
        error: const OcrError(code: 'NO_TEXT_DETECTED', detail: 'Tidak ada teks terdeteksi'),
        processingTimeMs: stopwatch.elapsedMilliseconds,
      );
    }
 
    final sortedBoxes = [...boxes]..sort((a, b) => a.y.compareTo(b.y));
 
    final lines = <String>[];
    final confidences = <double>[];
 
    for (final box in sortedBoxes) {
      final crop = img.copyCrop(
        image,
        x: box.x,
        y: box.y,
        width: box.width.clamp(1, image.width - box.x),
        height: box.height.clamp(1, image.height - box.y),
      );
 
      final recInput = RecognitionPreprocessor.process(crop);
      final recOutput = await _recSession!.run(recInput);
      final recognized = CtcDecoder.decode(recOutput, _dict);
 
      if (recognized.text.trim().isEmpty) continue;
 
      lines.add(recognized.text);
      confidences.add(recognized.confidence);
    }
 
    stopwatch.stop();
 
    if (lines.isEmpty) {
      return OcrResult(
        success: false,
        source: OcrSource.onDevice,
        confidence: 0,
        rawText: '',
        error: const OcrError(
          code: 'NO_TEXT_DETECTED',
          detail: 'Box terdeteksi tapi tidak ada teks terbaca',
        ),
        processingTimeMs: stopwatch.elapsedMilliseconds,
      );
    }
 
    final avgConfidence = confidences.reduce((a, b) => a + b) / confidences.length;
 
    return OcrResult(
      success: true,
      source: OcrSource.onDevice,
      confidence: avgConfidence * 100,
      rawText: lines.join('\n'),
      processingTimeMs: stopwatch.elapsedMilliseconds,
    );
  }
 
  @override
  Future<void> dispose() async {
    await _detSession?.dispose();
    await _recSession?.dispose();
    _ready = false;
  }
}
 
class DictLoader {
  static Future<List<String>> load(String pathOrUrl) async {
    final content = pathOrUrl.startsWith('http')
        ? await _fetchViaHttp(pathOrUrl)
        : await _readLocalFile(pathOrUrl);
    return content.split('\n').where((l) => l.trim().isNotEmpty).toList();
  }
 
  static Future<String> _fetchViaHttp(String url) async {
    final response = await http.get(
      Uri.parse(url),
      headers: {'ngrok-skip-browser-warning': 'true'},
    );
    if (response.statusCode != 200) {
      throw Exception('Gagal fetch dictionary dari $url (HTTP ${response.statusCode})');
    }
    return response.body;
  }
 
  static Future<String> _readLocalFile(String path) =>
      LocalTextReaderImpl().readAsString(path);
}