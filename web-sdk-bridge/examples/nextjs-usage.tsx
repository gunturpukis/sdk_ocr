"use client"; // WAJIB — hook ini butuh window/DOM, tidak bisa di-render di server

// Contoh pemakaian di Next.js App Router. Untuk production, ganti import di
// bawah dengan nama package final Anda setelah dipublish.
import { useOcrScanner } from "@yourorg/ocr-scanner-react";

export function ScanButton() {
  const { status, progress, result, error, readiness, open } = useOcrScanner({
    // DEV: hasil `flutter run -d chrome --web-port 8080` dari apps/web_host.
    // Harus http:// (bukan https) — localhost tidak kena mixed-content.
    // PROD: https://scan.yourapp.com/scan/ (hosting `flutter build web` di
    // belakang HTTPS — halaman https:// TIDAK BOLEH meng-iframe http://).
    iframeUrl: "http://localhost:8080",
    // DEV: services/ocr-cloud-api di localhost:3000. PROD: rekomendasi
    // pakai route proxy same-origin Next.js (lihat README bagian "Auth")
    // supaya API key tidak pernah keluar dari server.
    proxyBaseUrl: "http://localhost:3000",
    // URL models.json di CDN Anda (SHA256 tiap model tercantum di dalamnya).
    modelManifestUrl: "https://unveiled-work-clang.ngrok-free.dev/models.json",
    // Default: hybrid — on-device dulu (onnxruntime-web sudah diaktifkan di
    // web/index.html host), fallback cloud kalau confidence rendah.
    // Set true untuk selalu cloud (model medium lebih akurat):
    // forceCloud: true,
    // HANYA untuk testing lokal — terlihat di DevTools browser. Di production
    // JANGAN dikirim; pakai proxy server-side yang menyuntikkan Authorization.
    // apiKey: "dev-key-anda",
  });

  return (
    <div>
      <button
        onClick={() => {
          open().catch(() => {
            // Error sudah tersimpan di state `error` hook — ignore di sini
            // supaya tidak jadi unhandled rejection.
          });
        }}
        disabled={status === "scanning"}
      >
        {status === "scanning" ? `Memindai... ${Math.round(progress * 100)}%` : "Scan Dokumen"}
      </button>

      {readiness && <p>Engine: {readiness}</p>}
      {status === "error" && <p style={{ color: "red" }}>{error}</p>}

      {status === "done" && result?.success && (
        <pre>{JSON.stringify(result.data.fields ?? result.data.rawText, null, 2)}</pre>
      )}
    </div>
  );
}

// next.config.js — kalau nanti onnxruntime-web di dalam iframe pakai
// varian WASM threads (lebih cepat), header ini WAJIB ada di domain YANG
// HOST APP INI (bukan domain iframe), supaya SharedArrayBuffer tersedia:
//
// module.exports = {
//   async headers() {
//     return [
//       {
//         source: "/:path*",
//         headers: [
//           { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
//           { key: "Cross-Origin-Embedder-Policy", value: "require-corp" },
//         ],
//       },
//     ];
//   },
// };
