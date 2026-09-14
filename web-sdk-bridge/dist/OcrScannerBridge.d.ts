/**
 * OcrScannerBridge — jembatan framework-agnostic ke iframe Flutter Web
 * (`apps/web_host`). Ini yang dipublish sebagai npm package inti; React
 * hook (`useOcrScanner`) dan wrapper framework lain (Vue/Svelte/vanilla)
 * tinggal pakai class ini, tanpa duplikasi logic postMessage.
 *
 * Desain sengaja full-screen overlay (bukan iframe kecil inline) karena:
 * 1. UX capture kamera memang paling natural full-screen (sama seperti
 *    kebanyakan SDK scan ID produksi — Jumio, Onfido, dll).
 * 2. Flutter Web canvas tidak melaporkan intrinsic content size ke DOM
 *    host seperti elemen HTML biasa, jadi auto-resize iframe inline itu
 *    rapuh — full-screen menghindari masalah itu sepenuhnya.
 *
 * KEAMANAN postMessage (diubah dari versi awal yang pakai targetOrigin
 * '*' dan tidak cek event.origin):
 * - Semua pesan OUT ke iframe dikirim dengan targetOrigin persis origin
 *   `iframeUrl` — browser akan blok kalau iframe ternyata di domain lain.
 * - Semua pesan IN dari iframe divalidasi `event.origin` + `event.source`
 *   sebelum diproses, jadi pesan dari iframe/tab lain tidak bisa spoofing.
 */
export type OcrReadiness = "onDeviceReady" | "cloudOnlyFallback";
export interface OcrField {
    value: string;
    confidence: number;
    line?: number;
}
export interface OcrResultPayload {
    success: boolean;
    data: {
        confidence: number;
        rawText: string;
        documentType: string;
        fields?: Record<string, OcrField>;
    };
    meta: {
        source: "cloud" | "onDevice";
        processingTimeMs?: number;
    };
    error?: {
        code: string;
        detail: string;
    };
}
export interface OcrScannerConfig {
    /** URL tempat build `apps/web_host` di-hosting, mis. https://scan.yourapp.com/scan/ */
    iframeUrl: string;
    /** URL backend proxy Anda sendiri — BUKAN base URL cloud OCR provider langsung. */
    proxyBaseUrl: string;
    modelManifestUrl: string;
    /**
     * OPSIONAL — HANYA untuk testing lokal. Kalau diisi, key ini dikirim ke
     * iframe via postMessage dan terlihat di DevTools browser user. Untuk
     * production, JANGAN set ini: pakai backend proxy yang menyuntikkan
     * header Authorization di sisi server (lihat README, bagian "Auth").
     */
    apiKey?: string;
    confidenceThreshold?: number;
    /**
     * false (default) = hybrid: scan on-device dulu (PaddleOCR via
     * onnxruntime-web — butuh script ort di web/index.html host), lalu
     * fallback ke cloud kalau confidence di bawah threshold / on-device
     * gagal inisialisasi. true = selalu cloud (model medium lebih akurat,
     * tapi tiap scan butuh network + API key valid).
     */
    forceCloud?: boolean;
    /**
     * Batas waktu menunggu hasil sejak open() dipanggil (ms). Melindungi
     * caller dari menggantung selamanya kalau URL iframe salah / iframe
     * gagal load / init OCR menggantung. Default 120000 (2 menit) — model
     * kecil perlu waktu download saat pertama kali. Set 0 untuk disable.
     */
    initTimeoutMs?: number;
    onProgress?: (progress: number) => void;
    onLog?: (message: string, error?: string) => void;
    /** Dipanggil saat web host selesai init (download model selesai / fallback cloud). */
    onReady?: (readiness: OcrReadiness) => void;
    /** Dipanggil kalau user menutup scanner dari sisi dalam iframe (tanpa hasil). */
    onCancel?: () => void;
}
export declare class OcrScannerBridge {
    private config;
    private iframe;
    private messageHandler;
    private timeoutId;
    private settled;
    private resolveOpen;
    private rejectOpen;
    /** Origin `iframeUrl` — dipakai untuk validasi event.origin & targetOrigin postMessage. */
    private readonly allowedOrigin;
    constructor(config: OcrScannerConfig);
    /**
     * Buka scanner full-screen dan tunggu satu hasil scan. Promise resolve
     * begitu host menerima `OCR_RESULT` pertama (baik sukses maupun gagal —
     * caller cek `result.success`), atau reject kalau:
     * - iframe gagal init (`OCR_ERROR` dari host),
     * - timeout `initTimeoutMs` tercapai tanpa hasil,
     * - user membatalkan dari sisi dalam iframe (`OCR_CANCELLED`),
     * - ditutup manual via close() sebelum ada hasil,
     * - scanner sudah terbuka (panggil close() dulu).
     */
    open(): Promise<OcrResultPayload>;
    /** Tutup paksa scanner tanpa menunggu hasil (mis. user klik "Batal" di UI host). */
    close(): void;
    /** Selesaikan open() promise dengan hasil scan — sekali saja, lalu bereskan. */
    private settleResult;
    /** Selesaikan open() promise dengan error — sekali saja, lalu bereskan. */
    private settleError;
    private clearTimeoutTimer;
}
