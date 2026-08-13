import 'local_text_reader.dart';

class LocalTextReaderImpl implements LocalTextReader {
  @override
  Future<String> readAsString(String path) {
    // Di Web, DictLoader selalu pakai jalur http (ModelPaths berisi URL,
    // bukan path lokal), jadi cabang ini seharusnya tidak pernah kepanggil.
    throw UnsupportedError(
      'Web selalu baca dictionary lewat URL http, bukan file lokal.',
    );
  }
}
