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
///    `OcrScanScreen` dari `ocr_ui`.
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
  OcrClient? _client;
  String? _initError;

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
    }
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

      print('API KEY: ${apiKey.isEmpty ? "❌ EMPTY (cek format postMessage Anda!)" : "✅ SET (${apiKey.length} char)"}');
      print('BASE URL: $baseUrl');
      print('MODEL MANIFEST: $modelManifestUrl');

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
              : OcrScanScreen(
                  client: client,
                  onResult: (result) => _postToHost({'type': 'OCR_RESULT', 'payload': result.toJson()}),
                ),
    );
  }
}
