# Run doc — sdk_ocr (thread ini)

Semua path relatif ke root repo `/Users/Guntur/Guntur/sdk_ocr`.

## Layanan yang berjalan (launchd, outlive thread)

| Label launchd | Port | Fungsi | Log |
|---|---|---|---|
| `freebuff-flutter-host` | 8080 | Flutter web host (`apps/web_host`) — iframe scanner | `.freebuff/flutter-host.log` |
| `freebuff-react-demo` | 5173 | Demo React (Vite) yang consume SDK | `.freebuff/react-demo.log` |
| `freebuff-models` | 9090 | Models server — serve `services/ocr-cloud-api/models-cache` (models.json + .ort + dict) | `.freebuff/models-server.log` |

Cek status: `launchctl print gui/$(id -u)/freebuff-flutter-host` (atau `freebuff-react-demo`).
Stop: `launchctl remove <label>`. Port 5173 dipin via `--strictPort` di vite config.

## Reproduce artifacts (fresh checkout)

1. **Build SDK bridge** (dipakai demo via `file:` dependency):
   ```bash
   cd web-sdk-bridge && npm install && npm run build
   ```
2. **Install demo React**:
   ```bash
   cd examples/react-demo && npm install --no-fund --no-audit
   ```
   (Dep `@gunturpukis/ocr-scanner-react": "file:../../web-sdk-bridge/gunturpukis-ocr-scanner-react-0.1.0.tgz` → hasil build di langkah 1.)

2b. **Copy API key demo** (forceCloud: true butuh key — file gitignored):
   ```bash
   grep '^OCR_API_KEY=' services/ocr-cloud-api/.env | sed 's/^OCR_API_KEY=/VITE_OCR_API_KEY=/' > examples/react-demo/.env.local
   ```
   Setelah mengubah `.env.local`, restart dev server (Vite baca env saat startup).
3. **Flutter host** — butuh `onnxruntime-web@1.20.1` script tag di `apps/web_host/web/index.html`
   (sudah ada) dan model cache di browser (otomatis didownload saat OCR_INIT pertama,
   butuh models server :9090 hidup).
4. **Models server** (launchd, label `freebuff-models`):
   ```bash
   launchctl submit -l freebuff-models -- /bin/sh -c \
     "cd /Users/Guntur/Guntur/sdk_ocr && export PATH=/opt/homebrew/bin:$PATH && exec node .freebuff/models-server.js >> /Users/Guntur/Guntur/sdk_ocr/.freebuff/models-server.log 2>&1"
   ```

## Run servers

```bash
# Flutter web host :8080 — RELEASE BUILD via static server (boot cepat, tanpa DDC debug yang flaky di iframe)
# Rebuild dulu bila source berubah: cd apps/web_host && flutter build web --release
launchctl submit -l freebuff-flutter-host -- /bin/sh -c \
  "cd /Users/Guntur/Guntur/sdk_ocr && export PATH=/opt/homebrew/bin:$PATH && exec node .freebuff/static-server.js >> /Users/Guntur/Guntur/sdk_ocr/.freebuff/flutter-host.log 2>&1"

# Demo React :5173
launchctl submit -l freebuff-react-demo -- /bin/sh -c \
  "cd examples/react-demo && export PATH=/opt/homebrew/bin:$PATH && exec npm run dev >> .freebuff/react-demo.log 2>&1"
```

CATATAN macOS: `nohup ... &` dari runner tool ini akan ter-reap (grup proses dibunuh
saat command selesai) — gunakan launchd seperti di atas. launchd butuh PATH di-export
di dalam job (`env: node: No such file or directory` kalau tidak).

## Ganti sumber SDK demo (tarball ↔ registry)

```bash
cd examples/react-demo
npm run sdk:tarball   # re-pack bridge + install dari tarball lokal (default saat ini)
npm run sdk:registry  # flip ke @gunturpukis/ocr-scanner-react dari npm —
                      # menolak dengan pesan jelas selama package belum dipublish
```

## Verifikasi E2E (dipakai thread ini)

Buka http://localhost:5173/ → klik "Scan dokumen (kamera)" → iframe :8080 terbuka,
handshake OCR_INIT → tunggu OCR_READY (model dari cache browser) → hasil scan muncul
di panel "Hasil OCR" React. Untuk scan tanpa kamera (otomatis), jalankan di console:
`document.querySelector('iframe').contentWindow.postMessage(JSON.stringify({type:'OCR_SCAN'}), 'http://localhost:8080')`
— trigger scan gambar sintetis melalui pipeline penuh.
