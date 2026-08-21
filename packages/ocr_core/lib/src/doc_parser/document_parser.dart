import '../models/ocr_result.dart';

class KtpFields {
  final String? nik;
  final String? name;
  final String? birthPlaceDate;
  final String? gender;
  final String? bloodType;
  final String? address;
  final String? rtRw;
  final String? village; // Kelurahan/Desa
  final String? district; // Kecamatan
  final String? religion;
  final String? maritalStatus;
  final String? occupation;
  final String? nationality;
  final bool nationalityIsGuess; // true kalau hasil fallback misread-recovery, bukan match langsung
  final String? validUntil;

  /// Baris asal tiap field yang berhasil diekstrak (0-based di
  /// `rawText.split('\n')`), dipakai oleh [toOcrFields] untuk mengisi
  /// `OcrField.line`. Key sama dengan key di [toOcrFields].
  final Map<String, int> _lines;

  const KtpFields({
    this.nik,
    this.name,
    this.birthPlaceDate,
    this.gender,
    this.bloodType,
    this.address,
    this.rtRw,
    this.village,
    this.district,
    this.religion,
    this.maritalStatus,
    this.occupation,
    this.nationality,
    this.nationalityIsGuess = false,
    this.validUntil,
    Map<String, int> lines = const {},
  }) : _lines = lines;

  /// Konversi ke `Map<String, OcrField>` — inilah bentuk JSON key-value
  /// per baris yang dikonsumsi `OcrResult.fields`. Tiap field membawa
  /// `value`, `confidence`, dan `line` (kalau diketahui), sehingga
  /// consumer bisa trace balik ke baris OCR mentah untuk keperluan
  /// debugging/QA tanpa perlu parsing ulang `rawText`.
  Map<String, OcrField> toOcrFields() {
    final result = <String, OcrField>{};
    void add(String key, String? value, double confidence) {
      if (value != null && value.isNotEmpty) {
        result[key] = OcrField(value: value, confidence: confidence, line: _lines[key]);
      }
    }

    add('nik', nik, 95);
    add('name', name, 70); // sekarang label-anchored ("NAMA ..."), bukan tebakan baris kosong lagi
    add('birthPlaceDate', birthPlaceDate, 80);
    add('gender', gender, 95);
    add('bloodType', bloodType, 85);
    add('address', address, 65); // multi-baris, confidence sedang karena boundary antar-baris bisa meleset
    add('rtRw', rtRw, 90);
    add('village', village, 75);
    add('district', district, 75);
    add('religion', religion, 90);
    add('maritalStatus', maritalStatus, 85);
    add('occupation', occupation, 70);
    add('nationality', nationality, nationalityIsGuess ? 40 : 90); // confidence rendah kalau hasil tebakan
    add('validUntil', validUntil, 85);

    return result;
  }

  /// Shortcut langsung ke JSON key-value (`{fieldKey: {value, confidence, line}}`).
  Map<String, dynamic> toJson() => toOcrFields().map((k, v) => MapEntry(k, v.toJson()));
}

class KtpParser {
  static const _religions = ['ISLAM', 'KRISTEN', 'KATOLIK', 'HINDU', 'BUDDHA', 'KHONGHUCU'];

  static const _maritalStatuses = [
    'BELUM KAWIN',
    'KAWIN',
    'CERAI HIDUP',
    'CERAI MATI',
  ];

  static const _bloodTypes = ['A', 'B', 'AB', 'O'];

  // Urutan label sesuai layout baku KTP — dipakai untuk menentukan batas
  // akhir field multi-baris (mis. alamat berhenti begitu baris berikutnya
  // cocok salah satu label ini).
  // Sengaja pakai \b (word boundary), BUKAN ^ (anchor awal baris), supaya
  // label kedua yang muncul di tengah baris (mis. "GOL. DARAH" setelah
  // "JENIS KELAMIN ..." pada baris yang sama) tetap terdeteksi.
  static final Map<String, RegExp> _labels = {
    'nik': RegExp(r'\bNIK\s*[:.\-]?\s*'),
    'name': RegExp(r'\bNAMA\s*[:.\-]?\s*'),
    'birthPlaceDate': RegExp(r'\bTEMPAT\W{0,3}TGL\W{0,3}LAHIR\s*[:.\-]?\s*'),
    'gender': RegExp(r'\bJENIS\s*KELAMIN\s*[:.\-]?\s*'),
    'bloodType': RegExp(r'\bGOL(?:ONGAN)?\.?\s*DARAH\s*[:.\-]?\s*'),
    'address': RegExp(r'\bALAMAT\s*[:.\-]?\s*'),
    'rtRw': RegExp(r'\bRT\s*/?\s*RW\s*[:.\-]?\s*'),
    'village': RegExp(r'\bKEL(?:URAHAN)?\s*/?\s*DESA\s*[:.\-]?\s*'),
    'district': RegExp(r'\bKECAMATAN\s*[:.\-]?\s*'),
    'religion': RegExp(r'\bAGAMA\s*[:.\-]?\s*'),
    'maritalStatus': RegExp(r'\bSTATUS\s*PERKAWINAN\s*[:.\-]?\s*'),
    'occupation': RegExp(r'\bPEKERJAAN\s*[:.\-]?\s*'),
    'nationality': RegExp(r'\bKEWARGANEGARAAN\s*[:.\-]?\s*'),
    'validUntil': RegExp(r'\bBERLAKU\s*HINGGA\s*[:.\-]?\s*'),
  };

