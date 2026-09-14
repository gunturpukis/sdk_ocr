// Throwaway local static server untuk smoke test: serve models-cache dengan
// CORS terbuka + handle OPTIONS preflight (fetch Flutter mengirim custom
// header ngrok-skip-browser-warning yang memicu preflight).
const http = require("http");
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..", "services", "ocr-cloud-api", "models-cache");
const types = { ".json": "application/json", ".txt": "text/plain", ".ort": "application/octet-stream" };

http
  .createServer((req, res) => {
    res.setHeader("Access-Control-Allow-Origin", "*");
    if (req.method === "OPTIONS") {
      res.writeHead(204, {
        "Access-Control-Allow-Methods": "GET, OPTIONS",
        "Access-Control-Allow-Headers": "*",
        "Access-Control-Max-Age": "86400",
      });
      return res.end();
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
