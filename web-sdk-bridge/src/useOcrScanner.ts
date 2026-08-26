import { useCallback, useEffect, useRef, useState } from "react";
import { OcrScannerBridge, type OcrResultPayload, type OcrScannerConfig } from "./OcrScannerBridge";

export type OcrScanStatus = "idle" | "scanning" | "done" | "error";

/**
 * React hook di atas `OcrScannerBridge`. Dipakai baik di React (CRA/Vite)
 * maupun Next.js — untuk Next.js App Router, komponen yang memanggil hook
 * ini WAJIB `'use client'` (butuh `window`/DOM) dan sebaiknya di-lazy-load
 * (lihat contoh Next.js di README package ini) supaya bundle iframe
 * scanner tidak ikut ke initial page load.
 */
export function useOcrScanner(config: Omit<OcrScannerConfig, "onProgress" | "onLog">) {
  const bridgeRef = useRef<OcrScannerBridge | null>(null);
  const [status, setStatus] = useState<OcrScanStatus>("idle");
  const [progress, setProgress] = useState(0);
  const [result, setResult] = useState<OcrResultPayload | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    bridgeRef.current = new OcrScannerBridge({
      ...config,
      onProgress: setProgress,
    });

    return () => {
      bridgeRef.current?.close();
      bridgeRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- config dianggap stabil per-mount
  }, []);

  const open = useCallback(async () => {
    setStatus("scanning");
    setError(null);
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

  return { status, progress, result, error, open, close };
}
