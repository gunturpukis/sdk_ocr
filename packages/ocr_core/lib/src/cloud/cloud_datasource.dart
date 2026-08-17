import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/ocr_result.dart';

class CloudDataSource {
  final String baseUrl;
  final String apiKey;
  final Duration timeout;

  CloudDataSource({
    required this.baseUrl,
    required this.apiKey,
    this.timeout = const Duration(seconds: 20),
  });

  Future<OcrResult> recognize(Uint8List imageBytes) async {
    try {
      // 1. Parsing URI dengan aman (memastikan trailing slash disesuaikan)
      final normalizedBase = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
      final uri = Uri.parse('$normalizedBase/v1/ocr/read');

      final request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..files.add(
          http.MultipartFile.fromBytes('image', imageBytes, filename: 'scan.jpg'),
        );

      final streamedResponse = await request.send().timeout(timeout);
      final response = await http.Response.fromStream(streamedResponse);

      // 2. Evaluasi Response Status Code
      if (response.statusCode != 200) {
        return OcrResult(
          success: false,
          source: OcrSource.cloud,
          confidence: 0,
          rawText: '',
          error: OcrError(
            code: 'CLOUD_HTTP_${response.statusCode}',
            detail: 'Failed with status ${response.statusCode}: ${response.reasonPhrase}',
          ),
        );
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return OcrResult.fromJson(json);
    } on Exception catch (e) {
      return OcrResult(
        success: false,
        source: OcrSource.cloud,
        confidence: 0,
        rawText: '',
        error: OcrError(code: 'NO_CONNECTIVITY', detail: e.toString()),
      );
    }
  }
}