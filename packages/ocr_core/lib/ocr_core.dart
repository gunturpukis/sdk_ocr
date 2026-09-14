library ocr_core;

export 'src/models/ocr_result.dart';
export 'src/ocr_client.dart';
export 'src/ocr_repository.dart' show CloudFirstPolicy; // kebijakan routing hybrid
export 'src/engine/ocr_engine.dart' show OcrEngine; // dibutuhkan kalau consumer mau inject mock/custom engine untuk testing
export 'src/doc_parser/document_parser.dart';