
import 'inference_session.dart';
 
class RecognizedLine {
  final String text;
  final double confidence;
 
  const RecognizedLine({required this.text, required this.confidence});
}
 
/// CTC (Connectionist Temporal Classification) greedy decode — ambil
/// karakter dengan probabilitas tertinggi tiap time step, hilangkan
/// duplikat berturut-turut dan blank token, lalu map index ke karakter
/// lewat dictionary.
///
/// CATATAN: sempat dicoba heuristik sisip-spasi dari panjang blank run
/// di antara karakter (lihat histori debugging), tapi hasilnya net
/// negatif — gap blank run di model ini ternyata tidak berkorelasi
/// dengan batas kata, malah memotong kata yang sudah benar jadi
/// terpisah acak. Dictionary/model "tiny" ini sepertinya memang tidak
/// pernah dilatih untuk merepresentasikan spasi dalam satu baris teks.
/// Spasi antar kata untuk field terstruktur (KTP, dst) sebaiknya
/// direkonstruksi di layer parsing dokumen (regex per pola field),
/// bukan dipaksakan di level decode CTC generik ini.
class CtcDecoder {
  static const _blankIndex = 0; // konvensi PaddleOCR: index 0 = blank/CTC
 
  static RecognizedLine decode(TensorOutput output, List<String> dict) {
    final shape = output.shape; // [1, T, numClasses]
    final timeSteps = shape[1];
    final numClasses = shape[2];
    final data = output.data;
 
    final chars = <String>[];
    final confidences = <double>[];
    var lastIndex = -1;
 
    for (var t = 0; t < timeSteps; t++) {
      var bestIndex = 0;
      var bestProb = double.negativeInfinity;
 
      for (var c = 0; c < numClasses; c++) {
        final prob = data[t * numClasses + c];
        if (prob > bestProb) {
          bestProb = prob;
          bestIndex = c;
        }
      }
 
      final isDuplicate = bestIndex == lastIndex;
      lastIndex = bestIndex;
 
      if (bestIndex == _blankIndex || isDuplicate) continue;
 
      final charIndex = bestIndex - 1; // geser karena index 0 dipakai blank
      if (charIndex >= 0 && charIndex < dict.length) {
        chars.add(dict[charIndex]);
        confidences.add(bestProb);
      }
    }
 
    final text = chars.join();
    final avgConfidence =
        confidences.isEmpty ? 0.0 : confidences.reduce((a, b) => a + b) / confidences.length;
 
    return RecognizedLine(text: text, confidence: avgConfidence);
  }
}