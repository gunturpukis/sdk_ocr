# SDK OCR — on-device + cloud, Flutter & Web

Monorepo SDK scan dokumen (OCR) hybrid: **on-device dulu** (PaddleOCR via ONNX
Runtime), **fallback cloud** bila confidence di bawah ambang atau init gagal.
Satu kontrak respons untuk semua platform.

| Komponen | Path | Fungsi |
|---|---|---|
| **ocr_core** | `packages/ocr_core` | Logic murni: model manager (download+SHA256+cache), inference det+rec, normalisasi input, hybrid decision. Tanpa opini UI. |
| **ocr_ui** | `packages/ocr_ui` | Layar scan Flutter siap pakai (kamera, overlay, confidence badge) — opsional. |
| **Web SDK (npm)** | `web-sdk-bridge` | `@gunturpukis/ocr-scanner-react` — bridge postMessage framework-agnostic + hook React. |
| **Flutter web host** | `apps/web_host` | Scanner full-screen yang di-embed sebagai iframe oleh Web SDK. |
| **Cloud OCR API** | `services/ocr-cloud-api` | Node/Express: PaddleOCR server-side, auth Bearer, rate limit, CORS. |
| **Demo** | `examples/react-demo` | Contoh consumer React yang live. |

## Status (hasil audit 2026-09 — lihat `docs/AUDIT.md`)

- ✅ **Jalur web tervalidasi end-to-end**: 31/31 unit test `ocr_core`, scan live
  di browser (on-device conf 96–100%, fallback cloud terlog), batched recognition
  aktif, normalisasi input memperbaiki dokumen padat (62 → 99+).
- ✅ **Web SDK siap publish**: scoped npm, MIT, CI typecheck, release otomatis
  dari tag `v*` dengan provenance, changesets.
- ⚠️ **Jalur mobile belum pernah dijalankan di perangkat asli** — arsitektur
  benar, tapi API `flutter_onnxruntime` wajib diverifikasi dulu
  (langkahnya ada di panduan mobile).

## Mulai cepat

Pilih platform Anda:

| Platform | Panduan |
|---|---|
| Flutter (iOS/Android) | [`docs/guides/MOBILE.md`](docs/guides/MOBILE.md) |
| React (Vite/CRA) | [`docs/guides/REACT.md`](docs/guides/REACT.md) |
| Next.js (App Router) | [`docs/guides/NEXTJS.md`](docs/guides/NEXTJS.md) |
| Vue 3 / Nuxt 3 | [`docs/guides/VUE.md`](docs/guides/VUE.md) |

### Contoh 30 detik (React)

```tsx
import { useOcrScanner } from "@gunturpukis/ocr-scanner-react";

const { status, progress, result, open } = useOcrScanner({
  iframeUrl: "https://scan.yourapp.com",       // Flutter web host (HTTPS)
  proxyBaseUrl: "/api/ocr",                    // proxy backend Anda (menyuntik auth)
  modelManifestUrl: "https://cdn.yourapp.com/models.json",
  confidenceThreshold: 85,
  forceCloud: false,                           // hybrid: on-device dulu
});

<button onClick={() => open().catch(() => {})} disabled={status === "scanning"}>
  {status === "scanning" ? `Memindai… ${Math.round(progress * 100)}%` : "Scan Dokumen"}
</button>
{result?.success && <pre>{result.data.rawText}</pre>}
```

## Infrastruktur yang dibutuhkan (semua platform)

1. **Model hosting** — `models.json` + file `.ort` di CDN Anda (format manifest
   ada di `packages/ocr_core/lib/src/models/model_manifest.dart`; contoh nyata di
   `services/ocr-cloud-api/models-cache/`). Model ±139MB, di-download sekali
   per device/browser, diverifikasi SHA256.
2. **Flutter web host di HTTPS** (untuk jalur web) — build `apps/web_host` dan
   hosting folder `build/web/`.
3. **Cloud API** (untuk fallback) — deploy `services/ocr-cloud-api`, set
   `OCR_API_KEY` + `CORS_ALLOWED_ORIGINS` (whitelist origin *iframe* web host).
4. **Backend proxy** (production web) — backend Anda sendiri yang menyuntikkan
   `Authorization` ke cloud API; key tidak pernah sampai browser.

## Development lokal (repo ini)

```bash
# cloud API (fallback) — :3000
cd services/ocr-cloud-api && npm install && npm start

# models server dev — :9090 (serve models.json + model + ort)
node .freebuff/models-server.js

# Flutter web host — :8080
cd apps/web_host && flutter run -d web-server --web-port 8080

# demo React — :5173
cd examples/react-demo && npm install && npm run dev
```

Detail lengkap (launchd, release build, env) ada di `.freebuff/run.md`.

## Testing

```bash
cd packages/ocr_core && flutter test     # 31 test: normalizer, box merging, batching, policy
cd web-sdk-bridge && npm run typecheck
cd examples/react-demo && npx tsc --noEmit
```

## Kontribusi / rilis

Changesets untuk versioning web SDK:

```bash
cd web-sdk-bridge
npx changeset            # tulis perubahan (patch/minor/major)
npx changeset version    # bump + CHANGELOG
git tag v$(node -p "require('./package.json').version") && git push --tags
# → .github/workflows/release.yml publish ke npm (provenance) otomatis
```

CI (`.github/workflows/`): typecheck + pack smoke untuk web SDK; release
tag-gated dengan guard tag↔version.
