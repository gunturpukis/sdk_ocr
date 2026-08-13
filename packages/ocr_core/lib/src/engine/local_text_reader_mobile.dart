import 'dart:io';

import 'local_text_reader.dart';

class LocalTextReaderImpl implements LocalTextReader {
  @override
  Future<String> readAsString(String path) => File(path).readAsString();
}
