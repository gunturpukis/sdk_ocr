"use client"; // WAJIB — hook ini butuh window/DOM, tidak bisa di-render di server

import { useOcrScanner } from "@yourorg/ocr-scanner-react"; // nama publish npm package Anda

export function ScanKtpButton() {
  const { status, progress, result, error, open } = useOcrScanner({
    iframeUrl: "https://scan.yourapp.com/v1/", // hasil `flutter build web` dari apps/web_host
    proxyBaseUrl: "https://yourapp.com/api/ocr-proxy", // backend proxy Anda, BUKAN cloud OCR provider langsung
    modelManifestUrl: "https://cdn.yourapp.com/models/models.json",
  });

  return (
    <div>
      <button onClick={() => open()} disabled={status === "scanning"}>
        {status === "scanning" ? `Memindai... ${Math.round(progress * 100)}%` : "Scan KTP"}
      </button>

      {status === "error" && <p style={{ color: "red" }}>{error}</p>}

      {status === "done" && result?.success && (
        <pre>{JSON.stringify(result.data.fields, null, 2)}</pre>
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
