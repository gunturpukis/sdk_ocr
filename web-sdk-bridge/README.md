# @gunturpukis/ocr-scanner-react

SDK web untuk scan dokumen (OCR) di React / Next.js / vanilla JS — jembatan
`postMessage` ke scanner Flutter Web (`apps/web_host`) yang di-embed sebagai
`<iframe>` full-screen. Framework-agnostic: core-nya adalah class
`OcrScannerBridge`; React hanya tinggal hook tipis `useOcrScanner` di atasnya.

```
┌─────────────────────────────┐   postMessage    ┌──────────────────────────┐
│  Aplikasi Anda (React/Next) │◄────────────────►│  apps/web_host (iframe)  │
│  useOcrScanner()            │                  │  OcrClient (ocr_core)    │
└──────────────┬──────────────┘                  └────────────┬─────────────┘
               │ config: iframeUrl,                           │ multipart POST /v1/ocr/read
               │ proxyBaseUrl, modelManifestUrl               │ (Authorization: Bearer …)
               ▼                                              ▼
        [modelManifestUrl → CDN models.json]        [proxyBaseUrl → services/ocr-cloud-api]
```

## Instalasi

```bash
# dari registry npm (setelah publish):
npm i @gunturpukis/ocr-scanner-react

# atau dari tarball lokal:
cd web-sdk-bridge
npm pack               # buat gunturpukis-ocr-scanner-react-0.1.0.tgz
npm i /path/ke/web-sdk-bridge/gunturpukis-ocr-scanner-react-0.1.0.tgz
# atau: npm i file:../web-sdk-bridge   (monorepo)
```

## Publishing (npm)

Package ini dipublikasikan sebagai **`@gunturpukis/ocr-scanner-react`** (MIT).

**One-time setup di mesin Anda:**

```bash
npm login              # akun pemilik scope @gunturpukis; aktifkan 2FA
npm publish --dry-run  # pratinjau: cek daftar file + metadata
cd web-sdk-bridge && npm publish   # publish pertama (manual, butuh OTP 2FA)
```

> `publishConfig.access: "public"` sudah diset — scoped package tidak akan
> ter-publish sebagai restricted.

**Setup CI publish (sekali saja):**

1. Buat npm *Automation* token: npmjs.com → Access Tokens → Generate (type
   Automation — melewati OTP untuk publish dari CI).
2. GitHub repo `gunturpukis/sdk_ocr` → Settings → Secrets and variables →
   Actions → New repository secret: nama `NPM_TOKEN`, isi token tadi.

**Rilis berikutnya (via Changesets):**

```bash
cd web-sdk-bridge
npx changeset          # tulis perubahan + pilih patch/minor/major; commit file .md-nya
npx changeset version  # bump package.json + tulis CHANGELOG.md
npm publish            # publish manual, ATAU:
git tag v$(node -p "require('./package.json').version") && git push --tags
                       # → .github/workflows/release.yml publish otomatis (dgn provenance)
```

CI `.github/workflows/release.yml` menjaga tag harus sama dengan
`package.json` version (fail-fast kalau mismatch) dan memverifikasi
typecheck sebelum publish.

## Prasyarat (WAJIB berjalan dulu)

1. **Cloud OCR API** (`services/ocr-cloud-api`) — `npm install && npm start`,
   tunggu log `[ocr-service] Model siap` + `[server] Cloud OCR API jalan`.
2. **Flutter Web host** (`apps/web_host`) — dev: `flutter run -d chrome
   --web-port 8080`; production: `flutter build web --release` lalu hosting
   folder `build/web/` di belakang **HTTPS**.
3. **models.json** di CDN Anda — manifest berisi URL + SHA256 model `.ort`
   (format sesuai `model_manifest.dart` di `ocr_core`).

## Pemakaian — React (Vite/CRA)

```tsx
import { useOcrScanner } from "@gunturpukis/ocr-scanner-react";

function ScanPage() {
  const { status, progress, result, error, readiness, open, close } = useOcrScanner({
    iframeUrl: import.meta.env.VITE_OCR_IFRAME_URL,        // http://localhost:8080 (dev)
    proxyBaseUrl: import.meta.env.VITE_OCR_PROXY_URL,      // http://localhost:3000 (dev)
    modelManifestUrl: import.meta.env.VITE_OCR_MANIFEST_URL,
  });

  return (
    <div>
      <button
        onClick={() => open().catch(() => {})} // error tersedia di state `error`
        disabled={status === "scanning"}
      >
        {status === "scanning" ? `Memindai... ${Math.round(progress * 100)}%` : "Scan Dokumen"}
      </button>
      {status === "error" && <p style={{ color: "red" }}>{error}</p>}
      {status === "done" && result?.success && (
        <pre>{JSON.stringify(result.data.fields ?? result.data.rawText, null, 2)}</pre>
      )}
    </div>
  );
}
```

