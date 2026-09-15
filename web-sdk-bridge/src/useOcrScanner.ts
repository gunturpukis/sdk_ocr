import { useCallback, useEffect, useRef, useState } from "react";
import {
  OcrScannerBridge,
  type OcrReadiness,
  type OcrResultPayload,
  type OcrScannerConfig,
} from "./OcrScannerBridge";

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
export function useOcrScanner(config: Omit<OcrScannerConfig, "onProgress" | "onReady" | "onCancel">) {
  const bridgeRef = useRef<OcrScannerBridge | null>(null);
  const [status, setStatus] = useState<OcrScanStatus>("idle");
  const [progress, setProgress] = useState(0);
  const [result, setResult] = useState<OcrResultPayload | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [readiness, setReadiness] = useState<OcrReadiness | null>(null);

  useEffect(() => {
    const bridge = new OcrScannerBridge({
      ...config,
      onProgress: setProgress,
      onReady: (r) => setReadiness(r),
      onCancel: () => setStatus("idle"),
    });
    bridgeRef.current = bridge;

    return () => {
      bridge.close();
      bridgeRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- config dianggap stabil per-mount (lihat catatan di atas)
  }, []);

  const open = useCallback(async (): Promise<OcrResultPayload> => {
    setStatus("scanning");
    setError(null);
    setResult(null);
    setProgress(0);
    try {
      const payload = await bridgeRef.current!.open();
      setResult(payload);
      setStatus("done");
      return payload;
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setStatus("error");
      throw e;
    }
  }, []);

  const close = useCallback(() => {
    bridgeRef.current?.close();
    setStatus("idle");
  }, []);

  return { status, progress, result, error, readiness, open, close };
}
