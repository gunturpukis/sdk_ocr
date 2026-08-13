# OCR SDK — ocr_core + ocr_ui

Monorepo dua package Flutter:
- **`packages/ocr_core`** — logic murni (tanpa opini UI): model download/cache,
  inference PaddleOCR (deteksi + rekognisi), decision hybrid on-device/cloud.
- **`packages/ocr_ui`** — layar scan siap pakai di atas `ocr_core` (opsional,
  boleh di-skip kalau mau bikin UI sendiri di atas `ocr_core` langsung).

## ⚠️ Status kode ini — baca sebelum lanjut

Saya menulis semua ini **tanpa akses ke Flutter SDK/compiler** (sandbox saya
tidak punya Flutter terinstall), jadi kode ini **belum pernah di-compile atau
dijalankan sama sekali**. Anggap ini sebagai scaffold arsitektur yang solid,
bukan kode yang siap `flutter run` tanpa iterasi. Yang paling perlu Anda
validasi duluan:

1. **`flutter_onnxruntime` API exact** (`inference_session_mobile.dart`) —
   saya tulis berdasarkan contoh dari dokumentasi yang saya baca
   (`createSessionFromAsset`, dst), tapi belum saya cek detail nama method
   untuk load dari file path (`createSessionFromFile`) dan cara ambil output
   tensor (`asFlattenedDataList`) — cek langsung ke source/API docs package
   itu, kemungkinan ada penyesuaian nama method.
2. **`onnxruntime-web` JS interop** (`inference_session_web.dart`) — sama,
   signature `ort.InferenceSession`/`ort.Tensor` perlu dicocokkan ke versi
   yang benar-benar Anda pakai.
3. **`DetectionPostprocessor`** — ini **penyederhanaan besar** dari algoritma
   DB asli PaddleOCR (axis-aligned box, bukan rotated rect + unclip pakai
   pyclipper). Cukup untuk dokumen yang di-scan relatif lurus, tapi kalau
   akurasi kurang bagus di real testing, di sinilah kemungkinan besar
   sumbernya — lihat komentar di file itu untuk detail trade-off-nya.
4. **Belum ada unit test sama sekali** — prioritas berikutnya sebelum
   nulis fitur baru lagi.

## Yang sudah solid (hasil diskusi + validasi sebelumnya)

- Unified response contract (`OcrResult`) dan flow hybrid on-device→cloud
  fallback dengan confidence threshold — ini sudah dipikirkan matang dari
  awal desain, bukan tempelan.
- `ppu-paddle-ocr` (package Node/JS yang sempat kita coba jalankan) terbukti
  real dan berfungsi — model-nya (format `.ort`) dan sumbernya (GitHub LFS
  `ppu-paddle-ocr-models`) itu referensi valid untuk model yang dipakai di
  `ModelManager` Anda, meskipun implementasi inference session di kode ini
  saya tulis manual (bukan pakai package itu), supaya Anda tidak bergantung
  ke library JS pihak ketiga di jalur kritis.
- Conditional export mobile/Web sudah konsisten diterapkan di semua tempat
  yang butuh (`ModelManager`, `InferenceSession`, `LocalTextReader`) — tidak
  ada `dart:io` yang bocor ke build Web.

## Setup

```bash
cd packages/ocr_core && flutter pub get
cd ../ocr_ui && flutter pub get
```

### Model hosting (wajib sebelum SDK bisa jalan)

1. Download model dari `ppu-paddle-ocr-models` (format `.ort`, atau varian
   `.onnx` portable) — jangan langsung pakai URL GitHub LFS mereka di
   production (lihat diskusi sebelumnya soal bandwidth quota).
2. Upload ke CDN Anda sendiri (S3/R2/MinIO).
3. Generate `models.json` — hitung SHA256 tiap file, isi sesuai format di
   `model_manifest.dart`.
4. Pass URL manifest itu ke `OcrClient(modelManifestUrl: ...)`.

### Web — tambahan di `web/index.html`

```html
<script src="https://cdn.jsdelivr.net/npm/onnxruntime-web/dist/ort.min.js"></script>
```

## Pemakaian dasar

```dart
import 'package:ocr_ui/ocr_ui.dart';
import 'package:ocr_core/ocr_core.dart';

final client = OcrClient(
  apiKey: 'xxx',
  baseUrl: 'https://ocr-api.example.com',
  modelManifestUrl: 'https://cdn.example.com/models/models.json',
);

// panggil sekali di awal (splash screen / sebelum buka scan screen)
await client.prepare(
  onProgress: (p) => print('Download model: ${(p * 100).toStringAsFixed(0)}%'),
);

// pakai UI siap pakai
Navigator.push(context, MaterialPageRoute(
  builder: (_) => OcrScanScreen(
    client: client,
    onResult: (result) {
      if (result.success) print(result.rawText);
    },
  ),
));

// ATAU pakai ocr_core langsung tanpa ocr_ui, kalau mau UI custom
final result = await client.scan(imageBytesFromCameraAnda);
```

## Langkah selanjutnya yang saya sarankan (urutan prioritas)

1. `flutter pub get` di kedua package, perbaiki error compile yang muncul
   (kemungkinan besar di `inference_session_mobile.dart`/`_web.dart` sesuai
   catatan di atas).
2. Test `initialize()` dengan model asli — pastikan shape tensor
   input/output cocok dengan asumsi di `image_preprocessing.dart` dan
   `ctc_decoder.dart` (tiap versi model PaddleOCR bisa beda urutan
   dimensi/dictionary).
3. Test `recognize()` dengan foto dokumen asli, bandingkan
   `DetectionPostprocessor` terhadap ekspektasi (apakah box yang terdeteksi
   masuk akal).
4. Baru lanjut ke document-specific parsing (KTP/SIM field extraction) di
   atas `rawText` yang sudah didapat.
