import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:ocr_core/ocr_core.dart';
import 'package:ocr_ui/ocr_ui.dart';
import 'package:web/web.dart' as web;

// CATATAN VALIDASI (baca sebelum deploy):
// File ini ditulis tanpa akses compiler Flutter Web di sandbox saya, sama
// seperti disclaimer di README utama repo ini. Bagian yang PALING perlu
// dicek ulang terhadap versi `package:web` yang benar-benar Anda pakai:
//   - signature `web.window.addEventListener` / `EventListener` typedef
//   - `MessageEvent.data` (tipe JSAny? -> cast ke JSString)
//   - `web.window.parent` (WindowProxy non-null di spec, tapi cek versi)
// Anggap sebagai starting point protokol postMessage, bukan kode final.

void main() {
  runApp(const OcrWebHostApp());
}

/// App Flutter Web tunggal yang dibungkus sebagai `<iframe>` oleh host app
/// (React/Next.js/vanilla apa pun) — lihat `web-sdk-bridge/` untuk wrapper
/// JS/React di sisi host.
///
/// Alur:
/// 1. Host kirim `postMessage({type:'OCR_INIT', baseUrl, modelManifestUrl})`.
/// 2. App ini bikin `OcrClient`, panggil `prepare()`, lalu tampilkan
///    `OcrScanScreen` dari `ocr_ui`.
/// 3. Tiap hasil scan dikirim balik ke host via
///    `postMessage({type:'OCR_RESULT', payload: ocrResult.toJson()})`.
///
/// PENTING SOAL KEAMANAN: `baseUrl` di sini SEHARUSNYA menunjuk ke backend
/// proxy milik Anda sendiri (bukan cloud OCR provider langsung), supaya API
/// key asli tidak pernah keluar dari server dan tidak pernah lewat
/// postMessage / terlihat di devtools browser pengguna.
class OcrWebHostApp extends StatefulWidget {
  const OcrWebHostApp({super.key});

  @override
  State<OcrWebHostApp> createState() => _OcrWebHostAppState();
}

class _OcrWebHostAppState extends State<OcrWebHostApp> {
  OcrClient? _client;
  String? _initError;

