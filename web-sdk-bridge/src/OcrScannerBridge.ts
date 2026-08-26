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
  /** URL tempat build `apps/web_host` di-hosting, mis. https://scan.yourapp.com/v1/ */
  iframeUrl: string;
  /** URL backend proxy Anda sendiri — BUKAN base URL cloud OCR provider langsung. */
  proxyBaseUrl: string;
  modelManifestUrl: string;
  confidenceThreshold?: number;
  onProgress?: (progress: number) => void;
  onLog?: (message: string, error?: string) => void;
}

export class OcrScannerBridge {
  private config: OcrScannerConfig;
  private iframe: HTMLIFrameElement | null = null;
  private messageHandler: ((event: MessageEvent) => void) | null = null;

  constructor(config: OcrScannerConfig) {
    this.config = config;
  }

  /**
   * Buka scanner full-screen dan tunggu satu hasil scan. Promise resolve
   * begitu host menerima `OCR_RESULT` pertama (baik sukses maupun gagal —
   * caller cek `result.success`), atau reject kalau iframe gagal init /
   * ditutup manual sebelum ada hasil.
   */
  open(): Promise<OcrResultPayload> {
    if (this.iframe) {
      return Promise.reject(new Error("Scanner sudah terbuka — panggil close() dulu."));
    }

    return new Promise((resolve, reject) => {
      const iframe = document.createElement("iframe");
      iframe.src = this.config.iframeUrl;
      iframe.allow = "camera"; // WAJIB, tanpa ini browser blok akses kamera di dalam iframe
      Object.assign(iframe.style, {
        position: "fixed",
        inset: "0",
        width: "100vw",
        height: "100vh",
        border: "none",
        zIndex: "999999",
      } satisfies Partial<CSSStyleDeclaration>);

      const onMessage = (event: MessageEvent) => {
        // Hanya terima pesan dari iframe scanner ini sendiri, bukan
        // iframe/tab lain yang kebetulan ada di halaman.
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
              }),
              "*",
            );
            break;
          case "OCR_MODEL_PROGRESS":
            this.config.onProgress?.(msg.progress as number);
            break;
          case "OCR_LOG":
            this.config.onLog?.(msg.message as string, msg.error as string | undefined);
            break;
          case "OCR_ERROR":
            this.close();
            reject(new Error((msg.message as string) ?? "OCR init gagal"));
            break;
          case "OCR_RESULT":
            resolve(msg.payload as OcrResultPayload);
            this.close();
            break;
        }
      };

      this.messageHandler = onMessage;
      window.addEventListener("message", onMessage);
      document.body.appendChild(iframe);
      this.iframe = iframe;
    });
  }

  /** Tutup paksa scanner tanpa menunggu hasil (mis. user klik "Batal" di UI host). */
  close(): void {
    if (this.messageHandler) {
      window.removeEventListener("message", this.messageHandler);
      this.messageHandler = null;
    }
    if (this.iframe) {
      this.iframe.contentWindow?.postMessage(JSON.stringify({ type: "OCR_DISPOSE" }), "*");
      this.iframe.remove();
      this.iframe = null;
    }
  }
}
