import 'package:flutter/material.dart';

/// Token desain ocr_ui — dipisah dari Material theme aplikasi consumer
/// supaya overlay kamera scan konsisten terlihat sama di app manapun
/// yang pakai SDK ini, terlepas dari tema masing-masing app.
class OcrUiTokens {
  // Overlay kamera pakai charcoal gelap (bukan hitam pekat) supaya masih
  // ada kedalaman saat preview kamera terlihat di baliknya.
  static const overlayScrim = Color(0xCC15181D);

  // Aksen scan-line: teal terang, mengingatkan pada laser scanner/flatbed
  // scanner — sengaja bukan warna brand generik (biru Material default
  // atau hijau sukses standar) supaya punya identitas sendiri.
  static const scanLine = Color(0xFF2DD4BF);

  static const bracketIdle = Color(0xFFF5F5F0);
  static const bracketActive = scanLine;

  static const confidenceHigh = Color(0xFF4ADE80);
  static const confidenceMedium = Color(0xFFFBBF24);
  static const confidenceLow = Color(0xFFF87171);

  static const statusText = Color(0xFFF5F5F0);
  static const statusTextMuted = Color(0xFFA3A3A0);

  static TextStyle statusLabel = const TextStyle(
    color: statusText,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
  );

  static TextStyle statusCaption = const TextStyle(
    color: statusTextMuted,
    fontSize: 13,
    fontWeight: FontWeight.w400,
  );

  static Color confidenceColor(double confidence) {
    if (confidence >= 85) return confidenceHigh;
    if (confidence >= 60) return confidenceMedium;
    return confidenceLow;
  }
}
