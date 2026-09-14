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
  error?: { code: string; detail: string };
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

const DEFAULT_INIT_TIMEOUT_MS = 120_000;

export class OcrScannerBridge {
  private config: OcrScannerConfig;
  private iframe: HTMLIFrameElement | null = null;
  private messageHandler: ((event: MessageEvent) => void) | null = null;
  private timeoutId: ReturnType<typeof setTimeout> | null = null;
  private settled = false;
  private resolveOpen: ((value: OcrResultPayload) => void) | null = null;
  private rejectOpen: ((reason?: unknown) => void) | null = null;
  /** Origin `iframeUrl` — dipakai untuk validasi event.origin & targetOrigin postMessage. */
  private readonly allowedOrigin: string;

  constructor(config: OcrScannerConfig) {
    this.config = config;
    // Validasi iframeUrl sejak constructor supaya salah URL ketahuan di dev,
    // bukan saat user sudah klik tombol scan.
    try {
      this.allowedOrigin = new URL(config.iframeUrl).origin;
    } catch {
      throw new Error(`OcrScannerBridge: iframeUrl bukan URL yang valid: "${config.iframeUrl}"`);
    }
  }

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
  open(): Promise<OcrResultPayload> {
    if (this.iframe) {
      return Promise.reject(new Error("Scanner sudah terbuka — panggil close() dulu."));
    }

    return new Promise<OcrResultPayload>((resolve, reject) => {
      this.settled = false;
      this.resolveOpen = resolve;
      this.rejectOpen = reject;

      const iframe = document.createElement("iframe");
      iframe.src = this.config.iframeUrl;
      iframe.allow = "camera"; // WAJIB, tanpa ini browser blok akses kamera di dalam iframe
      iframe.title = "OCR Document Scanner";
      Object.assign(iframe.style, {
        position: "fixed",
        inset: "0",
        width: "100vw",
        height: "100vh",
        border: "none",
        zIndex: "999999",
      } satisfies Partial<CSSStyleDeclaration>);

      const onMessage = (event: MessageEvent) => {
        // Hanya pesan dari origin iframe scanner + dari window iframe itu
        // sendiri — bukan dari tab/iframe lain yang kebetulan postMessage.
        if (event.origin !== this.allowedOrigin) return;
        if (event.source !== iframe.contentWindow) return;

        let msg: { type: string; [key: string]: unknown };
        try {
          msg = typeof event.data === "string" ? JSON.parse(event.data) : event.data;
        } catch {
          return;
        }

        switch (msg.type) {
          case "OCR_HOST_READY":
            iframe.contentWindow?.postMessage(
              JSON.stringify({
                type: "OCR_INIT",
                baseUrl: this.config.proxyBaseUrl,
                modelManifestUrl: this.config.modelManifestUrl,
                confidenceThreshold: this.config.confidenceThreshold ?? 85,
                // Kosong kalau tidak diset — scan yang butuh cloud akan
                // dapat 401 INVALID_API_KEY, itu sinyal config kurang.
                apiKey: this.config.apiKey ?? "",
                // Default hybrid: on-device dulu, fallback cloud.
                forceCloud: this.config.forceCloud ?? false,
              }),
              this.allowedOrigin, // bukan '*' — jangan bocorkan config ke domain lain
            );
            break;
          case "OCR_READY":
            this.config.onReady?.(msg.readiness as OcrReadiness);
            break;
          case "OCR_MODEL_PROGRESS":
            this.config.onProgress?.(msg.progress as number);
            break;
          case "OCR_LOG":
            this.config.onLog?.(msg.message as string, msg.error as string | undefined);
            break;
          case "OCR_ERROR":
            this.settleError(new Error((msg.message as string) ?? "OCR init gagal"));
            break;
          case "OCR_RESULT":
            this.settleResult(msg.payload as OcrResultPayload);
            break;
          case "OCR_CANCELLED":
            this.config.onCancel?.();
            this.settleError(new Error("Scan dibatalkan dari sisi scanner."));
            break;
        }
      };

      this.messageHandler = onMessage;
      window.addEventListener("message", onMessage);
      document.body.appendChild(iframe);
      this.iframe = iframe;

      // Guard deadlock: kalau iframe salah URL / gagal load / init menggantung,
      // open() tetap selesai dengan error yang jelas (bukan pending selamanya).
      const timeoutMs = this.config.initTimeoutMs ?? DEFAULT_INIT_TIMEOUT_MS;
      if (timeoutMs > 0) {
        this.timeoutId = setTimeout(() => {
          this.settleError(
            new Error(
              `OCR scanner timeout setelah ${Math.round(timeoutMs / 1000)}s tanpa hasil. ` +
                `Cek apakah iframeUrl bisa dibuka: ${this.config.iframeUrl}`,
            ),
          );
        }, timeoutMs);
      }
    });
  }

  /** Tutup paksa scanner tanpa menunggu hasil (mis. user klik "Batal" di UI host). */
  close(): void {
    // Kalau masih ada open() yang pending, jangan biarkan promise-nya
    // menggantung selamanya — settle dengan error penutupan.
    if (!this.settled && this.rejectOpen) {
      this.settleError(new Error("Scanner ditutup sebelum ada hasil."));
      return;
    }
    this.clearTimeoutTimer();
    if (this.messageHandler) {
      window.removeEventListener("message", this.messageHandler);
      this.messageHandler = null;
    }
    if (this.iframe) {
      // Kirim OCR_DISPOSE SEBELUM iframe diremove — setelah remove(),
      // contentWindow sudah tidak bisa menerima pesan.
      try {
        this.iframe.contentWindow?.postMessage(
          JSON.stringify({ type: "OCR_DISPOSE" }),
          this.allowedOrigin,
        );
      } catch {
        // iframe mungkin sudah di-unload — aman diabaikan.
      }
      this.iframe.remove();
      this.iframe = null;
    }
  }

  /** Selesaikan open() promise dengan hasil scan — sekali saja, lalu bereskan. */
  private settleResult(value: OcrResultPayload): void {
    if (this.settled) return;
    this.settled = true;
    const resolve = this.resolveOpen;
    this.resolveOpen = null;
    this.rejectOpen = null;
    resolve?.(value);
    this.close();
  }

  /** Selesaikan open() promise dengan error — sekali saja, lalu bereskan. */
  private settleError(error: Error): void {
    if (this.settled) return;
    this.settled = true;
    const reject = this.rejectOpen;
    this.resolveOpen = null;
    this.rejectOpen = null;
    reject?.(error);
    this.close();
  }

  private clearTimeoutTimer(): void {
    if (this.timeoutId !== null) {
      clearTimeout(this.timeoutId);
      this.timeoutId = null;
    }
  }
}
