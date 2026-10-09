/// Build 176 Step 7 — quiet-audio knobs, OFF unless set at build time.
///
/// b175 evidence: "Can you got a sort that for me?" arrived with mic avg
/// RMS 108 / peak 436, under the RMS-500 speech edge, so no speech edge
/// fired and ASR misheard it. The device (Samsung SM-T837V, API 29)
/// reports `agcAvailable: false` (AEC and NS available), so
/// `audioSource=voice_communication` gets no automatic gain on it.
///
///   --dart-define=MIC_GAIN=2.0         digital gain on every mic chunk
///                                      (1.0..4.0, clipped; absent = off)
///   --dart-define=SPEECH_EDGE_RMS=300  speech-edge RMS level (absent = 500)
library;

import 'dart:typed_data';

/// Raw define; empty when not set.
const String kMicGainDefine = String.fromEnvironment('MIC_GAIN');

/// Raw define; 0 when not set.
const int kSpeechEdgeRmsDefine = int.fromEnvironment('SPEECH_EDGE_RMS');

/// The build's speech-edge level: [kSpeechEdgeRmsDefine] when it is a
/// sane value (100..2000), else the build 175 default 500.
const double kSpeechEdgeRms =
    kSpeechEdgeRmsDefine >= 100 && kSpeechEdgeRmsDefine <= 2000 ? kSpeechEdgeRmsDefine * 1.0 : 500.0;

/// [define] parsed and bounded to 1.0..4.0; 1.0 (no change) when absent or
/// not a number.
double parseMicGain(String define) {
  final v = double.tryParse(define.trim());
  if (v == null || v.isNaN || v <= 1.0) return 1.0;
  return v > 4.0 ? 4.0 : v;
}

final double kMicGain = parseMicGain(kMicGainDefine);

/// For the BUILD line: `micGain=off speechEdgeRms=500`.
String describeMicKnobs({double? gain, double? edgeRms}) {
  final g = gain ?? kMicGain;
  final e = edgeRms ?? kSpeechEdgeRms;
  return 'micGain=${g == 1.0 ? 'off' : g.toStringAsFixed(1)} speechEdgeRms=${e.toStringAsFixed(0)}';
}

/// [chunk] (pcm16 little-endian) scaled by [gain], clipped to int16.
/// Returns [chunk] itself when [gain] is 1.0 — the default path copies
/// nothing and changes nothing.
Uint8List applyMicGain(Uint8List chunk, double gain) {
  if (gain == 1.0 || chunk.length < 2) return chunk;
  final out = Uint8List(chunk.length);
  final src = ByteData.sublistView(chunk);
  final dst = ByteData.sublistView(out);
  final n = chunk.length ~/ 2;
  for (var i = 0; i < n; i++) {
    var s = (src.getInt16(i * 2, Endian.little) * gain).round();
    if (s > 32767) s = 32767;
    if (s < -32768) s = -32768;
    dst.setInt16(i * 2, s, Endian.little);
  }
  if (chunk.length.isOdd) out[chunk.length - 1] = chunk[chunk.length - 1];
  return out;
}
