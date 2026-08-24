# Cloud OCR API

Server Express yang jalankan PaddleOCR model **medium** (lebih besar/akurat
dari `small` yang dipakai on-device) — dipakai lewat `CloudDataSource` di
`ocr_core`, baik untuk fallback confidence rendah maupun dipanggil paksa
lewat `client.scan(bytes, forceCloud: true)` untuk dokumen yang memang
selalu butuh model besar (NIB, dsb).

## ⚠️ Status — belum tervalidasi jalan sungguhan

Sama seperti beberapa komponen sebelumnya, saya **tidak bisa jalankan
server ini sampai selesai di sandbox saya** — `onnxruntime-node` butuh
download binary native dari `nuget.org` yang diblokir jaringan sandbox
saya (`Failed to download Nuget index`). Ini murni keterbatasan sandbox
saya, bukan bug di kode. Saya sudah validasi sintaks semua file (`node
--check`, semua lolos), tapi **belum pernah jalan end-to-end**. Jalankan
di mesin Anda untuk validasi penuh — kemungkinan ada 1-2 putaran fix
kecil seperti biasa.

## Setup

```bash
npm install
cp .env.example .env
```

Edit `.env`:
1. `OCR_API_KEY` — ganti dengan key acak yang kuat (contoh generate: `openssl rand -hex 32`)
2. `MODEL_DET_URL`, `MODEL_REC_URL`, `MODEL_DICT_URL` — arahkan ke file
   model **medium** yang sudah/akan Anda upload ke R2 (bucket `model-ocr`
   yang sama). **Bukan** URL GitHub LFS langsung — sama seperti pelajaran
   sebelumnya soal bandwidth quota, ini extra penting di server karena
   kalau server restart berkali-kali (deploy, scaling, crash-restart),
   tiap restart re-download model dari sumbernya.

## Jalankan

```bash
npm start
```

Model di-load sekali saat startup (bukan per-request) — tunggu sampai
muncul:
```
[ocr-service] Model siap dalam ????ms
[server] Cloud OCR API jalan di http://localhost:3000
```

Loading model **medium** (~139MB) kemungkinan besar butuh waktu cukup
lama saat startup pertama (fetch dari R2 + inisialisasi ONNX Runtime).

## Test manual

```bash
curl -X POST http://localhost:3000/v1/ocr/read \
  -H "Authorization: Bearer <OCR_API_KEY dari .env Anda>" \
  -F "image=@/path/ke/foto-nib.jpg"
```

Response yang diharapkan (format sama persis dengan `OcrResult` di
`ocr_core`, jadi `CloudDataSource.recognize()` bisa langsung parse):
```json
{
  "success": true,
  "message": "OCR success",
  "meta": { "source": "cloud", "engine": "paddle_ocr_medium", "processingTimeMs": 1234 },
  "data": { "documentType": "GENERIC", "confidence": 94.2, "rawText": "...", "fields": null },
  "error": null
}
```

## Hubungkan ke Flutter

Di `OcrClient`, ganti `baseUrl` dan `apiKey` dari placeholder ke server
ini:

```dart
final client = OcrClient(
  apiKey: '<OCR_API_KEY yang sama seperti di .env server>',
  baseUrl: 'http://localhost:3000',  // atau URL public server Anda
  modelManifestUrl: '...',
);

// KTP — hybrid biasa (coba on-device dulu)
final ktpResult = await client.scan(ktpBytes);

// NIB — paksa langsung ke cloud (model medium ini)
final nibResult = await client.scan(nibBytes, forceCloud: true);
```

**Untuk testing dari device fisik/simulator** (bukan cuma dari mesin yang
sama), `localhost` tidak akan bisa diakses — perlu expose lewat ngrok
juga, sama persis pola yang sudah kita pakai untuk model hosting:
```bash
ngrok http 3000
```
lalu pakai URL ngrok itu sebagai `baseUrl`.

## Yang belum ada (perlu iterasi lanjutan)

- **Document-type detection otomatis** — sekarang semua hasil ditandai
  `documentType: "GENERIC"`. Kalau nanti mau auto-detect KTP vs NIB vs
  SKCK dari cloud, perlu logic tambahan (bisa reuse pendekatan
  `KtpParser` untuk deteksi berbasis keyword).
- **Structured field extraction di sisi cloud** — `KtpParser` sekarang
  cuma jalan di `ocr_core` (client). Kalau NIB juga butuh field
  terstruktur, perlu bangun parser serupa (`NibParser`) — bisa di
  client (setelah dapat rawText dari cloud) atau di server.
- **Persistent rate limiting** — implementasi sekarang in-memory per-IP,
  reset kalau server restart. Cukup untuk MVP, tidak cukup untuk
  production skala besar.
- **Logging/monitoring** — belum ada, penting untuk tahu berapa banyak
  request gagal/lambat di production.
