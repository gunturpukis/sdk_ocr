import 'package:flutter/material.dart';

import '../theme/ocr_ui_theme.dart';

/// Overlay kamera dengan frame guide berbentuk corner bracket (seperti
/// viewfinder kamera rangefinder) + garis scan animasi yang bergerak
/// naik-turun, dan area di luar frame di-dim supaya user fokus posisikan
/// dokumen di dalam frame.
class ScanFrameOverlay extends StatefulWidget {
  final bool isScanning;
  final double aspectRatio; // rasio frame, misal 1.586 untuk KTP (ISO/IEC 7810 ID-1)

  const ScanFrameOverlay({
    super.key,
    this.isScanning = false,
    this.aspectRatio = 1.586,
  });

  @override
  State<ScanFrameOverlay> createState() => _ScanFrameOverlayState();
}

class _ScanFrameOverlayState extends State<ScanFrameOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant ScanFrameOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isScanning && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isScanning) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(
        painter: _ScanFramePainter(
          scanProgress: _controller.value,
          isScanning: widget.isScanning,
          aspectRatio: widget.aspectRatio,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _ScanFramePainter extends CustomPainter {
  final double scanProgress;
  final bool isScanning;
  final double aspectRatio;

  _ScanFramePainter({
    required this.scanProgress,
    required this.isScanning,
    required this.aspectRatio,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final frameWidth = size.width * 0.85;
    final frameHeight = frameWidth / aspectRatio;
    final frameRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: frameWidth,
      height: frameHeight,
    );

    _paintScrim(canvas, size, frameRect);
    _paintBrackets(canvas, frameRect);
    if (isScanning) _paintScanLine(canvas, frameRect);
  }

  void _paintScrim(Canvas canvas, Size size, Rect frameRect) {
    final scrimPaint = Paint()..color = OcrUiTokens.overlayScrim;
    final fullPath = Path()..addRect(Offset.zero & size);
    final holePath = Path()
      ..addRRect(RRect.fromRectAndRadius(frameRect, const Radius.circular(16)));

    final path = Path.combine(PathOperation.difference, fullPath, holePath);
    canvas.drawPath(path, scrimPaint);
  }

  void _paintBrackets(Canvas canvas, Rect frameRect) {
    const bracketLength = 28.0;
    const strokeWidth = 4.0;

    final paint = Paint()
      ..color = isScanning ? OcrUiTokens.bracketActive : OcrUiTokens.bracketIdle
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final corners = [
      // top-left
      [frameRect.topLeft, Offset(bracketLength, 0), Offset(0, bracketLength)],
      // top-right
      [frameRect.topRight, Offset(-bracketLength, 0), Offset(0, bracketLength)],
      // bottom-left
      [frameRect.bottomLeft, Offset(bracketLength, 0), Offset(0, -bracketLength)],
      // bottom-right
      [frameRect.bottomRight, Offset(-bracketLength, 0), Offset(0, -bracketLength)],
    ];

    for (final corner in corners) {
      final origin = corner[0];
      final dx = corner[1];
      final dy = corner[2];
      canvas.drawLine(origin, origin + dx, paint);
      canvas.drawLine(origin, origin + dy, paint);
    }
  }

  void _paintScanLine(Canvas canvas, Rect frameRect) {
    final y = frameRect.top + frameRect.height * scanProgress;

    final gradient = LinearGradient(
      colors: [
        OcrUiTokens.scanLine.withValues(alpha: 0),
        OcrUiTokens.scanLine.withValues(alpha: 0.9),
        OcrUiTokens.scanLine.withValues(alpha: 0),
      ],
    );

    final rect = Rect.fromLTWH(frameRect.left, y - 12, frameRect.width, 24);
    final paint = Paint()..shader = gradient.createShader(rect);
    canvas.drawRect(rect, paint);

    final linePaint = Paint()
      ..color = OcrUiTokens.scanLine
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(frameRect.left, y),
      Offset(frameRect.right, y),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ScanFramePainter oldDelegate) =>
      oldDelegate.scanProgress != scanProgress || oldDelegate.isScanning != isScanning;
}
