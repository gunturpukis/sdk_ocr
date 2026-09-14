
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';
 
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
// Test-harness dependency (transitif via ocr_core): fetch gambar benchmark
// nyata yang diserve oleh models server lokal.
import 'package:http/http.dart' as http;
import 'package:ocr_core/ocr_core.dart';
import 'package:web/web.dart' as web;
 
// CATATAN VALIDASI (baca sebelum deploy):
// File ini ditulis tanpa akses compiler Flutter Web di sandbox saya, sama
// seperti disclaimer di README utama repo ini. Bagian yang PALING perlu
// dicek ulang terhadap versi `package:web` yang benar-benar Anda pakai:
//   - signature `web.window.addEventListener` / `EventListener` typedef
//   - `MessageEvent.data` (tipe JSAny? -> cast ke JSString)
//   - `web.window.parent` (WindowProxy non-null di spec, tapi cek versi)
// Anggap sebagai starting point protokol postMessage, bukan kode final.
//
// PERUBAHAN DARI VERSI SEBELUMNYA:
// `OcrScanScreen` dari `ocr_ui` sudah TIDAK dipakai di sini. Widget itu
// black-box (source-nya tidak tersedia saat file ini disesuaikan), jadi
// tidak bisa dipastikan implementasi takePicture()-nya sudah benar untuk
// web (mirror, resolusi, dst). Sebagai gantinya, host app ini sekarang
// punya capture flow sendiri (_ScanHomeScreen + _LiveCameraCaptureScreen)
// yang sudah menerapkan fix mirror & resolusi yang sama dengan demo
// sebelumnya, lalu memanggil `client.scan()` langsung.
//
// REKOMENDASI: terapkan fix yang sama (flip bytes saat mirrored, cek
// previewSize, tap-to-focus dengan try-catch) di source asli
// `OcrScanScreen` pada package `ocr_ui`, supaya semua consumer lain yang
// masih memakai widget itu langsung ikut kebagian fix-nya juga — jangan
// cuma di host app ini.
 
void main() {
  runApp(const OcrWebHostApp());
}
 
/// App Flutter Web tunggal yang dibungkus sebagai `<iframe>` oleh host app
/// (React/Next.js/vanilla apa pun) — lihat `web-sdk-bridge/` untuk wrapper
/// JS/React di sisi host.
///
/// FORMAT postMessage — FLAT, bukan nested (penting, sempat jadi bug):
/// ```js
/// window.postMessage(JSON.stringify({
///   type: 'OCR_INIT',
///   apiKey: '...',
///   baseUrl: '...',
///   modelManifestUrl: '...',
/// }), '*');
/// ```
///
/// Alur:
/// 1. Host kirim `OCR_INIT` (format di atas).
/// 2. App ini bikin `OcrClient`, panggil `prepare()`, lalu tampilkan
///    `_ScanHomeScreen` (capture kustom, bukan lagi `OcrScanScreen`).
/// 3. Tiap hasil scan dikirim balik ke host via
///    `postMessage({type:'OCR_RESULT', payload: ocrResult.toJson()})`.
///
/// PENTING SOAL KEAMANAN: `baseUrl` di sini SEHARUSNYA menunjuk ke backend
/// proxy milik Anda sendiri (bukan cloud OCR provider langsung), supaya API
/// key asli tidak pernah keluar dari server dan tidak pernah lewat
/// postMessage / terlihat di devtools browser pengguna. `apiKey` di sini
/// HANYA untuk fase testing lokal langsung ke services/ocr-cloud-api.
class OcrWebHostApp extends StatefulWidget {
  const OcrWebHostApp({super.key});
 
  @override
  State<OcrWebHostApp> createState() => _OcrWebHostAppState();
}
 
class _OcrWebHostAppState extends State<OcrWebHostApp> {
  // Default hybrid: on-device dulu (butuh onnxruntime-web — script tag
  // SUDAH aktif di web/index.html), fallback cloud kalau confidence di
  // bawah threshold / init on-device gagal. Bridge (web-sdk-bridge)
  // mengirim `forceCloud` di OCR_INIT; nilai di bawah hanya fallback
  // kalau field tidak ada di message.
  bool _forceCloud = false;
  OcrClient? _client;
  String? _initError;

