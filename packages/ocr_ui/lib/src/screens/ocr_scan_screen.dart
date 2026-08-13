import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    _setupCamera();
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
    if (controller == null || !controller.value.isInitialized || _isProcessing) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = 'Membaca dokumen...';
    });

    try {
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();

      final result = await widget.client.scan(bytes);

      setState(() {
        _lastResult = result;
        _isProcessing = false;
        _statusMessage = result.success ? null : (result.error?.detail ?? 'Gagal membaca teks');
      });

      widget.onResult(result);
    } catch (e) {
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
            const Center(child: CircularProgressIndicator(color: OcrUiTokens.scanLine)),

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
                  const _ModeBadge(label: 'Mode online', icon: Icons.cloud_outlined),
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
                _CaptureButton(isProcessing: _isProcessing, onTap: _capture),
              ],
            ),
          ),
        ],
      ),
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
            color: isProcessing ? OcrUiTokens.statusTextMuted : OcrUiTokens.statusText,
          ),
          child: isProcessing
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                )
              : null,
        ),
      ),
    );
  }
}
