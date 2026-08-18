
import '../models/ocr_result.dart';
 
class KtpFields {
  final String? nik;
  final String? name;
  final String? birthPlaceDate;
  final String? gender;
  final String? bloodType;
  final String? address;
  final String? rtRw;
  final String? religion;
  final String? maritalStatus;
  final String? occupation;
  final String? nationality;
  final bool nationalityIsGuess; // true kalau hasil fallback misread-recovery, bukan match langsung
  final String? validUntil;
 
  const KtpFields({
    this.nik,
    this.name,
    this.birthPlaceDate,
    this.gender,
    this.bloodType,
    this.address,
    this.rtRw,
    this.religion,
    this.maritalStatus,
    this.occupation,
    this.nationality,
    this.nationalityIsGuess = false,
    this.validUntil,
  });
 
  Map<String, OcrField> toOcrFields() {
    final result = <String, OcrField>{};
    void add(String key, String? value, double confidence) {
      if (value != null && value.isNotEmpty) {
        result[key] = OcrField(value: value, confidence: confidence);
      }
    }
 
    add('nik', nik, 95);
    add('name', name, 55); // heuristik kasar, confidence rendah dengan sengaja
    add('birthPlaceDate', birthPlaceDate, 80);
    add('gender', gender, 95);
    add('bloodType', bloodType, 85);
    add('address', address, 50); // heuristik kasar juga
    add('rtRw', rtRw, 90);
    add('religion', religion, 90);
    add('maritalStatus', maritalStatus, 85);
    add('occupation', occupation, 60);
    add('nationality', nationality, nationalityIsGuess ? 40 : 90); // confidence rendah kalau hasil tebakan
    add('validUntil', validUntil, 85);
 
    return result;
  }
}
 
class KtpParser {
  static const _religions = ['ISLAM', 'KRISTEN', 'KATOLIK', 'HINDU', 'BUDDHA', 'KHONGHUCU'];
 
  static const _maritalStatuses = [
    'BELUM KAWIN', 'BELUMKAWIN',
    'KAWIN',
    'CERAI HIDUP', 'CERAIHIDUP',
    'CERAI MATI', 'CERAIMATI',
  ];
 
  static const _bloodTypes = ['A', 'B', 'AB', 'O'];
 
  static KtpFields parse(String rawText) {
    final normalized = rawText.toUpperCase();
    final lines = normalized.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
 
    final nationalityResult = _extractNationalityWithGuessFlag(normalized);
 
    return KtpFields(
      nik: _extractNik(normalized),
      name: _extractName(lines),
      birthPlaceDate: _extractBirthPlaceDate(normalized),
      gender: _extractGender(normalized),
      bloodType: _extractBloodType(normalized),
      address: _extractAddress(lines),
      rtRw: _extractRtRw(normalized),
      religion: _extractEnum(normalized, _religions),
      maritalStatus: _extractMaritalStatus(normalized),
      occupation: null, // TODO: butuh strategi lebih baik, lihat catatan di bawah
      nationality: nationalityResult?.$1,
      nationalityIsGuess: nationalityResult?.$2 ?? false,
      validUntil: _extractValidUntil(normalized),
    );
  }
 
  static String? _extractNik(String text) {
    final match = RegExp(r'\b\d{16}\b').firstMatch(text);
    return match?.group(0);
  }
 
  static String? _extractGender(String text) {
    if (text.contains('LAKI-LAKI') || text.contains('LAKILAKI')) return 'LAKI-LAKI';
    if (text.contains('PEREMPUAN')) return 'PEREMPUAN';
    return null;
  }
 
  static String? _extractBloodType(String text) {
    final darahIndex = text.indexOf('DARAH');
    if (darahIndex == -1) return null;
 
    final window = text.substring(darahIndex, (darahIndex + 30).clamp(0, text.length));
    for (final type in _bloodTypes) {
      if (RegExp('\\b$type\\b').hasMatch(window)) return type;
    }
    return null; // field kosong di KTP-nya sendiri (umum terjadi), bukan gagal ekstrak
  }
 
  static String? _extractRtRw(String text) {
    final match = RegExp(r'\b\d{3}\s*/\s*\d{3}\b').firstMatch(text);
    return match?.group(0)?.replaceAll(RegExp(r'\s'), '');
  }
 
  static String? _extractEnum(String text, List<String> candidates) {
    for (final candidate in candidates) {
      if (text.contains(candidate)) return candidate;
    }
    return null;
  }
 
  static String? _extractMaritalStatus(String text) {
    for (final status in _maritalStatuses) {
      if (text.contains(status)) {
        // normalisasi varian tanpa-spasi ke bentuk standar
        return status.replaceAllMapped(
          RegExp(r'([A-Z])([A-Z]+)'),
          (m) => m.group(0)!,
        );
      }
    }
    return null;
  }
 
  static (String, bool)? _extractNationalityWithGuessFlag(String text) {
    if (RegExp(r'\bWNI\b').hasMatch(text)) return ('WNI', false);
    if (RegExp(r'\bWNA\b').hasMatch(text)) return ('WNA', false);
 
    final hasNationalityContext = text.contains('KEWARGANEGARAAN');
    final looksLikeMisreadWni = RegExp(r'\bW[A-Z]I\b').hasMatch(text);
    if (hasNationalityContext && looksLikeMisreadWni) return ('WNI', true); // tebakan
 
    return null;
  }
 
  static String? _extractValidUntil(String text) {
    if (text.contains('SEUMUR HIDUP') || text.contains('SEUMURHIDUP')) {
      return 'SEUMUR HIDUP';
    }
    final matches = RegExp(r'\b\d{2}-\d{2}-\d{4}\b').allMatches(text).toList();
    return matches.isEmpty ? null : matches.last.group(0);
  }
 
  static String? _extractBirthPlaceDate(String text) {
    final match = RegExp(r'([A-Z]+)?,?\s*(\d{2}-\d{2}-\d{4})').firstMatch(text);
    return match?.group(0);
  }
  static String? _extractName(List<String> lines) {
    final knownWords = {
      'NIK', 'NAMA', 'TEMPAT', 'TGL', 'LAHIR', 'JENIS', 'KELAMIN',
      'GOL', 'DARAH', 'ALAMAT', 'AGAMA', 'STATUS', 'PERKAWINAN',
      'PEKERJAAN', 'KEWARGANEGARAAN', 'BERLAKU', 'HINGGA', 'WNI', 'WNA',
      'LAKI-LAKI', 'PEREMPUAN', 'ISLAM', 'KRISTEN', 'KATOLIK', 'HINDU',
      'BUDDHA', 'KHONGHUCU', 'KAWIN', 'BELUM', 'CERAI', 'HIDUP', 'MATI',
      'SEUMUR', 'RT', 'RW', 'KEL', 'DESA', 'KECAMATAN', 'PROVINSI', 'KOTA',
    };
 
    for (var i = 2; i < lines.length; i++) {
      final line = lines[i];
      final isAllLetters = RegExp(r'^[A-Z\s]+$').hasMatch(line);
      if (!isAllLetters || line.length < 5) continue;
 
      final words = line.split(RegExp(r'\s+'));
      final isKnownLabel = words.any(knownWords.contains);
      if (isKnownLabel) continue;
 
      return line; // kandidat pertama yang lolos filter
    }
    return null;
  }
 
  static String? _extractAddress(List<String> lines) => null;
}
 