  @override
  void initState() {
    super.initState();
    web.window.addEventListener(
      'message',
      _handleMessage.toJS,
    );
    // Beri tahu host bahwa iframe siap menerima config OCR_INIT — host
    // sebaiknya menunggu sinyal ini sebelum mengirim postMessage pertama,
    // supaya tidak race condition (kirim INIT sebelum listener terpasang)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _postToHost({
        'type': 'OCR_HOST_READY',
      });
      print('🟢 OCR_HOST_READY dikirim');
    });
  }

  @override
  void dispose() {
    web.window.removeEventListener(
      'message',
      _handleMessage.toJS,
    );
    _client?.dispose();
    super.dispose();
  }

  void _handleMessage(web.Event event) {
    final messageEvent = event as web.MessageEvent;
    print('📨 RAW MESSAGE: ${messageEvent.data}');
    final rawData = messageEvent.data;
    if (rawData is! JSString) {
      print('⚠️ Message bukan JSString');
      return;
    }
    try {
      final decoded = jsonDecode(rawData.toDart);
      if (decoded is! Map) {
        print('⚠️ Format message tidak valid');
        return;
      }
      final data = Map<String, dynamic>.from(decoded);
      final type = data['type'];
      print('📨 MESSAGE TYPE: $type');
      switch (type) {
        case 'OCR_INIT':
          _handleOcrInit(data);
          break;
        case 'OCR_DISPOSE':
          _client?.dispose();
          _client = null;
          break;
      }
    } catch (e, stackTrace) {
      print('❌ MESSAGE ERROR: $e');
      print(stackTrace);
    }
  }

  void _onMessage(web.Event event) {
    final messageEvent = event as web.MessageEvent;
    // Saat standalone, parent == window sendiri.
    // Jangan proses postMessage yang dikirim oleh app sendiri.
    if (messageEvent.source == web.window) {
      return;
    }
    // Saat benar-benar berada di iframe,
    // hanya terima pesan dari parent.
    if (messageEvent.source != web.window.parent) {
      return;
    }
    final raw = messageEvent.data;
    if (raw == null) {
      return;
    }
    late final Map<String, dynamic> data;
    try {
      data = jsonDecode(
        (raw as JSString).toDart,
      ) as Map<String, dynamic>;
    } catch (e) {
      print('⚠️ Invalid message: $e');
      return;
    }
    print('📨 RAW MESSAGE: $raw');
    print('📨 MESSAGE TYPE: ${data['type']}');
    switch (data['type']) {
      case 'OCR_INIT':
        final payload = Map<String, dynamic>.from(
          data['payload'] ?? {},
        );
        _initClient(payload);
        break;
      case 'OCR_DISPOSE':
        _client?.dispose();
        _client = null;
        break;
    }
  }

  Future<void> _handleOcrInit(
    Map<String, dynamic> message,
  ) async {
    try {
      print('🚀 OCR_INIT diterima');
      final payload = Map<String, dynamic>.from(
        message['payload'] ?? {},
      );
      final apiKey = payload['apiKey'] as String? ?? '';
      final baseUrl = payload['baseUrl'] as String?;
      final modelManifestUrl = payload['modelManifestUrl'] as String?;
      if (baseUrl == null || baseUrl.isEmpty) {
        throw Exception('baseUrl wajib diisi');
      }
      if (modelManifestUrl == null || modelManifestUrl.isEmpty) {
        throw Exception('modelManifestUrl wajib diisi');
      }
      print('BASE URL: $baseUrl');
      print('MODEL MANIFEST: $modelManifestUrl');
      if (_client != null) {
        print('⚠️ OcrClient sudah diinisialisasi');
        return;
      }
      final client = OcrClient(
        apiKey: apiKey,
        baseUrl: baseUrl,
        modelManifestUrl: modelManifestUrl,
        confidenceThreshold: 85.0,
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
        _initError = null;
      });
      print('🚀 OcrClient dibuat');
      await client.prepare(
        onProgress: (progress) {
          print('📦 Model progress: $progress');
          _postToHost({
            'type': 'OCR_MODEL_PROGRESS',
            'progress': progress,
          });
        },
      );
      print(
        '✅ OCR READY: ${client.readiness.name}',
      );
      _postToHost({
        'type': 'OCR_READY',
        'readiness': client.readiness.name,
      });
    } catch (e, stackTrace) {
      print('❌ OCR_INIT ERROR: $e');
      print(stackTrace);
      if (!mounted) return;
      setState(() {
        _initError = e.toString();
      });
      _postToHost({
        'type': 'OCR_ERROR',
        'message': e.toString(),
      });
    }
  }

  Future<void> _initClient(Map<String, dynamic> config) async {
  if (_client != null) return;
  try {
       // PERHATIAN — apiKey dari OCR_INIT ini HANYA untuk fase testing lokal
      // (langsung ke services/ocr-cloud-api tanpa proxy). JANGAN dipakai
      // pola ini untuk deploy publik — sebelum go-live, ganti balik ke
      // apiKey kosong + baseUrl mengarah ke backend proxy (lihat README),
      // supaya API key asli tidak pernah terkirim lewat postMessage /
      // kelihatan di devtools browser pengguna.
    print('🚀 Initializing OCR client...');
    final payload = Map<String, dynamic>.from(
      config['payload'] ?? {},
    );
    final apiKey = payload['apiKey'] as String? ?? '';
    final baseUrl = payload['baseUrl'] as String?;
    final modelManifestUrl =
        payload['modelManifestUrl'] as String?;
    print('API KEY: ${apiKey.isEmpty ? 'EMPTY' : 'SET'}');
    print('BASE URL: $baseUrl');
    print('MODEL MANIFEST: $modelManifestUrl');
    if (baseUrl == null || baseUrl.isEmpty) {
      throw Exception('baseUrl tidak tersedia');
    }
    if (modelManifestUrl == null || modelManifestUrl.isEmpty) {
      throw Exception('modelManifestUrl tidak tersedia');
    }
    final client = OcrClient(
      apiKey: apiKey,
      baseUrl: baseUrl,
      modelManifestUrl: modelManifestUrl,
      confidenceThreshold:
          (payload['confidenceThreshold'] as num?)?.toDouble() ?? 85.0,
      logger: (message, {error, stackTrace}) {
        _postToHost({
          'type': 'OCR_LOG',
          'message': message,
          'error': error?.toString(),
        });
      },
    );
    if (!mounted) {
      client.dispose();
      return;
    }
    setState(() {
      _client = client;
    });
    await client.prepare(
      onProgress: (p) {
        _postToHost({
          'type': 'OCR_MODEL_PROGRESS',
          'progress': p,
        });
      },
    );
    _postToHost({
      'type': 'OCR_READY',
      'readiness': client.readiness.name,
    });
  } catch (e, stackTrace) {
    print('❌ OCR INIT ERROR: $e');
    print(stackTrace);
    if (!mounted) return;
    setState(() {
      _initError = e.toString();
    });
    _postToHost({
      'type': 'OCR_ERROR',
      'message': e.toString(),
    });
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
                child: Text(error,
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center),
              ),
            )
          : client == null
              ? const Scaffold(
                  backgroundColor: Colors.black,
                  body: Center(
                      child: CircularProgressIndicator(color: Colors.white)),
                )
              : OcrScanScreen(
                  client: client,
                  onResult: (result) => _postToHost({
                    'type': 'OCR_RESULT',
                    'payload': result.toJson(),
                  }),
                ),
    );
  }
}
