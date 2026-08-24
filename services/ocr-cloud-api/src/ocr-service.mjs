import { PaddleOcrService } from "ppu-paddle-ocr";
import { loadImage, createCanvas } from "@napi-rs/canvas";
import { mkdirSync, existsSync, statSync, createWriteStream } from "fs";
import { join } from "path";

const MODEL_CACHE_DIR = "./models-cache";

let serviceInstance = null;
let initPromise = null;

/// Download file ke disk lokal dengan fetch kita sendiri (BUKAN lewat
/// library ppu-paddle-ocr) — supaya kita kontrol penuh timeout-nya.
/// Library itu punya timeout internal yang terlalu pendek untuk file
/// besar (model medium ~60-77MB) lewat koneksi yang tidak secepat CDN
/// asli (misal tunnel ngrok saat development) — solusinya bukan
/// mengakali timeout itu, tapi hindari sama sekali: kita download
/// duluan pakai fetch tanpa batas waktu ketat, simpan lokal, baru
/// kasih PATH LOKAL ke PaddleOcrService (bukan URL remote). Loading
/// dari file lokal itu instan, tidak akan pernah kena masalah timeout.
async function ensureLocalFile(url, filename) {
  const destPath = join(MODEL_CACHE_DIR, filename);

  if (existsSync(destPath) && statSync(destPath).size > 0) {
    console.log(`[ocr-service] ${filename} sudah ada di cache lokal, skip download`);
    return destPath;
  }

  console.log(`[ocr-service] Download ${filename} dari ${url}...`);
  const start = Date.now();

  const response = await fetch(url); // fetch bawaan Node — tanpa timeout ketat seperti library
  if (!response.ok) {
    throw new Error(`Gagal download ${filename}: HTTP ${response.status}`);
  }

  const buffer = Buffer.from(await response.arrayBuffer());
  await new Promise((resolve, reject) => {
    const stream = createWriteStream(destPath);
    stream.on("error", reject);
    stream.on("finish", resolve);
    stream.write(buffer);
    stream.end();
  });

  console.log(`[ocr-service] ${filename} selesai (${buffer.length} bytes, ${Date.now() - start}ms)`);
  return destPath;
}

/// Inisialisasi sekali di startup server (model loading itu operasi
/// berat — beberapa detik — jangan dilakukan per-request). Semua
/// request berikutnya reuse instance yang sama.
export async function getOcrService() {
  if (serviceInstance) return serviceInstance;
  if (initPromise) return initPromise; // hindari race condition kalau ada request bersamaan saat startup

  initPromise = (async () => {
    console.log("[ocr-service] Memuat model medium...");
    const start = Date.now();

    mkdirSync(MODEL_CACHE_DIR, { recursive: true });

    // Download SENDIRI dulu ke lokal (lihat penjelasan di ensureLocalFile),
    // baru kasih path lokal ke PaddleOcrService — bukan URL remote.
    const [detPath, recPath, dictPath] = await Promise.all([
      ensureLocalFile(process.env.MODEL_DET_URL, "det.ort"),
      ensureLocalFile(process.env.MODEL_REC_URL, "rec.ort"),
      ensureLocalFile(process.env.MODEL_DICT_URL, "dict.txt"),
    ]);

    const service = new PaddleOcrService({
      model: {
        detection: detPath,
        recognition: recPath,
        charactersDictionary: dictPath,
      },
      debugging: { debug: false, verbose: false },
    });

    await service.initialize();

    console.log(`[ocr-service] Model siap dalam ${Date.now() - start}ms`);
    serviceInstance = service;
    return service;
  })();

  return initPromise;
}

/// Konversi Buffer gambar upload (dari multer) jadi objek Canvas —
/// ppu-paddle-ocr di Node (lewat dependency ppu-ocv) expect Canvas
/// (@napi-rs/canvas), BUKAN Buffer mentah, meski contoh di dokumentasi
/// terlihat seperti terima Buffer langsung. Ini mirroring persis
/// implementasi internal nodePlatform.loadImage() di ppu-ocv.
export async function bufferToCanvas(buffer) {
  const img = await loadImage(buffer);
  const canvas = createCanvas(img.width, img.height);
  const ctx = canvas.getContext("2d");
  ctx.drawImage(img, 0, 0);
  return canvas;
}

/// Konversi hasil ppu-paddle-ocr ke unified response contract yang
/// sama persis dipakai on-device (ocr_core) — supaya CloudDataSource
/// di Flutter parse dengan OcrResult.fromJson() yang sama, consumer
/// app tidak perlu tahu bedanya sama sekali.
export function toUnifiedResponse(rawResult, processingTimeMs) {
  const minConfidence = Number(process.env.MIN_CONFIDENCE ?? 50);
  const confidence = (rawResult.confidence ?? 0) * 100; // ppu-paddle-ocr pakai skala 0-1

  if (!rawResult.text || confidence < minConfidence) {
    return {
      success: false,
      message: "Confidence terlalu rendah atau tidak ada teks terdeteksi",
      meta: {
        source: "cloud",
        engine: "paddle_ocr_medium",
        processingTimeMs,
      },
      data: null,
      error: {
        code: "LOW_CONFIDENCE_OR_NO_TEXT",
        detail: `Confidence ${confidence.toFixed(1)}% di bawah threshold ${minConfidence}%`,
      },
    };
  }

  return {
    success: true,
    message: "OCR success",
    meta: {
      source: "cloud",
      engine: "paddle_ocr_medium",
      processingTimeMs,
    },
    data: {
      documentType: "GENERIC", // document-type detection belum dibangun, sama seperti on-device
      confidence,
      rawText: rawResult.text,
      fields: null,
    },
    error: null,
  };
}
