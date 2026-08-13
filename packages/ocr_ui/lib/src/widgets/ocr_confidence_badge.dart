import 'package:flutter/material.dart';

import '../theme/ocr_ui_theme.dart';

class OcrConfidenceBadge extends StatelessWidget {
  final double confidence;
  final bool isCloudSource;

  const OcrConfidenceBadge({
    super.key,
    required this.confidence,
    this.isCloudSource = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = OcrUiTokens.confidenceColor(confidence);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            '${confidence.toStringAsFixed(0)}% yakin',
            style: OcrUiTokens.statusCaption.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
          if (isCloudSource) ...[
            const SizedBox(width: 6),
            Icon(Icons.cloud_outlined, size: 12, color: color),
          ],
        ],
      ),
    );
  }
}