Return hook: `{ status, progress, result, error, readiness, open, close }`.
- `status`: `"idle" | "scanning" | "done" | "error"`
- `readiness`: `"onDeviceReady" | "cloudOnlyFallback" | null`
- `open()` resolve dengan `OcrResultPayload` (cek `result.success`), reject
  kalau gagal init / timeout / dibatalkan dari dalam scanner.

## Pemakaian — Next.js (App Router)

Komponen yang memanggil `useOcrScanner` **wajib** `"use client"`, dan
sebaiknya di-import dinamis supaya tidak dirender di server dan bundle
scanner tidak masuk initial load:

```tsx
// app/scan/ScanButton.tsx
"use client";
import { useOcrScanner } from "@gunturpukis/ocr-scanner-react";
// ... (isi sama seperti contoh React di atas / examples/nextjs-usage.tsx)
```

```tsx
// app/scan/page.tsx — Server Component
import dynamic from "next/dynamic";

const ScanButton = dynamic(() => import("./ScanButton"), { ssr: false });

export default function ScanPage() {
  return <ScanButton />;
}
```

Simpan URL di env variables (`NEXT_PUBLIC_OCR_IFRAME_URL`, dst).

## Auth — mana yang dipakai?

`services/ocr-cloud-api` memvalidasi `Authorization: Bearer <OCR_API_KEY>`
di **setiap** request. Secara default bridge pakai mode **hybrid**
(`forceCloud: false`): scan di-device dulu via onnxruntime-web (script tag
ort sudah aktif di `apps/web_host/web/index.html`), dan baru fallback ke
cloud kalau confidence di bawah threshold atau init on-device gagal — jadi
scan umum tidak butuh API key, cloud hanya terpanggil sebagai fallback.
Kalau set `forceCloud: true`, semua scan lewat cloud dan butuh key. Dua opsi:

| | Dev / testing lokal | Production |
|---|---|---|
| Cara | set `apiKey` di config `useOcrScanner` | **same-origin proxy** — JANGAN set `apiKey` |
| Key terlihat di browser? | Ya (DevTools) — ok untuk lokal | Tidak — proxy menyuntik header di server |
| Contoh | `apiKey: "dev-key"` | Next.js Route Handler di bawah |

Contoh proxy Next.js (App Router) — `app/api/ocr/[...path]/route.ts`:

```ts
export const runtime = "nodejs";

const UPSTREAM = process.env.OCR_API_URL; // http://localhost:3000, TIDAK NEXT_PUBLIC_*
const API_KEY = process.env.OCR_API_KEY;  // idem

export async function POST(req: Request, { params }: { params: Promise<{ path: string[] }> }) {
  const { path } = await params;
  const form = await req.formData();
  const upstream = await fetch(`${UPSTREAM}/${path.join("/")}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${API_KEY}` },
    body: form,
  });
  return new Response(upstream.body, {
    status: upstream.status,
    headers: { "content-type": upstream.headers.get("content-type") ?? "application/json" },
  });
}
```

Lalu di client: `proxyBaseUrl: "/api/ocr"` — request iframe jadi same-origin,
CORS tidak relevan, dan key asli tidak pernah keluar dari server.

## Troubleshooting

| Gejala | Penyebab & fix |
|---|---|
| `INVALID_API_KEY` / hasil error 401 | `apiKey` tidak terkirim ke iframe (dev) atau proxy belum menyuntik `Authorization` (prod). Cek log `OCR_LOG` via `onLog`. |
| Timeout `120s` di `open()` | `iframeUrl` salah / tidak bisa diakses dari browser user, atau init OCR menggantung. Buka URL iframe langsung di tab untuk memastikan app Flutter-nya load. |
| Blank iframe, error di console soal mixed content | Halaman `https://` meng-iframe `http://...` — web host HARUS di-hosting di HTTPS di production (ngrok tunnel untuk uji device). |
| `blocked by CORS policy` di request `/v1/ocr/read` | Origin **domain iframe** (bukan domain React Anda) belum di-whitelist di `services/ocr-cloud-api`. Set `CORS_ALLOWED_ORIGINS` di `.env` server (localhost otomatis diizinkan), atau pakai proxy same-origin. |
| Kamera tidak muncul | Izin kamera ditolak / halaman tidak secure context (HTTPS atau localhost), atau atribut `allow="camera"` hilang (sudah otomatis oleh bridge). |
| Progress model tidak jalan | `onProgress` hanya aktif saat model di-download pertama kali — kalau sudah ter-cache di Cache Storage browser, langsung 100%. |

## Catatan performa & COOP/COEP

Jalur on-device web memakai build WASM single-thread dari onnxruntime-web
(script tag ter-pin di `apps/web_host/web/index.html`) — build ini tidak
butuh header COOP/COEP di halaman host app. Kalau nanti pindah ke varian
WASM threads (lebih cepat), halaman **host app React/Next** butuh header
COOP/COEP supaya `SharedArrayBuffer` tersedia — contoh `next.config.js`
ada di `examples/nextjs-usage.tsx`.
