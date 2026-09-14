import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:ocr_core/ocr_core.dart';

import '../theme/ocr_ui_theme.dart';
import '../widgets/ocr_confidence_badge.dart';
import '../widgets/scan_frame_overlay.dart';

/// Layar scan siap pakai — consumer app tinggal pass `OcrClient` yang
/// sudah di-`prepare()`, dan terima hasil lewat `onResult`. Untuk
/// consumer yang mau bikin UI sendiri, `ocr_core` bisa dipakai langsung
/// tanpa widget ini sama sekali.
class OcrScanScreen extends StatefulWidget {
  final OcrClient client;
  final void Function(OcrResult result) onResult;
  final double frameAspectRatio;

  const OcrScanScreen({
    super.key,
    required this.client,
    required this.onResult,
    this.frameAspectRatio = 1.586, // rasio kartu ID standar
  });

  @override
  State<OcrScanScreen> createState() => _OcrScanScreenState();
}

class _OcrScanScreenState extends State<OcrScanScreen> {
  CameraController? _cameraController;
  bool _isProcessing = false;
  String? _statusMessage;
  OcrResult? _lastResult;
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _setupCamera();
  }

  Future<void> _pickFromGallery() async {
    if (_isProcessing) return;
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 100,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      await _runScan(bytes);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _statusMessage = 'Gagal memilih gambar: $e';
      });
    }
  }

  Future<void> _setupCamera() async {
    try {
      final cameras = await availableCameras();
      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();

      if (!mounted) return;
      setState(() => _cameraController = controller);
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusMessage = 'Kamera tidak tersedia: $e');
    }
  }

  Future<void> _capture() async {
    final controller = _cameraController;
    if (controller == null ||
        !controller.value.isInitialized ||
        _isProcessing) {
      return;
    }
    try {
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      await _runScan(bytes);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _statusMessage = 'Gagal mengambil foto: $e';
      });
    }
  }

    void _log(String message) {
    debugPrint(message);
    setState(() => _logs.insert(0, '${DateTime.now().toIso8601String().substring(11, 19)}  $message'));
  }

  Future<void> _runScan(Uint8List bytes) async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
      _statusMessage = 'Membaca dokumen...';
      _lastResult = null;
    });
    try {
      final result = await widget.client.scan(
        bytes,
        forceCloud: false,
      );
      if (!mounted) return;
      setState(() {
        _lastResult = result;
        _isProcessing = false;
        _statusMessage = result.success
            ? null
            : (result.error?.detail ?? 'Gagal membaca teks');
      });
      _log('  rawText:\n${result.rawText}');
      widget.onResult(result);

    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _statusMessage = 'Terjadi kesalahan: $e';
      });
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _cameraController;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (controller != null && controller.value.isInitialized)
            CameraPreview(controller)
          else
            const Center(
                child: CircularProgressIndicator(color: OcrUiTokens.scanLine)),
          ScanFrameOverlay(
            isScanning: _isProcessing,
            aspectRatio: widget.frameAspectRatio,
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 16,
            right: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.close, color: OcrUiTokens.statusText),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                if (widget.client.readiness == OcrReadiness.cloudOnlyFallback)
                  const _ModeBadge(
                      label: 'Mode online', icon: Icons.cloud_outlined),
              ],
            ),
          ),
          Positioned(
            bottom: 48,
            left: 24,
            right: 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_statusMessage != null) ...[
                  Text(
                    _statusMessage!,
                    textAlign: TextAlign.center,
                    style: OcrUiTokens.statusLabel,
                  ),
                  const SizedBox(height: 8),
                ],
                if (_lastResult != null && _lastResult!.success) ...[
                  OcrConfidenceBadge(
                    confidence: _lastResult!.confidence,
                    isCloudSource: _lastResult!.source == OcrSource.cloud,
                  ),
                  const SizedBox(height: 16),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // _GalleryButton(
                    //   isProcessing: _isProcessing,
                    //   onTap: _pickFromGallery,
                    // ),
                    // const SizedBox(width: 32),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _CaptureButton(
                          isProcessing: _isProcessing,
                          onTap: _capture,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Ambil Foto',
                          style: OcrUiTokens.statusCaption,
                        ),
                      ],
                    ),
                  ],
                )
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GalleryButton extends StatelessWidget {
  final bool isProcessing;
  final VoidCallback onTap;
  const _GalleryButton({
    required this.isProcessing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: isProcessing ? null : onTap,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: OcrUiTokens.overlayScrim,
              border: Border.all(
                color: isProcessing
                    ? OcrUiTokens.statusTextMuted
                    : OcrUiTokens.statusText,
                width: 1.5,
              ),
            ),
            child: Icon(
              Icons.photo_library_outlined,
              size: 24,
              color: isProcessing
                  ? OcrUiTokens.statusTextMuted
                  : OcrUiTokens.statusText,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Galeri',
          style: OcrUiTokens.statusCaption,
        ),
      ],
    );
  }
}

class _ModeBadge extends StatelessWidget {
  final String label;
  final IconData icon;

  const _ModeBadge({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: OcrUiTokens.overlayScrim,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: OcrUiTokens.statusTextMuted),
          const SizedBox(width: 6),
          Text(label, style: OcrUiTokens.statusCaption),
        ],
      ),
    );
  }
}

class _CaptureButton extends StatelessWidget {
  final bool isProcessing;
  final VoidCallback onTap;

  const _CaptureButton({required this.isProcessing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isProcessing ? null : onTap,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: OcrUiTokens.statusText, width: 3),
        ),
        padding: const EdgeInsets.all(4),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isProcessing
                ? OcrUiTokens.statusTextMuted
                : OcrUiTokens.statusText,
          ),
          child: isProcessing
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.black),
                )
              : null,
        ),
      ),
    );
  }
}
