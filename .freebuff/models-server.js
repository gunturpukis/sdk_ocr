// Throwaway local static server untuk smoke test: serve models-cache dengan
// CORS terbuka + handle OPTIONS preflight (fetch Flutter mengirim custom
// header ngrok-skip-browser-warning yang memicu preflight).
const http = require("http");
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..", "services", "ocr-cloud-api", "models-cache");
const types = { ".json": "application/json", ".txt": "text/plain", ".ort": "application/octet-stream", ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm" };

http
  .createServer((req, res) => {
    res.setHeader("Access-Control-Allow-Origin", "*");
    if (req.method === "OPTIONS") {
      res.writeHead(204, {
        "Access-Control-Allow-Methods": "GET, PUT, OPTIONS",
        "Access-Control-Allow-Headers": "*",
        "Access-Control-Max-Age": "86400",
      });
      return res.end();
    }
    // PUT: simpan body ke file di bench/ saja (test harness upload).
  if (req.method === "PUT") {
    const m = req.url.match(/^\/bench\/([A-Za-z0-9._-]+)$/);
    if (!m) {
      res.writeHead(403);
      return res.end("PUT hanya diizinkan ke /bench/<nama>");
    }
    const chunks = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size > 15 * 1024 * 1024) { req.destroy(); }
      else chunks.push(c);
    });
    req.on("end", () => {
      const out = path.join(root, "bench", m[1]);
      require("fs").writeFile(out, Buffer.concat(chunks), (err) => {
        res.writeHead(err ? 500 : 201, { "Access-Control-Allow-Origin": "*" });
        res.end(err ? "write failed" : "saved " + m[1]);
      });
    });
    return;
  }
  const rel = path.normalize(decodeURIComponent(req.url.split("?")[0])).replace(/^([\\/])+/, "");
    const file = path.join(root, rel);
    if (!file.startsWith(root)) {
      res.writeHead(403);
      return res.end();
    }
    fs.readFile(file, (err, buf) => {
      if (err) {
        res.writeHead(404);
        return res.end("not found");
      }
      res.writeHead(200, {
        "Content-Type": types[path.extname(file)] || "application/octet-stream",
        "Content-Length": buf.length,
      });
      res.end(buf);
    });
  })
  .listen(9090, () => console.log("models server on http://localhost:9090"));
