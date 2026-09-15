# Panduan Web — React (Vite / CRA)

Integrasi SDK scan OCR ke aplikasi React. Intinya satu hook:
`useOcrScanner` dari package **`@gunturpukis/ocr-scanner-react`** — buka
scanner full-screen (iframe Flutter), terima satu hasil scan.

> Demo lengkap yang sudah jalan ada di `examples/react-demo` di repo ini.

---

## Arsitektur singkat

```
Aplikasi React Anda ──postMessage──► iframe Flutter (apps/web_host)
   useOcrScanner()                     ├── on-device: PaddleOCR via ort-web (fallback
                                       │   ke cloud bila confidence < threshold)
                                       └── cloud: POST {proxyBaseUrl}/v1/ocr/read
```

Model ±139MB di-download sekali oleh browser (Cache Storage + verifikasi
SHA256) — scan berikutnya instan.

---

## Langkah 1 — Install

```bash
npm i @gunturpukis/ocr-scanner-react
# atau tarball lokal sebelum publish:
# npm i /path/ke/web-sdk-bridge/gunturpukis-ocr-scanner-react-0.1.0.tgz
```

Syarat peer: `react >= 18`.

## Langkah 2 — Deploy Flutter web host (prasyarat wajib)

SDK butuh **satu URL `iframeUrl`** yang menyajikan hasil build `apps/web_host`:

```bash
cd apps/web_host
flutter build web --release
# hosting folder build/web/ di HTTPS, mis. https://scan.yourapp.com
```

Aturan penting:
- Halaman React `https://` **tidak boleh** meng-iframe `http://` (mixed
  content) → host wajib HTTPS di production.
- `web/index.html` host berisi `wasmPaths` ort + script tag — self-host file
  ort (folder `dist/` onnxruntime-web) di CDN Anda untuk produksi; dev boleh
  memakai models server lokal :9090.
- Kalau host memakai `X-Frame-Options: DENY`, tambahkan pengecualian untuk
  domain React Anda.

## Langkah 3 — Pakai hook

```tsx
import { useOcrScanner } from "@gunturpukis/ocr-scanner-react";

function ScanPage() {
  const { status, progress, result, error, readiness, open, close } =
    useOcrScanner({
      iframeUrl: import.meta.env.VITE_OCR_IFRAME_URL,      // https://scan.yourapp.com
      proxyBaseUrl: import.meta.env.VITE_OCR_PROXY_URL,    // https://api.yourapp.com/ocr-proxy
      modelManifestUrl: import.meta.env.VITE_OCR_MANIFEST_URL,
      confidenceThreshold: 85,
      forceCloud: false, // hybrid: on-device dulu
      onLog: (m) => console.log("[ocr]", m),
    });

  return (
    <div>
      <button onClick={() => open().catch(() => {})} disabled={status === "scanning"}>
        {status === "scanning" ? `Memindai… ${Math.round(progress * 100)}%` : "Scan Dokumen"}
      </button>

      {status === "error" && <p style={{ color: "red" }}>{error}</p>}
      {status === "done" && result?.success && (
        <pre>{result.data.rawText}</pre>
      )}
    </div>
  );
}
```

Return hook: `{ status, progress, result, error, readiness, open, close }`
- `status`: `idle | scanning | done | error`
- `readiness`: `onDeviceReady | cloudOnlyFallback | null`
- `open()` me-reject kalau gagal/dibatalkan — **selalu `.catch()`**
- `open()` me-resolve juga untuk hasil gagal-OCR (cek `result.success`)

## Langkah 4 — Konfigurasi penting

| Opsi | Default | Arti |
|---|---|---|
| `iframeUrl` | wajib | URL Flutter web host |
| `proxyBaseUrl` | wajib | Backend proxy Anda (menyuntik `Authorization`) |
| `modelManifestUrl` | wajib | `models.json` (URL + SHA256 model) |
| `confidenceThreshold` | `85` | Ambang fallback cloud |
| `forceCloud` | `false` | `true` = semua scan ke cloud |
| `initTimeoutMs` | `120000` | Timeout `open()`; `0` = tanpa batas |
| `apiKey` | — | **Dev saja** — terlihat di DevTools browser |

**Aturan config:** config di-capture sekali per-mount. Kalau nilai config
baru tahu setelah fetch async (mis. dari `/api/config`), jangan render tombol
scan sebelum config siap (conditional render) — perubahan config object
**tidak** diterapkan ke bridge yang sudah dibuat.

## Langkah 5 — Auth (pola production)

API key **tidak pernah** dikirim dari browser di production. Pakai proxy
same-origin di backend Anda sendiri:

```ts
// contoh Express/Vite dev proxy — intinya: forward multipart + set header
app.post("/ocr-proxy/*path", async (req, res) => {
  const upstream = await fetch("https://ocr-api.yourapp.com" + req.url, {
    method: "POST",
    headers: { Authorization: `Bearer ${process.env.OCR_API_KEY}` },
    body: req, // stream body multipart apa adanya
  });
  res.status(upstream.status).body(upstream.body);
});
```

Lalu client: `proxyBaseUrl: "/ocr-proxy"`. Request jadi same-origin — CORS
tidak relevan, key tidak pernah keluar dari server. Contoh khusus Next.js
ada di [`NEXTJS.md`](NEXTJS.md).

## Langkah 6 — CORS di cloud API

Request ke cloud API datang dari **origin iframe** (domain hosting web host),
bukan origin React. Whitelist origin iframe di `CORS_ALLOWED_ORIGINS` cloud
API (`localhost:*` otomatis untuk dev).

## Checklist smoke

- [ ] Scan pertama: progress model 0→100% → `OCR_READY`
- [ ] `readiness === "onDeviceReady"`, scan dokumen → `source: onDevice`
- [ ] Set confidenceThreshold 99 → hasil jatuh ke cloud (uji fallback)
- [ ] Matikan API proxy → error kontrak muncul rapi (bukan hang)
- [ ] `X-Frame-Options`/CSP `frame-ancestors` tidak memblok iframe
