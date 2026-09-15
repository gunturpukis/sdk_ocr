# Panduan Web — Vue 3

SDK web-nya framework-agnostic: class **`OcrScannerBridge`** yang sama
dipakai React (via hook) dan Vue (via composable). Panduan ini membungkusnya
jadi `useOcrScanner()` untuk Vue 3 (Composition API).

> `@gunturpukis/ocr-scanner-react` berisi `OcrScannerBridge` murni —
> tidak ada kode React di jalurnya, jadi aman dipakai dari Vue.
> (Saat package berisi dua modul: `OcrScannerBridge.js` dan hook React;
> Vue cukup meng-import class-nya saja.)

---

## Langkah 1 — Install

```bash
npm i @gunturpukis/ocr-scanner-react
```

## Langkah 2 — Composable `useOcrScanner`

```ts
// composables/useOcrScanner.ts
import { onBeforeUnmount, ref, shallowRef } from "vue";
import { OcrScannerBridge, type OcrResultPayload, type OcrScannerConfig } from "@gunturpukis/ocr-scanner-react";

export type OcrStatus = "idle" | "scanning" | "done" | "error";

/**
 * Bungkus OcrScannerBridge jadi composable Vue.
 * CATATAN: config di-capture SEKALI saat composable dibuat — sama seperti
 * perilaku hook React. Jangan render tombol scan sebelum config async siap.
 */
export function useOcrScanner(config: OcrScannerConfig) {
  const status = ref<OcrStatus>("idle");
  const progress = ref(0);
  const result = shallowRef<OcrResultPayload | null>(null);
  const error = ref<string | null>(null);
  const readiness = ref<string | null>(null);

  const bridge = new OcrScannerBridge({
    ...config,
    onProgress: (p) => (progress.value = p),
    onReady: (r) => (readiness.value = r),
    onLog: (m, e) => config.onLog?.(m, e),
    onCancel: () => (status.value = "idle"),
  });

  async function open(): Promise<OcrResultPayload> {
    status.value = "scanning";
    error.value = null;
    result.value = null;
    progress.value = 0;
    try {
      const payload = await bridge.open();
      result.value = payload;
      status.value = "done";
      return payload;
    } catch (e) {
      error.value = e instanceof Error ? e.message : String(e);
      status.value = "error";
      throw e;
    }
  }

  function close() {
    bridge.close();
    status.value = "idle";
  }

  onBeforeUnmount(() => bridge.close());

  return { status, progress, result, error, readiness, open, close };
}
```

## Langkah 3 — Pakai di komponen

```vue
<script setup lang="ts">
import { useOcrScanner } from "@/composables/useOcrScanner";

const { status, progress, result, error, readiness, open, close } = useOcrScanner({
  iframeUrl: import.meta.env.VITE_OCR_IFRAME_URL,     // https://scan.yourapp.com
  proxyBaseUrl: import.meta.env.VITE_OCR_PROXY_URL,   // /api/ocr (proxy same-origin)
  modelManifestUrl: import.meta.env.VITE_OCR_MANIFEST_URL,
  confidenceThreshold: 85,
  forceCloud: false,
  onLog: (m) => console.log("[ocr]", m),
});

async function handleScan() {
  try {
    await open();
  } catch {
    // error sudah ada di state `error` — biarkan UI yang menampilkan
  }
}
</script>

<template>
  <button :disabled="status === 'scanning'" @click="handleScan">
    {{ status === 'scanning' ? `Memindai… ${Math.round(progress * 100)}%` : 'Scan Dokumen' }}
  </button>

  <small v-if="readiness">engine: {{ readiness }}</small>
  <p v-if="status === 'error'" class="err">{{ error }}</p>
  <pre v-if="status === 'done' && result?.success">{{ result.data.rawText }}</pre>
</template>
```

## Langkah 4 — Nuxt 3 (jika dipakai)

Sama pola dengan Next.js:

1. Komponen yang memanggil `useOcrScanner` bungkus `<ClientOnly>` (bridge
   butuh `window`).
2. Proxy auth via **server route** `server/api/ocr/[...path].ts`
   (hapi `defineEventHandler` + `readMultipartFormData`, set header
   `Authorization` dari `process.env.OCR_API_KEY` — key tidak pernah ke client).
3. Env client pakai `NUXT_PUBLIC_*` (`runtimeConfig.public`).

## Langkah 5 — Prasyarat yang sama dengan React

- Flutter web host ter-deploy di HTTPS (`apps/web_host` → `build/web/`).
- `proxyBaseUrl` menunjuk backend Anda sendiri (menyuntik `Authorization`) —
  **jangan** set `apiKey` di client production.
- CORS cloud API: whitelist **origin iframe** (domain web host), bukan
  origin Vue/Nuxt.
- Model ±139MB ter-cache di browser setelah scan pertama; sambut user
  pertama dengan state "menyiapkan mesin…" (progress sudah dikirim via
  `onProgress`).

## Perbedaan perilaku vs React hook

| Aspek | React hook | Composable Vue di atas |
|---|---|---|
| Sumber | dari package | Anda tulis sendiri (±60 baris, di atas) |
| Reaktivitas | `useState` | `ref`/`shallowRef` |
| Cleanup | `useEffect` return | `onBeforeUnmount` |
| Kontrak bridge | identik | identik (`open()/close()`, callback) |

Kalau ingin composable resmi di dalam package (mis. subpath
`@gunturpukis/ocr-scanner-react/vue`), itu perubahan kecil di `exports` map —
minta saja.

## Checklist smoke

- [ ] `npm run build` sukses tanpa akses `window` saat SSR (Nuxt)
- [ ] Scan pertama: progress → `OCR_READY` → hasil tampil reaktif
- [ ] `open()` gagal (URL salah) → `status: error`, tidak ada unhandled rejection
- [ ] Tutup tab/komponen unmount saat scanning → iframe tertutup bersih
