# Audit Proyek — OCR SDK Monorepo

Tanggal: 15 September 2026 · Scope: seluruh repo (`packages/*`, `web-sdk-bridge`,
`apps/web_host`, `services/ocr-cloud-api`, `examples/*`, CI, docs).

---

## 1. Ringkasan

| Area | Status | Catatan |
|---|---|---|
| Arsitektur & pemisahan layer | ✅ **Kuat** | Kontrak respons terpadu konsisten di Dart/JS/Node |
| Jalur Web (on-device + cloud) | ✅ **Teruji live** | 31 unit test + verifikasi E2E di browser |
| Jalur Mobile (Flutter) | ⚠️ **Belum terverifikasi** | Tidak pernah dijalankan di perangkat iOS/Android asli |
| Web SDK (npm) | ✅ **Siap rilis** | Scoped package, MIT, CI, changesets — tinggal `npm publish` |
| Cloud API | ✅ layak MVP | Rate limit in-memory & satu API key perlu upgrade sebelum scale |
| Keamanan | ✅ solid untuk produksi | postMessage tervalidasi origin, pola proxy auth benar |
| Dokumentasi | ⚠️ README akar basi | Klaim lama sudah tidak akurat — telah ditulis ulang |

**Kesimpulan:** fondasi produksi yang layak. Jalur web adalah yang paling matang;
jalur mobile adalah utang verifikasi terbesar (bukan utang desain — arsitekturnya sudah benar).

---

## 2. Yang ditemukan kuat

1. **Kontrak `OcrResult` seragam di semua lapisan.** Bentuk respons
   `{ success, data: { confidence, rawText, documentType, fields }, meta: { source, processingTimeMs }, error: { code, detail } }`
   identik di `ocr_core` (Dart), `web-sdk-bridge` (TS), dan `services/ocr-cloud-api`
   (Node) — termasuk error 401/429 yang mengembalikan kontrak yang sama, sehingga
   client Flutter bisa mengurai kegagalan cloud seperti respons normal.
2. **Conditional export bersih.** `ModelManager`, `InferenceSession`,
   `LocalTextReader` semuanya memakai conditional export `dart.library.io` /
   `dart.library.html` — `dart:io` tidak pernah bocor ke build web.
3. **Mesin web benar-benar tervalidasi.** 31/31 unit test (`ocr_core`), plus
   verifikasi live end-to-end: normalisasi input memperbaiki 300-dpi scan dari
   keyakinan 62 → 99–100, batched recognition dikonfirmasi aktif
   (`24 strip → 3 panggilan ort`), dan fallback cloud terlog dengan alasannya.
4. **Keamanan jembatan dipikirkan serius.** `OcrScannerBridge` mengirim pesan
   keluar dengan `targetOrigin` persis origin iframe dan memvalidasi
   `event.origin` + `event.source` untuk pesan masuk; URL iframe divalidasi
   sejak constructor.
5. **Pola auth yang benar terdokumentasi.** API key tidak pernah dibundel di
   produksi — pola proxy same-origin (menyuntikkan `Authorization` di server)
   contoh Route Handler Next.js-nya sudah ada di README package.
6. **Cloud API pertahanan dasar lengkap:** CORS diizinkan pada origin *iframe*
   (bukan origin host — penjelasannya benar dan sesuai cara request benar-benar
   mengalir), rate limit 30 req/menit/IP, batas upload 10 MB, model pre-load saat startup.
7. **Rilis npm siap:** scoped `@gunturpukis/ocr-scanner-react`, MIT, `files: dist`,
   `publishConfig.access`, CI typecheck + pack-smoke, rilis berbasis tag dengan
   provenance + pemeriksaan kesesuaian tag↔versi, changesets terpasang.

---

## 3. Celah & risiko (urutan prioritas)

