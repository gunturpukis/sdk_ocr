import 'local_text_reader.dart';

class LocalTextReaderImpl implements LocalTextReader {
  @override
  Future<String> readAsString(String path) {
    throw UnsupportedError('LocalTextReader tidak didukung di platform ini.');
  }
}
