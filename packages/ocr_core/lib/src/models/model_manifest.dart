class ModelEntry {
  final String url;
  final String sha256;
  final int sizeBytes;

  const ModelEntry({
    required this.url,
    required this.sha256,
    required this.sizeBytes,
  });

  factory ModelEntry.fromJson(Map<String, dynamic> json) => ModelEntry(
        url: json['url'] as String,
        sha256: json['sha256'] as String,
        sizeBytes: json['sizeBytes'] as int,
      );
}

class ModelManifest {
  final String version;
  final Map<String, ModelEntry> models; // key: "det" | "rec" | "dict"

  const ModelManifest({required this.version, required this.models});

  factory ModelManifest.fromJson(Map<String, dynamic> json) {
    final rawModels = json['models'] as Map<String, dynamic>;
    return ModelManifest(
      version: json['version'] as String,
      models: rawModels.map(
        (key, value) =>
            MapEntry(key, ModelEntry.fromJson(value as Map<String, dynamic>)),
      ),
    );
  }
}

class ModelPaths {
  final String det;
  final String rec;
  final String dict;

  const ModelPaths({required this.det, required this.rec, required this.dict});
}

class OcrModelException implements Exception {
  final String message;
  const OcrModelException(this.message);

  @override
  String toString() => 'OcrModelException: $message';
}
