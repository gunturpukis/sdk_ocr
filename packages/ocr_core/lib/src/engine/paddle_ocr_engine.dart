import 'dart:typed_data';
 
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
 
import '../models/ocr_result.dart';
import 'ctc_decoder.dart';
import 'input_normalizer.dart';
import 'detection_postprocessing.dart';
import 'image_preprocessing.dart';
import 'inference_session.dart';
import 'local_text_reader.dart';
import 'model_manager.dart';
import 'ocr_engine.dart';

class PaddleOcrEngine implements OcrEngine {
  final ModelManager _modelManager;
  final InferenceSession Function() _createSession;
  final void Function(String message)? logger;
 
  InferenceSession? _detSession;
  InferenceSession? _recSession;
  List<String> _dict = [];
  bool _ready = false;
 
  PaddleOcrEngine({
    required String modelManifestUrl,
    ModelManager? modelManager,
    InferenceSession Function()? sessionFactory,
    this.logger,
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
 
    // Normalisasi input (decode + ekspansi palette/1-bit → RGB 8-bit +
    // contrast stretch bila perlu). InputNormalizer.process mengembalikan
    // null untuk bytes yang tidak bisa di-decode, termasuk PNG 1-bit yang
    // membuat img.decodeImage() langsung melempar exception.
    final image = InputNormalizer.process(imageBytes);
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
    }    final sortedBoxes = [...boxes]..sort((a, b) => a.y.compareTo(b.y));
 
    // Fase 1: preprocess semua box jadi strip tensor (tanpa squash).
    // Catat strip per box supaya hasil decode bisa direkonstruksi urut.
    final stripsPerBox = <List<TensorInput>>[];
    final allStrips = <TensorInput>[];
    for (final box in sortedBoxes) {
      final crop = img.copyCrop(
        image,
        x: box.x,
        y: box.y,
        width: box.width.clamp(1, image.width - box.x),
        height: box.height.clamp(1, image.height - box.y),
      );
 
      final stripInputs = RecognitionPreprocessor.processMulti(crop);
      stripsPerBox.add(stripInputs);
      allStrips.addAll(stripInputs);
    }
 
    // Fase 2: inference BATCH — K strip diproses dalam SATU panggilan
    // session.run() (input [K,3,48,320]). Semua strip sudah dipad ke
    // 48x320, jadi aman di-stack. Ini memangkas overhead per-call ort-web
    // (setup feeds, transfer tensor, await JS) yang dominan untuk strip
    // pendek, dan memanfaatkan batched matmul di sisi runtime.
    // Batch dibatasi 8 supaya alokasi tensor tetap wajar.
    // Kalau model tidak mendukung dynamic batch (runtime error), jatuh
    // otomatis ke per-strip seperti semula — fallback aman, hasil sama.
    const recBatchSize = 8;
    final stripResults = List<RecognizedLine?>.filled(allStrips.length, null);
    var batchedCalls = 0;
    var fallbackStrips = 0;
    for (var start = 0; start < allStrips.length; start += recBatchSize) {
      final end = (start + recBatchSize) > allStrips.length
          ? allStrips.length
          : start + recBatchSize;
      final chunk = allStrips.sublist(start, end);
      try {
        if (chunk.length == 1) {
          stripResults[start] = CtcDecoder.decode(await _recSession!.run(chunk.single), _dict);
          continue;
        }
        final batchOutput = await _recSession!.run(RecognitionPreprocessor.concatBatch(chunk));
        final decoded = CtcDecoder.decodeBatch(batchOutput, chunk.length, _dict);
        for (var i = 0; i < decoded.length; i++) {
          stripResults[start + i] = decoded[i];
        }
        batchedCalls++;
      } catch (_) {
        // Fallback per-strip (model tanpa dukungan dynamic batch).
        fallbackStrips += chunk.length;
        for (var i = 0; i < chunk.length; i++) {
          stripResults[start + i] = CtcDecoder.decode(await _recSession!.run(chunk[i]), _dict);
        }
      }
    }
    logger?.call(
      'rec batch: ${allStrips.length} strip → $batchedCalls panggilan batch '
      '(fallback per-strip: $fallbackStrips)',
    );
 
    // Fase 3: rekonstruksi baris teks dari hasil strip, urut per box.
    final lines = <String>[];
    final confidences = <double>[];
    var stripCursor = 0;
    for (final strips in stripsPerBox) {
      for (var s = 0; s < strips.length; s++) {
        final recognized = stripResults[stripCursor++];
        if (recognized == null || recognized.text.trim().isEmpty) continue;
 
        lines.add(recognized.text);
        confidences.add(recognized.confidence);
      }
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