import { useState } from 'react';
import { useOcrScanner } from '@gunturpukis/ocr-scanner-react';

/**
 * Konfigurasi scanner untuk demo lokal:
 * - iframeUrl: Flutter web host (apps/web_host) yang jalan di :8080.
 * - modelManifestUrl: manifest model on-device dari models server :9090.
 * - proxyBaseUrl: URL yang menerima request cloud OCR dari iframe. Di demo
 *   ini menunjuk langsung ke cloud API :3000. API key dev dibaca dari
 *   `.env.local` (VITE_OCR_API_KEY — dicopy dari services/ocr-cloud-api/.env,
 *   file itu gitignored). Di production JANGAN set apiKey di client — pakai
 *   same-origin proxy yang menyuntikkan Authorization di server.
 * - forceCloud: true = SEMUA scan lewat cloud (butuh API key valid).
 *   Set false untuk hybrid on-device dulu, fallback cloud bila perlu.
 */
const SCANNER_CONFIG = {
  iframeUrl: 'http://localhost:8080',
  proxyBaseUrl: 'http://localhost:3000',
  modelManifestUrl: 'http://localhost:9090/models.json',
  confidenceThreshold: 85,
  forceCloud: true,
  apiKey: import.meta.env.VITE_OCR_API_KEY,
};

export default function App() {
  const [logs, setLogs] = useState<string[]>([]);

  const { status, progress, result, error, readiness, open, close } = useOcrScanner({
    ...SCANNER_CONFIG,
    onLog: (msg: string) => setLogs((prev) => [...prev.slice(-30), msg]),
  });

  async function handleScan() {
    try {
      await open();
    } catch {
      // error sudah tersimpan di hook; UI menampilkannya.
    }
  }

  return (
    <div className="app">
      <header>
        <h1>OCR SDK Demo — React</h1>
      </header>

      <section className="status-row">
        <span className={`pill pill-${status}`}>status: {status}</span>
        {readiness && <span className="pill">readiness: {readiness}</span>}
        {status === 'scanning' && <progress max={100} value={Math.round(progress * 100)} />}
      </section>

      <section className="controls">
        <button onClick={handleScan} disabled={status === 'scanning'}>
          Scan dokumen (kamera)
        </button>
        <button onClick={close} className="secondary">
          Close scanner
        </button>
      </section>

      <section className="result">
        {error && <div className="error">Error: {error}</div>}
        {result && (
          <>
            <h2>Hasil OCR</h2>
            <div className="meta">
              <span>source: {result.meta.source}</span>
              <span>confidence: {(result.data.confidence ?? 0).toFixed(1)}%</span>
              {result.meta.processingTimeMs != null && <span>{result.meta.processingTimeMs} ms</span>}
              <span>{result.data.documentType}</span>
            </div>
            <pre>{result.data.rawText || '(teks kosong)'}</pre>
          </>
        )}
      </section>

      {logs.length > 0 && (
        <section className="logs">
          <h2>Log bridge</h2>
          <pre>{logs.join('\n')}</pre>
        </section>
      )}
    </div>
  );
}