### P1 — Jalur mobile belum pernah dieksekusi di perangkat
`inference_session_mobile.dart` ditulis terhadap API `flutter_onnxruntime`
(`createSession`, `OrtValue.fromList`, `asFlattenedList`) **tanpa pernah
dikompilasi ke iOS/Android**. `OcrScanScreen` (kamera + overlay + badge) juga
belum pernah dirender di perangkat. Izin kamera (iOS `NSCameraUsageDescription`,
Android `CAMERA`) belum dikonfigurasi di mana pun — dan memang belum ada
aplikasi Flutter contoh di repo. **Aksi:** buat `examples/flutter_app` minimal,
jalankan di perangkat asli, cocokkan API `flutter_onnxruntime` yang sebenarnya.
(Panduan langkah demi langkah: `docs/guides/MOBILE.md`.)

### P2 — README akar menyatakan klaim basi
Menyatakan "belum pernah di-compile" dan "belum ada unit test sama sekali" —
keduanya sekarang salah (semuanya terkompilasi, 31 test lolos, jalur web
terverifikasi live). **Aksi:** selesai — README telah ditulis ulang dan
menautkan dokumen panduan ini.

### P3 — Keterbatasan detektor yang terdokumentasi (keterbatasan yang diketahui)
`DetectionPostprocessor` memakai sumbu-sejajar (axis-aligned) box, bukan
rotated-rect + unclip ala PaddleOCR asli. Dokumen miring/berotasi masih lemah.
Kotak (box) yang digabung dalam satu baris + pemisahan strip (strip splitting)
sudah memperbaiki dokumen padat, tapi rotasi besar tetap celah akurasi. **Aksi:**
jika kasus nyata banyak dokumen miring, implementasikan unclip (pyclipper) +
estimasi sudut.

### P4 — Cloud API masih MVP
Rate limit in-memory (hilang saat restart, per-instance), satu API key statis
(tidak ada rotasi / multi-tenant), belum ada test sama sekali. **Aksi sebelum
skala:** Redis-based limiter, key per-klien + rotasi, minimal smoke test endpoint.

### P5 — URL dev menempel di konfigurasi host
`apps/web_host/web/index.html` menunjuk `http://localhost:9090` untuk ort +
manifest (sudah diberi komentar produksi, tapi belum mekanisme config). **Aksi:**
buat langkah substitusi saat build (mis. `--dart-define` / env → template) untuk
deployment produksi.

### P6 — CI belum mencakup Flutter
`.github/workflows/ci.yml` hanya typecheck + pack `web-sdk-bridge`. **Aksi:**
tambahkan job `flutter analyze` + `flutter test` untuk `packages/ocr_core`.

### P7 — Hal kecil yang rapi
- `ocr_core`: 5 analyzer warning lama (`unnecessary_cast` dll).
- `ocr_ui`: `_GalleryButton` tidak terpakai (dikomentari di UI) — hidupkan atau hapus.
- Tarball demo + `models-cache/bench/` jangan sampai ter-commit (sudah dicek gitignore).

---

## 4. Verifikasi yang dijalankan saat audit

- `flutter analyze` + `flutter test` — `ocr_core`: **31/31 lolos**, 5 warning lama.
- `flutter analyze` — `ocr_ui`: 2 warning (kosmetik, daftar di atas).
- `web-sdk-bridge` `tsc --noEmit` — bersih.
- Smoke server: :8080 (release host), :5173 (demo), :9090 (models + ort, MIME benar),
  :3000 (`/health` 200) — semua hidup.
- Scan E2E lewat cloud terverifikasi: sukses, keyakinan 96.9% (sintetis) dan
  99.1% (dokumen SKCK nyata).

---

## 5. Panduan pemakaian SDK (tautan)

| Platform | Dokumen |
|---|---|
| Flutter mobile (iOS/Android) | [`docs/guides/MOBILE.md`](guides/MOBILE.md) |
| React (Vite/CRA) | [`docs/guides/REACT.md`](guides/REACT.md) |
| Next.js (App Router) | [`docs/guides/NEXTJS.md`](guides/NEXTJS.md) |
| Vue 3 | [`docs/guides/VUE.md`](guides/VUE.md) |