  /// Test hook: counter request scan dari host (OCR_SCAN). _ScanHomeScreen
  /// listen ini dan menjalankan scan gambar sintetis tanpa UI dialog.
  final ValueNotifier<int> _scanRequests = ValueNotifier(0);

  /// Test hook: request benchmark suite (OCR_BENCH) — value = config message.
  final ValueNotifier<Map<String, dynamic>?> _benchRequest = ValueNotifier(null);
 
  @override
  void initState() {
    super.initState();
    web.window.addEventListener('message', _handleMessage.toJS);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _postToHost({'type': 'OCR_HOST_READY'});
      print('🟢 OCR_HOST_READY dikirim');
    });
  }
 
  @override
  void dispose() {
    web.window.removeEventListener('message', _handleMessage.toJS);
    _scanRequests.dispose();
    _benchRequest.dispose();
    _client?.dispose();
    super.dispose();
  }
 
  void _handleMessage(web.Event event) {
    final messageEvent = event as web.MessageEvent;
    final rawData = messageEvent.data;
    if (rawData is! JSString) {
      print('⚠️ Message bukan JSString, diabaikan');
      return;
    }
 
    late final Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(rawData.toDart);
      if (decoded is! Map) {
        print('⚠️ Format message bukan JSON object, diabaikan');
        return;
      }
      data = Map<String, dynamic>.from(decoded);
    } catch (e) {
      print('❌ Gagal parse message JSON: $e');
      return;
    }
 
    print('📨 MESSAGE TYPE: ${data['type']}');
    switch (data['type']) {
      case 'OCR_INIT':
        _handleOcrInit(data); // 'data' itu sendiri sudah flat — LIHAT dokumentasi di atas class
      case 'OCR_DISPOSE':
        _client?.dispose();
        _client = null;
      case 'OCR_SCAN':
        // TEST HOOK: trigger scan gambar sintetis tanpa dialog kamera/file,
        // supaya pipeline tensor bisa di-automasi dari luar (harness).
        _handleScanRequest();
      case 'OCR_BENCH':
        // TEST HOOK: jalankan benchmark suite latency & confidence.
        _handleBenchRequest(data);
    }
  }

  /// Trigger scan sintetis via _ScanHomeScreen. Kalau layar scan belum
  /// terpasang (init belum selesai), balas error jelas daripada diam.
  void _handleScanRequest() {
    final client = _client;
    if (client == null) {
      _postToHost({
        'type': 'OCR_ERROR',
        'message': 'OCR_SCAN ditolak: client belum selesai init (kirim OCR_INIT dulu, tunggu OCR_READY)',
      });
      return;
    }
    _scanRequests.value++;
  }

  /// Test hook: mulai benchmark suite (OCR_BENCH). Config dibawa lewat
  /// notifier supaya _ScanHomeScreen bisa membacanya saat listener aktif.
  void _handleBenchRequest(Map<String, dynamic> data) {
    if (_client == null) {
      _postToHost({
        'type': 'OCR_ERROR',
        'message': 'OCR_BENCH ditolak: kirim OCR_INIT dulu dan tunggu OCR_READY',
      });
      return;
    }
    _benchRequest.value = Map<String, dynamic>.from(data);
  }
 
  Future<void> _handleOcrInit(Map<String, dynamic> data) async {
    if (_client != null) {
      print('⚠️ OcrClient sudah diinisialisasi, OCR_INIT diabaikan');
      return;
    }
 
    try {
      // PENTING: baca langsung dari 'data' (top-level), BUKAN dari
      // data['payload'] — format OCR_INIT itu flat. Baca dari 'payload'
      // yang gak ada di message akan selalu balik {} dan bikin apiKey
      // (dan field lain) jadi kosong tanpa error yang jelas.
      final apiKey = data['apiKey'] as String? ?? '';
      final baseUrl = data['baseUrl'] as String?;
      final modelManifestUrl = data['modelManifestUrl'] as String?;
      final confidenceThreshold = (data['confidenceThreshold'] as num?)?.toDouble() ?? 85.0;
      final forceCloud = data['forceCloud'] as bool? ?? false;

      // JANGAN log isi/panjang apiKey ke console — log ini terlihat di
      // DevTools browser user. Cukup indikator ada/tidaknya.
      print('BASE URL: $baseUrl');
      print('MODEL MANIFEST: $modelManifestUrl');
      print('FORCE CLOUD: $forceCloud (apiKey ${apiKey.isEmpty ? "❌ KOSONG — scan cloud akan 401" : "✅ diset"})');
 
      if (baseUrl == null || baseUrl.isEmpty) {
        throw Exception('baseUrl wajib diisi');
      }
      if (modelManifestUrl == null || modelManifestUrl.isEmpty) {
        throw Exception('modelManifestUrl wajib diisi');
      }
 
      final client = OcrClient(
        apiKey: apiKey,
        baseUrl: baseUrl,
        modelManifestUrl: modelManifestUrl,
        confidenceThreshold: confidenceThreshold,
        logger: (message, {error, stackTrace}) {
          _postToHost({
            'type': 'OCR_LOG',
            'message': message,
            if (error != null) 'error': error.toString(),
          });
        },
      );
 
      if (!mounted) {
        client.dispose();
        return;
      }
      setState(() {
        _client = client;
        _forceCloud = forceCloud;
        _initError = null;
      });
 
      await client.prepare(
        onProgress: (p) => _postToHost({'type': 'OCR_MODEL_PROGRESS', 'progress': p}),
      );
 
      print('✅ OCR READY: ${client.readiness.name}');
      _postToHost({'type': 'OCR_READY', 'readiness': client.readiness.name});
    } catch (e, stackTrace) {
      print('❌ OCR_INIT ERROR: $e');
      print(stackTrace);
      if (!mounted) return;
      setState(() => _initError = e.toString());
      _postToHost({'type': 'OCR_ERROR', 'message': e.toString()});
    }
  }
 
  void _postToHost(Map<String, dynamic> message) {
    web.window.parent?.postMessage(jsonEncode(message).toJS, '*'.toJS);
  }
 
  @override
  Widget build(BuildContext context) {
    final client = _client;
    final error = _initError;
 
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: error != null
          ? Scaffold(
              backgroundColor: Colors.black,
              body: Center(
                child: Text(error, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
              ),
            )
          : client == null
              ? const Scaffold(
                  backgroundColor: Colors.black,
                  body: Center(child: CircularProgressIndicator(color: Colors.white)),
                )
              : _ScanHomeScreen(
                  client: client,
                  forceCloud: _forceCloud,
                  scanRequests: _scanRequests,
                  benchRequest: _benchRequest,
                  onResult: (result) => _postToHost({'type': 'OCR_RESULT', 'payload': result.toJson()}),
                  onPost: _postToHost,
                ),
    );
  }
}
 
