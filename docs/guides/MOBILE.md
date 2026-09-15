# Panduan Mobile — Flutter (iOS & Android)

Integrasi SDK OCR ke aplikasi Flutter native memakai `ocr_core` (logic) +
`ocr_ui` (layar kamera siap pakai, opsional).

> **Status penting:** jalur mobile **belum pernah diverifikasi di perangkat
> asli** (lihat `docs/AUDIT.md` P1). Panduan ini menyertakan langkah
> verifikasi API `flutter_onnxruntime` yang wajib Anda lakukan — nama method
> di `inference_session_mobile.dart` ditulis dari dokumentasi, bukan hasil
> kompilasi.

---

## Arsitektur singkat

```
Aplikasi Anda (Flutter)
├── ocr_ui    → OcrScanScreen (kamera, overlay, badge) — opsional
└── ocr_core  → OcrClient
      ├── ModelManager      : download model .ort dari CDN + verifikasi SHA256 + cache
      ├── InferenceSession  : PaddleOCR det+rec via flutter_onnxruntime (native)
      ├── InputNormalizer   : palet/1-bit → RGB, kontras stretch
      └── fallback → cloud  : POST {baseUrl}/v1/ocr/read (Bearer API key)
```

Hybrid by default: on-device dulu → kalau `confidence < threshold` atau init
gagal → cloud. `forceCloud: true` memaksa semua scan ke cloud.

---

## Langkah 1 — Tambahkan dependency

`pubspec.yaml` aplikasi Anda:

```yaml
dependencies:
  ocr_core:
    path: ../sdk_ocr/packages/ocr_core   # atau git URL / path private
  ocr_ui:
    path: ../sdk_ocr/packages/ocr_ui     # opsional, hanya kalau pakai UI siap pakai
  camera: ^0.12.0+2                      # hanya kalau pakai ocr_ui
  image_picker: ^1.2.3                   # opsional (pilih dari galeri)
```

```bash
flutter pub get
```

> Sampai package dipublish ke pub.dev, pakai `path:` (atau hosted git private).
> Struktur monorepo ini memang belum pub — publikasi pub.dev bisa jadi
> langkah lanjutan (beda alur dari npm).

## Langkah 2 — Izin kamera (wajib)

**iOS — `ios/Runner/Info.plist`:**

```xml
<key>NSCameraUsageDescription</key>
<string>Kamera digunakan untuk memindai dokumen.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Galeri dipakai untuk memilih foto dokumen.</string>
```

**Android — `android/app/src/main/AndroidManifest.xml`:**

```xml
<uses-permission android:name="android.permission.CAMERA" />
<!-- package camera sudah handle permission runtime; ini deklarasi statisnya -->
```

**Android minSdk:** `flutter_onnxruntime` butuh `minSdkVersion 21`+ (cek
`android/app/build.gradle`) dan ABI `arm64-v8a`/`armeabi-v7a` (sudah default).

## Langkah 3 — Verifikasi API flutter_onnxruntime (P1 — WAJIB)

File `packages/ocr_core/lib/src/engine/inference_session_mobile.dart` memakai:

```dart
final _ort = OnnxRuntime();
_session = await _ort.createSession(modelPath);        // path filesystem
final outputs = await session.run({inputNames.first: ortInput});
final raw = await outputTensor.asFlattenedList();
```

Cocokkan ke source package yang terinstall:

```bash
grep -rn "createSession\|asFlattenedList\|OrtValue.fromList" \
  ~/.pub-cache/hosted/pub.dev/flutter_onnxruntime-*/lib/
```

Kalau nama method beda (mis. `createSessionFromFile`), sesuaikan
`inference_session_mobile.dart` — strukturnya sudah benar, hanya nama API yang
mungkin bergeser antar versi.

## Langkah 4 — Siapkan model + manifest

Model `.ort` diunduh saat runtime (bukan dibundel), diverifikasi SHA256, lalu
di-cache di dokumen directory:

1. Host `models.json` + file `.ort` di CDN/S3 Anda (contoh format ada di
   `services/ocr-cloud-api/models-cache/models.json`).
2. Untuk dev lokal: jalankan `node .freebuff/models-server.js` (:9090) dan pakai
   `http://<IP-LAN-anda>:9090/models.json` dari emulator/perangkat.
3. Ukuran model ±139MB — tampilkan progress download ke user (SDK sudah kirim
   `onProgress` 0..1).

## Langkah 5 — Inisialisasi client (sekali, di splash/login)

```dart
import 'package:ocr_core/ocr_core.dart';

final client = OcrClient(
  apiKey: const String.fromEnvironment('OCR_API_KEY'), // dev saja; prod pakai proxy
  baseUrl: 'https://ocr-api.yourapp.com',
  modelManifestUrl: 'https://cdn.yourapp.com/models/models.json',
  confidenceThreshold: 85,
);

final readiness = await client.prepare(
  onProgress: (p) => debugPrint('model ${(p * 100).toStringAsFixed(0)}%'),
);
// readiness == OcrReadiness.onDeviceReady → hybrid siap
// readiness == OcrReadiness.cloudOnlyFallback → semua scan lewat cloud
```

Simpan `client` di scope aplikasi (provider/locator). `prepare()` idempotent
untuk dipanggil ulang kalau gagal (background retry otomatis tiap 5 menit juga
berjalan).

## Langkah 6A — Pakai layar siap pakai (ocr_ui)

```dart
import 'package:ocr_ui/ocr_ui.dart';

Navigator.push(context, MaterialPageRoute(
  builder: (_) => OcrScanScreen(
    client: client,
    onResult: (result) {
      if (result.success) {
        debugPrint(result.rawText);
        Navigator.pop(context); // kembali ke form dengan hasil
      }
    },
  ),
));
```

Layar ini menyediakan: preview kamera belakang, frame overlay rasio kartu ID,
tombol capture, badge confidence + sumber (on-device/cloud).

## Langkah 6B — UI sendiri (ocr_core langsung)

```dart
final bytes = await cameraController.takePicture().then((f) => f.readAsBytes());
final result = await client.scan(bytes);            // hybrid
// atau: await client.scan(bytes, forceCloud: true); // selalu cloud

if (result.success) {
  print(result.rawText);          // teks penuh
  print(result.confidence);       // 0..100
  print(result.source);           // OcrSource.onDevice | OcrSource.cloud
} else {
  print(result.error?.code);      // INVALID_API_KEY, RATE_LIMITED, NO_CONNECTIVITY, ...
}
```

`OcrScanScreen` juga punya tombol galeri yang bisa diaktifkan (saat ini
dikomentari di source) — atau implementasikan lewat `image_picker` + `scan()`.

## Langkah 7 — Checklist smoke test perangkat asli

- [ ] `flutter run` di iOS simulator (kamera = virtual) → cek init tidak crash
- [ ] Perangkat Android fisik: scan dokumen cetak → confidence ≥ 85
- [ ] Mode pesawat + model sudah ter-cache → scan on-device tetap jalan
- [ ] Mode pesawat + model belum ada → error `NO_CONNECTIVITY` rapi (bukan crash)
- [ ] API key salah → error `INVALID_API_KEY` muncul di UI
- [ ] Rotasi dokumen 10–15° → catat akurasi (detektor axis-aligned — AUDIT P3)

---

*Pertanyaan arsitektur jawabannya ada di `docs/AUDIT.md`. Untuk web: lihat
[`REACT.md`](REACT.md) / [`NEXTJS.md`](NEXTJS.md) / [`VUE.md`](VUE.md).*
