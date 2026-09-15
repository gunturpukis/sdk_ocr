# Panduan Web — Next.js (App Router)

Integrasi ke Next.js. Satu perbedaan dengan React biasa: hook `useOcrScanner`
butuh `window`, jadi komponennya **wajib `'use client'`** dan sebaiknya
di-import dinamis tanpa SSR.

> Contoh kode lengkap juga ada di `web-sdk-bridge/examples/nextjs-usage.tsx`.

---

## Langkah 1 — Install

```bash
npm i @gunturpukis/ocr-scanner-react
```

## Langkah 2 — Komponen client

```tsx
// components/ScanButton.tsx
"use client"; // WAJIB — hook butuh window/DOM

import { useOcrScanner } from "@gunturpukis/ocr-scanner-react";

export default function ScanButton() {
  const { status, progress, result, error, readiness, open } = useOcrScanner({
    iframeUrl: process.env.NEXT_PUBLIC_OCR_IFRAME_URL!,   // https://scan.yourapp.com
    proxyBaseUrl: "/api/ocr",                             // proxy same-origin (langkah 3)
    modelManifestUrl: process.env.NEXT_PUBLIC_OCR_MANIFEST_URL!,
    confidenceThreshold: 85,
    forceCloud: false,
  });

  return (
    <div>
      <button
        onClick={() => open().catch(() => {})}
        disabled={status === "scanning"}
      >
        {status === "scanning"
          ? `Memindai… ${Math.round(progress * 100)}%`
          : "Scan Dokumen"}
      </button>

      {readiness && <small>engine: {readiness}</small>}
      {status === "error" && <p style={{ color: "red" }}>{error}</p>}
      {status === "done" && result?.success && (
        <pre>{result.data.rawText}</pre>
      )}
    </div>
  );
}
```

## Langkah 3 — Lazy-load tanpa SSR

```tsx
// app/scan/page.tsx — Server Component
import dynamic from "next/dynamic";

const ScanButton = dynamic(() => import("@/components/ScanButton"), {
  ssr: false, // bundle iframe scanner tidak masuk initial load
});

export default function ScanPage() {
  return <ScanButton />;
}
```

## Langkah 4 — Proxy auth same-origin (production)

API key tinggal di server. Buat Route Handler yang menyuntikkan header
`Authorization`:

```ts
// app/api/ocr/[...path]/route.ts
export const runtime = "nodejs";

const UPSTREAM = process.env.OCR_API_URL;  // http://ocr-api-internal:3000 (TIDAK NEXT_PUBLIC_*)
const API_KEY = process.env.OCR_API_KEY;   // idem

export async function POST(
  req: Request,
  { params }: { params: Promise<{ path: string[] }> },
) {
  const { path } = await params;
  const form = await req.formData();
  const upstream = await fetch(`${UPSTREAM}/${path.join("/")}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${API_KEY}` },
    body: form,
  });
  return new Response(upstream.body, {
    status: upstream.status,
    headers: {
      "content-type": upstream.headers.get("content-type") ?? "application/json",
    },
  });
}
```

`.env.local`:

```bash
NEXT_PUBLIC_OCR_IFRAME_URL=https://scan.yourapp.com
NEXT_PUBLIC_OCR_MANIFEST_URL=https://cdn.yourapp.com/models/models.json
OCR_API_URL=https://ocr-api.yourapp.com
OCR_API_KEY=<rahasia — jangan NEXT_PUBLIC_*>
```

Client memakai `proxyBaseUrl: "/api/ocr"` → request dari iframe jadi
same-origin dengan host app: **CORS tidak relevan dan key tidak pernah
terlihat di browser**.

## Langkah 5 — Env & hosting host Flutter

- Semua variabel yang dipakai di client **wajib** prefix `NEXT_PUBLIC_`.
- Flutter web host (`apps/web_host`) di-hosting terpisah di HTTPS
  (`flutter build web --release` → folder `build/web/`).
- Halaman `https://` tidak boleh meng-iframe `http://`.
- CORS cloud API: whitelist **origin iframe**, bukan origin Next.js.

## Langkah 6 — (Opsional) WASM threads lebih cepat

Build ort single-thread saat ini tidak butuh header khusus. Kalau pindah ke
varian WASM threads (inference lebih cepat di halaman padat), host app
Next.js butuh header COOP/COEP:

```js
// next.config.js
module.exports = {
  async headers() {
    return [
      {
        source: "/(.*)",
        headers: [
          { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
          { key: "Cross-Origin-Embedder-Policy", value: "require-corp" },
        ],
      },
    ];
  },
};
```

(Catatan: `require-corp` menuntut semua resource lintas-origin punya
`CORP`/CORS yang benar — uji menyeluruh sebelum diaktifkan.)

## Checklist smoke

- [ ] `next build` sukses (tidak ada akses `window` saat SSR)
- [ ] Scan pertama download model + progress jalan di production domain
- [ ] Proxy `/api/ocr/...` 200 dan `Authorization` tidak muncul di DevTools
- [ ] Fallback cloud terjadi benar saat confidence < threshold
- [ ] Tidak ada error mixed-content / CSP di console
