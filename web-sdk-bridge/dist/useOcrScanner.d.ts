import { type OcrReadiness, type OcrResultPayload, type OcrScannerConfig } from "./OcrScannerBridge";
export type OcrScanStatus = "idle" | "scanning" | "done" | "error";
/**
 * React hook di atas `OcrScannerBridge`. Dipakai baik di React (CRA/Vite)
 * maupun Next.js — untuk Next.js App Router, komponen yang memanggil hook
 * ini WAJIB `'use client'` (butuh `window`/DOM) dan sebaiknya di-lazy-load
 * dengan `dynamic(() => import(...), { ssr: false })` (lihat README package
 * ini) supaya bundle iframe scanner tidak ikut ke initial page load.
 *
 * Catatan perilaku:
 * - `open()` me-reject kalau scan gagal/dibatalkan — SELALU `.catch()` di
 *   caller, atau cukup baca `status === "error"` + `error` dari hook.
 * - Config di-capture sekali per-mount. Kalau URL config Anda baru tahu
 *   setelah fetch async (mis. dari /api/config), jangan render tombol scan
 *   sampai config siap (conditional render), karena perubahan config object
 *   TIDAK diterapkan ke bridge yang sudah dibuat.
 */
export declare function useOcrScanner(config: Omit<OcrScannerConfig, "onProgress" | "onLog" | "onReady" | "onCancel">): {
    status: OcrScanStatus;
    progress: number;
    result: OcrResultPayload | null;
    error: string | null;
    readiness: OcrReadiness | null;
    open: () => Promise<OcrResultPayload>;
    close: () => void;
};