  // Urutan field mengikuti urutan cetak fisik KTP — dipakai untuk tahu
  // "label berikutnya" saat menggabungkan value multi-baris (alamat).
  static const _labelOrder = [
    'nik', 'name', 'birthPlaceDate', 'gender', 'bloodType', 'address',
    'rtRw', 'village', 'district', 'religion', 'maritalStatus',
    'occupation', 'nationality', 'validUntil',
  ];

  static KtpFields parse(String rawText) {
    final rawLines = rawText.split('\n');
    final lines = rawLines.map((l) => l.trim().toUpperCase()).toList();

    // Tahap 1: cari baris mana yang match tiap label, dan sisa teks di
    // baris yang sama (kalau ada) sebagai kandidat value.
    //
    // PENTING: satu baris KTP sering menggabungkan DUA label sekaligus,
    // mis. "JENIS KELAMIN LAKI-LAKI GOL. DARAH O" — karena itu di sini
    // kita kumpulkan SEMUA label yang match di baris tsb (bukan cuma
    // yang pertama), urutkan berdasarkan posisi, lalu potong value tiap
    // label sampai posisi label berikutnya di baris yang sama.
    final labelLineIndex = <String, int>{};
    final sameLineValue = <String, String>{};

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty) continue;

      // Record positional (String, int, int) = (key, start, end).
      final matchesInLine = <(String, int, int)>[];
      for (final key in _labelOrder) {
        if (labelLineIndex.containsKey(key)) continue; // tiap field cuma diambil match pertama di dokumen
        final match = _labels[key]!.firstMatch(line);
        if (match != null) matchesInLine.add((key, match.start, match.end));
      }
      if (matchesInLine.isEmpty) continue;

