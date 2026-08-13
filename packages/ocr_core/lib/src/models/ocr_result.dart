enum OcrSource { onDevice, cloud }

enum OcrDocumentType { generic, idCard, passport, driverLicense }

class OcrField {
  final String value;
  final double confidence;

  const OcrField({required this.value, required this.confidence});

  factory OcrField.fromJson(Map<String, dynamic> json) => OcrField(
        value: json['value'] as String,
        confidence: (json['confidence'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {'value': value, 'confidence': confidence};
}

class OcrError {
  final String code;
  final String detail;

  const OcrError({required this.code, required this.detail});

  factory OcrError.fromJson(Map<String, dynamic> json) => OcrError(
        code: json['code'] as String,
        detail: json['detail'] as String,
      );

  Map<String, dynamic> toJson() => {'code': code, 'detail': detail};
}

class OcrBoundingBox {
  final String? field;
  final double x;
  final double y;
  final double width;
  final double height;

  const OcrBoundingBox({
    this.field,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
}

/// Kontrak response unified — dipakai baik oleh hasil on-device (PaddleOCR)
/// maupun cloud fallback. Consumer SDK tidak perlu tahu sumbernya.
class OcrResult {
  final bool success;
  final OcrSource source;
  final double confidence; // skala 0-100, dinormalisasi lintas engine
  final String rawText;
  final OcrDocumentType documentType;
  final Map<String, OcrField>? fields;
  final List<OcrBoundingBox>? boundingBoxes;
  final OcrError? error;
  final int? processingTimeMs;

  const OcrResult({
    required this.success,
    required this.source,
    required this.confidence,
    required this.rawText,
    this.documentType = OcrDocumentType.generic,
    this.fields,
    this.boundingBoxes,
    this.error,
    this.processingTimeMs,
  });

  factory OcrResult.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>?;
    return OcrResult(
      success: json['success'] as bool,
      source: _sourceFromString(json['meta']?['source'] as String?),
      confidence: (data?['confidence'] as num?)?.toDouble() ?? 0,
      rawText: data?['rawText'] as String? ?? '',
      documentType: _documentTypeFromString(data?['documentType'] as String?),
      fields: (data?['fields'] as Map<String, dynamic>?)?.map(
        (k, v) => MapEntry(k, OcrField.fromJson(v as Map<String, dynamic>)),
      ),
      error: json['error'] != null
          ? OcrError.fromJson(json['error'] as Map<String, dynamic>)
          : null,
      processingTimeMs: json['meta']?['processingTimeMs'] as int?,
    );
  }

  static OcrSource _sourceFromString(String? value) =>
      value == 'cloud' ? OcrSource.cloud : OcrSource.onDevice;

  static OcrDocumentType _documentTypeFromString(String? value) {
    switch (value) {
      case 'ID_CARD':
        return OcrDocumentType.idCard;
      case 'PASSPORT':
        return OcrDocumentType.passport;
      case 'DRIVER_LICENSE':
        return OcrDocumentType.driverLicense;
      default:
        return OcrDocumentType.generic;
    }
  }
}
