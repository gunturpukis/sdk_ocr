import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_core/src/doc_parser/document_parser.dart';

void main() {
  group('KtpParser.parse', () {
    // Simulasi rawText hasil OCR dari OcrEngine — tiap baris terpisah '\n'
    // seperti yang dihasilkan PaddleOcrEngine.recognize() (lines.join('\n')).
    const sampleRawText = '''PROVINSI JAWA BARAT
KOTA BANDUNG
NIK 3273010101990001
NAMA BUDI SETIAWAN
TEMPAT/TGL LAHIR BANDUNG, 01-01-1999
JENIS KELAMIN LAKI-LAKI GOL. DARAH O
ALAMAT JL. MERDEKA NO. 10
RT/RW 003/004
KEL/DESA CIHAPIT
KECAMATAN BANDUNG WETAN
AGAMA ISLAM
STATUS PERKAWINAN BELUM KAWIN
PEKERJAAN KARYAWAN SWASTA
KEWARGANEGARAAN WNI
BERLAKU HINGGA SEUMUR HIDUP''';

    test('ekstrak semua field utama dengan benar', () {
      final fields = KtpParser.parse(sampleRawText);

      expect(fields.nik, '3273010101990001');
      expect(fields.name, 'BUDI SETIAWAN');
      expect(fields.gender, 'LAKI-LAKI');
      expect(fields.address, 'JL. MERDEKA NO. 10');
      expect(fields.rtRw, '003/004');
      expect(fields.village, 'CIHAPIT');
      expect(fields.district, 'BANDUNG WETAN');
      expect(fields.religion, 'ISLAM');
      expect(fields.maritalStatus, 'BELUM KAWIN');
      expect(fields.occupation, 'KARYAWAN SWASTA');
      expect(fields.nationality, 'WNI');
      expect(fields.nationalityIsGuess, isFalse);
      expect(fields.validUntil, 'SEUMUR HIDUP');
    });

    test('bloodType terbaca walau satu baris dengan jenis kelamin', () {
      final fields = KtpParser.parse(sampleRawText);
      expect(fields.bloodType, 'O');
    });

    test('toJson() menghasilkan key-value JSON dengan info baris asal', () {
      final json = KtpParser.parseToJson(sampleRawText);

      expect(json['nik']['value'], '3273010101990001');
      expect(json['nik']['confidence'], 95);
      expect(
          json['nik']['line'], 2); // baris index 2 (0-based) di sampleRawText

      expect(json['name']['value'], 'BUDI SETIAWAN');
      expect(json['address']['value'], 'JL. MERDEKA NO. 10');
    });

    test('alamat multi-baris tergabung sampai sebelum label RT/RW', () {
      const multiLineAddress = '''NIK 3273010101990001
NAMA BUDI SETIAWAN
ALAMAT
JL. MERDEKA NO. 10
BLOK C
RT/RW 003/004''';

      final fields = KtpParser.parse(multiLineAddress);
      expect(fields.address, 'JL. MERDEKA NO. 10 BLOK C');
    });

    test('field kosong di KTP (golongan darah kosong) tidak dianggap gagal',
        () {
      const noBloodType = '''NIK 3273010101990001
NAMA BUDI SETIAWAN
JENIS KELAMIN LAKI-LAKI
GOL. DARAH
ALAMAT JL. MERDEKA''';

      final fields = KtpParser.parse(noBloodType);
      expect(fields.bloodType, isNull);
      expect(fields.name, 'BUDI SETIAWAN'); // field lain tetap kebaca
    });

    test('nationality hasil tebakan (misread) ditandai nationalityIsGuess=true',
        () {
      const misread = '''NIK 3273010101990001
KEWARGANEGARAAN WGI''';

      final fields = KtpParser.parse(misread);
      expect(fields.nationality, 'WNI');
      expect(fields.nationalityIsGuess, isTrue);
    });

    test('rawText kosong tidak melempar exception, semua field null', () {
      final fields = KtpParser.parse('');
      expect(fields.nik, isNull);
      expect(fields.toOcrFields(), isEmpty);
    });

    test('rawText tanpa satupun label dikenali tidak melempar exception', () {
      final fields = KtpParser.parse('teks acak tanpa label ktp sama sekali');
      expect(fields.nik, isNull);
      expect(fields.name, isNull);
    });
  });
}
