export 'local_text_reader_stub.dart'
    if (dart.library.io) 'local_text_reader_mobile.dart'
    if (dart.library.html) 'local_text_reader_web.dart';

/// Baca isi file teks lokal. Cuma dipakai jalur mobile (Web selalu
/// fetch dictionary lewat URL http, tidak pernah lewat sini) — tapi
/// tetap perlu conditional export supaya `dart:io` tidak ikut
/// ter-import ke build Web sama sekali (dart:io bikin build Web gagal
/// compile kalau di-import langsung, bukan cuma error saat runtime).
abstract class LocalTextReader {
  Future<String> readAsString(String path);
}
