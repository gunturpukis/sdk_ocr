import "dotenv/config";
import express from "express";
import multer from "multer";
import cors from "cors";
import { authMiddleware } from "./auth-middleware.mjs";
import { getOcrService, toUnifiedResponse, bufferToCanvas } from "./ocr-service.mjs";

const app = express();

// Browser (beda dari curl/mobile app) wajib lolos CORS preflight dulu
// sebelum POST bisa jalan — terutama karena kita pakai header custom
// (Authorization).
//
// PENTING: request ke endpoint ini datang dari DOKUMEN iframe (domain
// tempat `apps/web_host` di-hosting), BUKAN dari halaman React/Next.js
// yang meng-embed-nya. Jadi origin yang di-whitelist di sini adalah
// domain hosting Flutter web host itu.
//
// Konfigurasi via env CORS_ALLOWED_ORIGINS (comma-separated, origin exact
// tanpa trailing slash), contoh:
//   CORS_ALLOWED_ORIGINS=https://scan.yourapp.com,https://host.yourapp.com
// Origin http://localhost:<port> / http://127.0.0.1:<port> otomatis
// diizinkan untuk dev (kecuali NODE_ENV=production).
const envOrigins = (process.env.CORS_ALLOWED_ORIGINS ?? "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);
const allowLocalhost = process.env.NODE_ENV !== "production";

app.use(
  cors({
    origin: [
      ...(allowLocalhost
        ? [/^http:\/\/localhost:\d+$/, /^http:\/\/127\.0\.0\.1:\d+$/]
        : []),
      ...envOrigins,
    ],
    methods: ["POST"],
    allowedHeaders: ["Authorization", "Content-Type"],
  }),
);

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 10 * 1024 * 1024 }, // 10MB — cukup longgar untuk foto dokumen, cegah abuse
});

// Rate limiting sederhana per-IP, in-memory. Untuk production skala
// besar, ganti dengan solusi proper (redis-based, dsb) — ini cukup
// untuk MVP/testing.
const requestCounts = new Map();
const RATE_LIMIT = 30; // request per menit per IP
const RATE_WINDOW_MS = 60_000;

function rateLimitMiddleware(req, res, next) {
  const ip = req.ip;
  const now = Date.now();
  const record = requestCounts.get(ip) ?? { count: 0, windowStart: now };

  if (now - record.windowStart > RATE_WINDOW_MS) {
    record.count = 0;
    record.windowStart = now;
  }

  record.count++;
  requestCounts.set(ip, record);

  if (record.count > RATE_LIMIT) {
    return res.status(429).json({
      success: false,
      message: "Too many requests",
      meta: { source: "cloud" },
      data: null,
      error: { code: "RATE_LIMITED", detail: `Maksimum ${RATE_LIMIT} request per menit` },
    });
  }

  next();
}

app.get("/health", (req, res) => res.json({ status: "ok" }));

app.post(
  "/v1/ocr/read",
  authMiddleware,
  rateLimitMiddleware,
  upload.single("image"),
  async (req, res) => {
    if (!req.file) {
      return res.status(400).json({
        success: false,
        message: "Bad request",
        meta: { source: "cloud" },
        data: null,
        error: { code: "MISSING_IMAGE", detail: 'Field "image" wajib disertakan (multipart/form-data)' },
      });
    }

    try {
      const service = await getOcrService();
      const start = Date.now();

      const canvasImage = await bufferToCanvas(req.file.buffer);
      const result = await service.recognize(canvasImage);
      const processingTimeMs = Date.now() - start;

      const unified = toUnifiedResponse(result, processingTimeMs);
      const statusCode = unified.success ? 200 : 200; // tetap 200 — error OCR itu bagian dari response normal, bukan HTTP error

      res.status(statusCode).json(unified);
    } catch (err) {
      console.error("[ocr] Gagal proses:", err);
      res.status(500).json({
        success: false,
        message: "Internal server error",
        meta: { source: "cloud" },
        data: null,
        error: { code: "PROCESSING_FAILED", detail: String(err?.message ?? err) },
      });
    }
  },
);

const PORT = process.env.PORT ?? 3000;

// Load model saat startup (bukan nunggu request pertama) — supaya
// request pertama dari user tidak kena delay loading model.
getOcrService()
  .then(() => {
    app.listen(PORT, () => {
      console.log(`[server] Cloud OCR API jalan di http://localhost:${PORT}`);
    });
  })
  .catch((err) => {
    console.error("[server] GAGAL start — model tidak bisa dimuat:", err);
    process.exit(1);
  });