/// Menggantikan `OcrScanScreen` bawaan `ocr_ui`. Menyediakan dua cara
/// capture:
/// - Native camera (`image_picker` → `<input capture>`) — kualitas
///   setara galeri, direkomendasikan untuk OCR akurasi tinggi.
/// - Live preview (`camera` / `camera_web`) — UI kustom dengan overlay
///   guide, tapi resolusinya dibatasi video track dan butuh mirror-fix
///   di web (lihat `_LiveCameraCaptureScreen`).
class _ScanHomeScreen extends StatefulWidget {
  const _ScanHomeScreen({
    required this.client,
    required this.forceCloud,
    required this.scanRequests,
    required this.benchRequest,
    required this.onResult,
    required this.onPost,
  });

  final OcrClient client;

  /// true = selalu scan via cloud API; false = hybrid on-device dulu
  /// (lihat catatan di _OcrWebHostAppState).
  final bool forceCloud;

  /// Test hook: increment = minta satu scan gambar sintetis (tanpa dialog).
  final ValueNotifier<int> scanRequests;

  /// Test hook: value berubah = jalankan benchmark suite (payload = config).
  final ValueNotifier<Map<String, dynamic>?> benchRequest;

  final void Function(OcrResult result) onResult;

  /// Saluran postMessage mentah (dipakai OCR_BENCH untuk log & hasil).
  final void Function(Map<String, dynamic> message) onPost;
 
