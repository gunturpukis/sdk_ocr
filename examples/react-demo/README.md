# OCR SDK Demo (React + Vite)

Demo meng-consume **`@gunturpukis/ocr-scanner-react`** — jembatan postMessage
ke scanner Flutter Web (iframe full-screen) dengan hybrid OCR on-device + cloud.

## Menjalankan demo

Prasyarat (lihat `.freebuff/run.md` untuk detail + perintah launchd):

| Service | Port | Cara |
|---|---|---|
| Flutter web host | 8080 | `flutter run -d web-server --web-port 8080` dari `apps/web_host` |
| Models server | 9090 | `node .freebuff/models-server.js` (serving models.json + model .ort) |
| Demo ini | 5173 | `npm install && npm run dev` |

Lalu buka http://localhost:5173/ → klik **Scan dokumen (kamera)** →
iframe :8080 terbuka → hasil scan muncul di panel "Hasil OCR".

Scan tanpa kamera (otomatis, untuk verifikasi cepat) — jalankan di console
browser saat iframe terbuka:

```js
document.querySelector('iframe').contentWindow.postMessage(
  JSON.stringify({ type: 'OCR_SCAN' }), 'http://localhost:8080'
);
```

## Sumber dependency SDK — tarball vs registry

```bash
npm run sdk:tarball   # re-pack web-sdk-bridge + install dari tarball lokal (default)
npm run sdk:registry  # flip ke versi dari npm registry
                      # (menolak dengan pesan jelas selama belum di-publish)
```

- `sdk:tarball` selalu me-`npm pack` ulang bridge dulu, jadi perubahan source
  SDK langsung terlihat di demo.
- `sdk:registry` butuh `@gunturpukis/ocr-scanner-react` sudah ada di npm —
  alurnya ada di `web-sdk-bridge/README.md` bagian **Publishing**.

## Konfigurasi scanner

Di `src/App.tsx` (dev):

```ts
const config = {
  iframeUrl: 'http://localhost:8080',          // Flutter web host
  proxyBaseUrl: 'http://localhost:3000',       // cloud OCR API (dev only)
  modelManifestUrl: 'http://localhost:9090/models.json',
  confidenceThreshold: 85,
  forceCloud: false,
};
```

Untuk production, lihat `web-sdk-bridge/README.md` — khususnya bagian
**Auth** (same-origin proxy) dan **Publishing**.