      matchesInLine.sort((a, b) => a.$2.compareTo(b.$2));
      for (var m = 0; m < matchesInLine.length; m++) {
        final (key, _, end) = matchesInLine[m];
        final valueEnd = m + 1 < matchesInLine.length ? matchesInLine[m + 1].$2 : line.length;
        labelLineIndex[key] = i;
        final remainder = line.substring(end, valueEnd).trim();
        if (remainder.isNotEmpty) sameLineValue[key] = remainder;
      }
    }

    final lineMeta = <String, int>{};
    String? valueOf(String key, {bool allowNextLine = true}) {
      if (sameLineValue.containsKey(key)) {
        lineMeta[key] = labelLineIndex[key]!;
        return sameLineValue[key];
      }
      if (!allowNextLine) return null;

      final labelIdx = labelLineIndex[key];
      if (labelIdx == null) return null;

      // OCR kadang taruh value di baris setelah label (bukan di baris
      // yang sama) — ambil baris berikutnya asal bukan label lain.
      for (var j = labelIdx + 1; j < lines.length; j++) {
        if (lines[j].isEmpty) continue;
        if (_matchesAnyLabel(lines[j])) return null;
        lineMeta[key] = j;
        return lines[j];
      }
      return null;
    }

    // Alamat sering membentang beberapa baris (nama jalan lalu lanjutan) —
    // gabungkan semua baris antara label ALAMAT dan label berikutnya yang
    // dikenali (RT/RW, KEL/DESA, KECAMATAN, dst).
    String? address = sameLineValue['address'];
    final addressLabelIdx = labelLineIndex['address'];
    if (addressLabelIdx != null) {
      final nextLabelIdx = _nextLabelLineAfter(addressLabelIdx, labelLineIndex);
      final endIdx = nextLabelIdx ?? lines.length;
      final extraLines = <String>[];
      for (var j = addressLabelIdx + 1; j < endIdx; j++) {
        if (lines[j].isNotEmpty) extraLines.add(lines[j]);
      }
      if (extraLines.isNotEmpty) {
        address = [if (address != null && address.isNotEmpty) address, ...extraLines].join(' ');
      }
      if (address != null && address.isNotEmpty) lineMeta['address'] = addressLabelIdx;
    }

    final nationalityResult = _extractNationalityWithGuessFlag(
      valueOf('nationality') ?? '',
      lines.join('\n'),
    );

    final fields = KtpFields(
      nik: _extractNik(valueOf('nik', allowNextLine: false)) ?? _extractNik(lines.join('\n')),
      name: _cleanName(valueOf('name')),
      birthPlaceDate: _normalizeBirthPlaceDate(valueOf('birthPlaceDate')),
      gender: _normalizeGender(valueOf('gender')),
      bloodType: _extractBloodTypeFromValue(valueOf('bloodType')),
      address: address?.trim().isEmpty == true ? null : address?.trim(),
      rtRw: _normalizeRtRw(valueOf('rtRw')),
      village: valueOf('village'),
      district: valueOf('district'),
      religion: _extractEnum(valueOf('religion') ?? '', _religions) ?? _extractEnum(lines.join('\n'), _religions),
      maritalStatus: _extractEnum(valueOf('maritalStatus') ?? '', _maritalStatuses),
      occupation: valueOf('occupation'),
      nationality: nationalityResult?.$1,
      nationalityIsGuess: nationalityResult?.$2 ?? false,
      validUntil: _normalizeValidUntil(valueOf('validUntil')),
      lines: lineMeta,
    );

    return fields;
  }

  /// Shortcut: langsung dapat JSON key-value (per baris) dari raw OCR text.
  static Map<String, dynamic> parseToJson(String rawText) => parse(rawText).toJson();

  static bool _matchesAnyLabel(String line) =>
      _labels.values.any((pattern) => pattern.hasMatch(line));

  static int? _nextLabelLineAfter(int afterIdx, Map<String, int> labelLineIndex) {
    int? next;
    for (final entry in labelLineIndex.entries) {
      if (entry.value <= afterIdx) continue;
      if (next == null || entry.value < next) next = entry.value;
    }
    return next;
  }

  static String? _extractNik(String? text) {
    if (text == null) return null;
    final match = RegExp(r'\b\d{16}\b').firstMatch(text);
    return match?.group(0);
  }

  static String? _cleanName(String? value) {
    if (value == null) return null;
    // buang sisa noise umum: titik dua ganda, karakter non-huruf di ujung
    final cleaned = value.replaceAll(RegExp(r'^[:.\-\s]+|[:.\-\s]+$'), '');
    return cleaned.isEmpty ? null : cleaned;
  }

  static String? _normalizeGender(String? value) {
    if (value == null) return null;
    if (value.contains('LAKI')) return 'LAKI-LAKI';
    if (value.contains('PEREMPUAN')) return 'PEREMPUAN';
    return null;
  }

  static String? _extractBloodTypeFromValue(String? value) {
    if (value == null) return null;
    for (final type in _bloodTypes) {
      if (RegExp('^$type\\b').hasMatch(value)) return type;
    }
    return null; // field kosong di KTP-nya sendiri (umum terjadi), bukan gagal ekstrak
  }

  static String? _normalizeRtRw(String? value) {
    if (value == null) return null;
    final match = RegExp(r'\d{2,3}\s*/\s*\d{2,3}').firstMatch(value);
    return match?.group(0)?.replaceAll(RegExp(r'\s'), '');
  }

  static String? _extractEnum(String text, List<String> candidates) {
    for (final candidate in candidates) {
      if (text.contains(candidate)) return candidate;
    }
    return null;
  }

  static (String, bool)? _extractNationalityWithGuessFlag(String labelValue, String fullText) {
    if (RegExp(r'\bWNI\b').hasMatch(labelValue)) return ('WNI', false);
    if (RegExp(r'\bWNA\b').hasMatch(labelValue)) return ('WNA', false);
    if (RegExp(r'\bWNI\b').hasMatch(fullText)) return ('WNI', false);
    if (RegExp(r'\bWNA\b').hasMatch(fullText)) return ('WNA', false);

    final hasNationalityContext = fullText.contains('KEWARGANEGARAAN');
    final looksLikeMisreadWni = RegExp(r'\bW[A-Z]I\b').hasMatch(fullText);
    if (hasNationalityContext && looksLikeMisreadWni) return ('WNI', true); // tebakan

    return null;
  }

  static String? _normalizeValidUntil(String? value) {
    if (value == null) return null;
    if (value.contains('SEUMUR HIDUP') || value.contains('SEUMURHIDUP')) {
      return 'SEUMUR HIDUP';
    }
    final match = RegExp(r'\d{2}-\d{2}-\d{4}').firstMatch(value);
    return match?.group(0);
  }

  static String? _normalizeBirthPlaceDate(String? value) {
    if (value == null) return null;
    final match = RegExp(r'([A-Z]+)?,?\s*(\d{2}-\d{2}-\d{4})').firstMatch(value);
    return match?.group(0) ?? value;
  }
}