  @override
  State<_ScanHomeScreen> createState() => _ScanHomeScreenState();
}
 
class _ScanHomeScreenState extends State<_ScanHomeScreen> {
  bool _isScanning = false;
  bool _isBenching = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    widget.scanRequests.addListener(_onExternalScanRequest);
    widget.benchRequest.addListener(_onExternalBenchRequest);
  }

  @override
  void didUpdateWidget(_ScanHomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scanRequests != widget.scanRequests) {
      oldWidget.scanRequests.removeListener(_onExternalScanRequest);
      widget.scanRequests.addListener(_onExternalScanRequest);
    }
    if (oldWidget.benchRequest != widget.benchRequest) {
      oldWidget.benchRequest.removeListener(_onExternalBenchRequest);
      widget.benchRequest.addListener(_onExternalBenchRequest);
    }
  }

  @override
  void dispose() {
    widget.scanRequests.removeListener(_onExternalScanRequest);
    widget.benchRequest.removeListener(_onExternalBenchRequest);
    super.dispose();
  }

  void _onExternalBenchRequest() {
    final cfg = widget.benchRequest.value;
    if (cfg == null || _isScanning || _isBenching) return;
    _runBenchSuite(cfg);
  }

  /// Benchmark suite: latency & confidence per gambar, beberapa repetisi.
  /// Menggunakan jalur produksi client.scan() penuh (preprocess → det →
  /// crop → rec → CTC). OcrResult.processingTimeMs mengukur pipeline
  /// engine saja; wallMs tambah overhead decode+await di atasnya.
  Future<void> _runBenchSuite(Map<String, dynamic> cfg) async {
    _isBenching = true;
    final totalSw = Stopwatch()..start();
    try {
      final reps = (cfg['reps'] as num?)?.toInt() ?? 3;
      final realBase = (cfg['realImageBaseUrl'] as String?) ?? 'http://localhost:9090/bench';
      final realImages = (cfg['realImages'] as List?)?.cast<String>() ?? const <String>[];

      widget.onPost({'type': 'OCR_LOG', 'message': 'BENCH: mulai (reps=$reps, real=${realImages.length})'});

      final cases = <(String, Uint8List)>[
        ..._buildSyntheticBenchImages(),
      ];
      for (final name in realImages) {
        try {
          final resp = await http.get(Uri.parse('$realBase/$name'));
          if (resp.statusCode != 200) {
            widget.onPost({'type': 'OCR_LOG', 'message': 'BENCH: fetch $name gagal HTTP ${resp.statusCode}'});
            continue;
          }
          cases.add(('real_$name', resp.bodyBytes));
        } catch (e) {
          widget.onPost({'type': 'OCR_LOG', 'message': 'BENCH: fetch $name error: $e'});
        }
      }

      final records = <Map<String, dynamic>>[];
      var globalFirst = true;
      for (final caseEntry in cases) {
        for (var rep = 1; rep <= reps; rep++) {
          final sw = Stopwatch()..start();
          OcrResult result;
          try {
            result = await widget.client.scan(caseEntry.$2);
          } catch (e) {
            result = OcrResult(
              success: false,
              source: OcrSource.onDevice,
              confidence: 0,
              rawText: '',
              error: OcrError(code: 'SCAN_THROW', detail: e.toString()),
            );
          }
          sw.stop();
          records.add({
            'case': caseEntry.$1,
            'rep': rep,
            'warmup': globalFirst,
            'ok': result.success,
            'source': result.source == OcrSource.cloud ? 'cloud' : 'onDevice',
            'confidence': result.confidence,
            'engineMs': result.processingTimeMs,
            'wallMs': sw.elapsedMilliseconds,
            'imageBytes': caseEntry.$2.length,
            'charCount': result.rawText.length,
            'errorCode': result.error?.code,
            'text': result.rawText.length > 120 ? result.rawText.substring(0, 120) : result.rawText,
          });
          globalFirst = false;
          widget.onPost({
            'type': 'OCR_LOG',
            'message': 'BENCH: ${caseEntry.$1} #$rep → ok=${result.success} '
                'src=${result.source.name} conf=${result.confidence.toStringAsFixed(1)} '
                'wall=${sw.elapsedMilliseconds}ms engine=${result.processingTimeMs}ms',
          });
        }
      }

      widget.onPost({
        'type': 'OCR_BENCH_DONE',
        'reps': reps,
        'totalMs': totalSw.elapsedMilliseconds,
        'records': records,
      });
    } finally {
      _isBenching = false;
    }
  }

  /// Suite gambar sintetis untuk benchmark: spektrum kesulitan dari
  /// teks besar bersih sampai noise/rotasi/kontras rendah/kosong.
  List<(String, Uint8List)> _buildSyntheticBenchImages() {
    Uint8List encode(img.Image image) => Uint8List.fromList(img.encodeJpg(image, quality: 92));
    final cases = <(String, Uint8List)>[];

    // 1. Teks besar bersih — baseline paling mudah.
    final c1 = img.Image(width: 640, height: 400);
    img.fill(c1, color: img.ColorRgb8(255, 255, 255));
    img.drawString(c1, 'HELLO WORLD 123', font: img.arial48, x: 40, y: 150, color: img.ColorRgb8(0, 0, 0));
    cases.add(('synth_clean_large', encode(c1)));

    // 2. Teks kecil 14px — simulasi dokumen dipindai dengan teks rapat.
    final c2 = img.Image(width: 480, height: 320);
    img.fill(c2, color: img.ColorRgb8(255, 255, 255));
    img.drawString(c2, 'Invoice No: 2024-0817', font: img.arial14, x: 24, y: 48, color: img.ColorRgb8(0, 0, 0));
    img.drawString(c2, 'Total: USD 1,250.00', font: img.arial14, x: 24, y: 78, color: img.ColorRgb8(0, 0, 0));
    img.drawString(c2, 'Thank you for your business', font: img.arial14, x: 24, y: 108, color: img.ColorRgb8(0, 0, 0));
    cases.add(('synth_small_14px', encode(c2)));

    // 3. Formulir multi-baris 24px.
    final c3 = img.Image(width: 640, height: 480);
    img.fill(c3, color: img.ColorRgb8(255, 255, 255));
    img.drawString(c3, 'Name: Budi Santoso', font: img.arial24, x: 40, y: 60, color: img.ColorRgb8(0, 0, 0));
    img.drawString(c3, 'Address: Jl. Merdeka No. 45', font: img.arial24, x: 40, y: 110, color: img.ColorRgb8(0, 0, 0));
    img.drawString(c3, 'Phone: +62 812 3456 7890', font: img.arial24, x: 40, y: 160, color: img.ColorRgb8(0, 0, 0));
    img.drawString(c3, 'DOB: 17-08-1945', font: img.arial24, x: 40, y: 210, color: img.ColorRgb8(0, 0, 0));
    cases.add(('synth_form_24px', encode(c3)));

    // 4. Kontras rendah (abu muda di abu) — simulasi scan pudar.
    final c4 = img.Image(width: 640, height: 400);
    img.fill(c4, color: img.ColorRgb8(215, 215, 215));
    img.drawString(c4, 'LOW CONTRAST TEXT 456', font: img.arial24, x: 40, y: 160, color: img.ColorRgb8(165, 165, 165));
    cases.add(('synth_low_contrast', encode(c4)));

    // 5. Noise gaussian — simulasi foto kamera buruk.
    final c5 = img.Image(width: 640, height: 400);
    img.fill(c5, color: img.ColorRgb8(255, 255, 255));
    img.drawString(c5, 'NOISY SCAN 789', font: img.arial48, x: 40, y: 150, color: img.ColorRgb8(0, 0, 0));
    cases.add(('synth_noisy', encode(img.noise(c5, 28, type: img.NoiseType.gaussian))));

    // 6. Rotasi kecil ~4 derajat — simulasi dokumen tidak lurus.
    final c6 = img.Image(width: 760, height: 520);
    img.fill(c6, color: img.ColorRgb8(255, 255, 255));
    img.drawString(c6, 'ROTATED DOCUMENT 321', font: img.arial24, x: 80, y: 230, color: img.ColorRgb8(0, 0, 0));
    cases.add(('synth_rotated_4deg', encode(img.copyRotate(c6, angle: 4))));

    // 7. Kosong — harus gagal dengan NO_TEXT_DETECTED.
    final c7 = img.Image(width: 640, height: 400);
    img.fill(c7, color: img.ColorRgb8(255, 255, 255));
    cases.add(('synth_blank', encode(c7)));

    return cases;
  }

  void _onExternalScanRequest() {
    if (!_isScanning) _runSyntheticScan();
  }

  /// Scan gambar sintetis (teks hitam di atas putih) yang digambar pakai
  /// package:image — tanpa dialog kamera/file, jadi bisa di-trigger dari
  /// test harness via OCR_SCAN dan otomatis end-to-end.
  Future<void> _runSyntheticScan() async {
    final image = img.Image(width: 640, height: 400);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    img.drawString(
      image,
      'HELLO WORLD 123',
      font: img.arial48,
      x: 40,
      y: 150,
      color: img.ColorRgb8(0, 0, 0),
    );
    final bytes = Uint8List.fromList(img.encodeJpg(image));
    await _runScan(bytes);
  }
 
  Future<void> _scanFromNativeCamera() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.camera);
    if (file == null) return;
 
    final bytes = await file.readAsBytes();
    await _runScan(bytes);
  }
 
  Future<void> _scanFromLivePreview() async {
    final bytes = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => const _LiveCameraCaptureScreen()),
    );
    if (bytes == null) return;
 
    await _runScan(bytes);
  }
 
  Future<void> _runScan(Uint8List bytes) async {
    setState(() {
      _isScanning = true;
      _statusMessage = null;
    });
 
    try {
      final result = await widget.client.scan(bytes, forceCloud: widget.forceCloud);
      widget.onResult(result);
      setState(() => _statusMessage = result.success
          ? 'Berhasil (${result.confidence.toStringAsFixed(1)}% yakin)'
          : 'Gagal: ${result.error?.detail}');
    } catch (e) {
      setState(() => _statusMessage = 'Error: $e');
    } finally {
      setState(() => _isScanning = false);
    }
  }
 
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: _isScanning ? null : _scanFromNativeCamera,
                icon: const Icon(Icons.camera_alt),
                label: const Text('Capture Kamera'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _isScanning ? null : _scanFromLivePreview,
                icon: const Icon(Icons.videocam),
                label: const Text('Capture (Live Preview)'),
              ),
              if (_isScanning) ...[
                const SizedBox(height: 24),
                const CircularProgressIndicator(color: Colors.white),
              ],
              if (_statusMessage != null) ...[
                const SizedBox(height: 16),
                Text(
                  _statusMessage!,
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
 
/// Layar live-preview kamera pakai package `camera` (camera_web di web).
///
/// Fix yang diterapkan di sini (sama seperti demo sebelumnya):
/// - `ResolutionPreset.max` + log `previewSize` aktual dari browser.
/// - `setFocusMode`/`setExposureMode`/`setFocusPoint` dibungkus try-catch
///   karena camera_web belum mengimplementasikannya (UnimplementedError).
/// - Preview di-mirror SECARA VISUAL untuk kamera non-"back" (webcam
///   laptop/depan) supaya nyaman dipakai aiming.
/// - PENTING: bytes hasil `takePicture()` DI WEB TERNYATA JUGA MIRROR
///   (terbukti dari teks "ALIA" terbaca "AIJA" di OCR) — bukan cuma
///   preview-nya. Jadi bytes-nya di-flip balik pakai package `image`
///   sebelum dikembalikan, supaya OCR menerima orientasi yang benar.
class _LiveCameraCaptureScreen extends StatefulWidget {
  const _LiveCameraCaptureScreen();
 
  @override
  State<_LiveCameraCaptureScreen> createState() => _LiveCameraCaptureScreenState();
}
 
class _LiveCameraCaptureScreenState extends State<_LiveCameraCaptureScreen> {
  CameraController? _controller;
  Future<void>? _initFuture;
  bool _isCapturing = false;
  String? _errorMessage;
  Size? _achievedResolution;
  bool _isMirrored = false;
 
  @override
  void initState() {
    super.initState();
    _initFuture = _initCamera();
  }
 
  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() =>
            _errorMessage = 'Tidak ada kamera yang terdeteksi oleh browser.');
        return;
      }
 
      final selected = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
 
      final controller = CameraController(
        selected,
        ResolutionPreset.max,
        enableAudio: false,
      );
 
      await controller.initialize();
      if (!mounted) return;
 
      try {
        await controller.setFocusMode(FocusMode.auto);
      } catch (e) {
        debugPrint('setFocusMode tidak didukung: $e');
      }
      try {
        await controller.setExposureMode(ExposureMode.auto);
      } catch (e) {
        debugPrint('setExposureMode tidak didukung: $e');
      }
 
      final achieved = controller.value.previewSize;
      debugPrint('Resolusi preview yang didapat dari browser: $achieved');
 
      // Kamera "back" (di HP) tidak perlu di-mirror. Selain itu (front,
      // atau webcam laptop/desktop yang browser anggap default), mirror
      // preview-nya secara visual DAN flip bytes hasil capture-nya —
      // keduanya terbukti mirror di camera_web, bukan cuma salah satu.
      final isMirrored = selected.lensDirection != CameraLensDirection.back;
 
      setState(() {
        _controller = controller;
        _achievedResolution = achieved;
        _isMirrored = isMirrored;
      });
    } catch (e) {
      if (!mounted) return;
      final message = e.toString().contains('NotAllowedError') ||
              e.toString().contains('Permission')
          ? 'Izin kamera ditolak. Aktifkan izin kamera untuk situs ini di pengaturan browser, lalu muat ulang halaman.'
          : 'Gagal membuka kamera: $e';
      setState(() => _errorMessage = message);
    }
  }
 
  Future<void> _focusAndExpose(
      TapUpDetails details, BoxConstraints constraints) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
 
    var dx = details.localPosition.dx / constraints.maxWidth;
    final dy = details.localPosition.dy / constraints.maxHeight;
    if (_isMirrored) dx = 1 - dx;
 
    try {
      await controller.setFocusPoint(Offset(dx, dy));
      await controller.setExposurePoint(Offset(dx, dy));
    } catch (e) {
      debugPrint('Tap-to-focus tidak didukung di device ini: $e');
    }
  }
 
  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _isCapturing) {
      return;
    }
 
    setState(() => _isCapturing = true);
    try {
      await Future.delayed(const Duration(milliseconds: 300));
 
      final file = await controller.takePicture();
      var bytes = await file.readAsBytes();
 
      // Bytes hasil takePicture() di camera_web ikut mirror — flip
      // balik di sini sebelum dikirim ke OCR.
      if (_isMirrored) {
        final decoded = img.decodeImage(bytes);
        if (decoded != null) {
          final flipped = img.flipHorizontal(decoded);
          bytes = Uint8List.fromList(img.encodeJpg(flipped, quality: 95));
        }
      }
 
      if (!mounted) return;
      Navigator.of(context).pop(bytes);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isCapturing = false;
        _errorMessage = 'Gagal mengambil foto: $e';
      });
    }
  }
 
  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
 
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Capture Foto (Live Preview)')),
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (context, snapshot) {
          if (_errorMessage != null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
 
          final controller = _controller;
          if (snapshot.connectionState != ConnectionState.done ||
              controller == null ||
              !controller.value.isInitialized) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          }
 
          return LayoutBuilder(
            builder: (context, constraints) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    onTapUp: (details) => _focusAndExpose(details, constraints),
                    child: Transform(
                      alignment: Alignment.center,
                      transform: _isMirrored
                          ? Matrix4.rotationY(math.pi)
                          : Matrix4.identity(),
                      child: CameraPreview(controller),
                    ),
                  ),
                  Positioned(
                    top: 16,
                    left: 0,
                    right: 0,
                    child: Text(
                      _achievedResolution != null
                          ? 'Resolusi: ${_achievedResolution!.width.toInt()}x${_achievedResolution!.height.toInt()}'
                              '${_isMirrored ? ' (preview di-mirror)' : ''}'
                          : 'Ketuk layar untuk fokus ke teks',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                  Positioned(
                    bottom: 24,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: FloatingActionButton(
                        onPressed: _isCapturing ? null : _capture,
                        child: _isCapturing
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.camera),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}