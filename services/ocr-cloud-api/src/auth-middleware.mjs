export function authMiddleware(req, res, next) {
  const authHeader = req.headers.authorization ?? "";
  const providedKey = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : null;

  if (!providedKey || providedKey !== process.env.OCR_API_KEY) {
    // Kontrak error sama persis seperti unified response yang sudah
    // disepakati di ocr_core — supaya CloudDataSource di Flutter bisa
    // parse error ini sama seperti error lainnya, bukan cuma HTTP 401 polos.
    return res.status(401).json({
      success: false,
      message: "Unauthorized",
      meta: { source: "cloud" },
      data: null,
      error: { code: "INVALID_API_KEY", detail: "API key tidak valid atau tidak disertakan" },
    });
  }

  next();
}
