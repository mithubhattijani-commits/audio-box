import 'dart:typed_data';

import 'wav_utils.dart';

/// TTS voice controls (v1.0.8, free) — applied on-device to the
/// generated WAV bytes, AFTER the proxy returns them.
///
/// The proxy itself accepts only {text, voice, lang} (see
/// tts-proxy/worker.js: no rate/pitch/style parameters, and the Edge
/// SSML hardcodes pitch '+0Hz' / rate '+0%'). So speed and pauses are
/// done here, on the PCM — no server change, no new API.
///
/// - Speed (0.5x–2.0x): linear-interpolation resample. Like any
///   resample it also changes the pitch — the UI says so plainly.
///   True pitch-shift at constant tempo needs a phase vocoder, which
///   is NOT in this build (see the report).
/// - Pauses: silence inserted at sentence boundaries. Boundary times
///   are even-split by character count over the audio (the same
///   even-split convention the caption tools already use honestly).
///
/// Applies to Gemini voices only (WAV output). Edge voices return MP3,
/// which cannot be resampled without a decoder — the TTS screen
/// disables the controls for Edge voices and says so.
class TtsControls {
  /// 1.0 = normal speed. 0.5 = half speed, 2.0 = double speed.
  final double speed;

  /// Silence inserted between sentences, in seconds (0 = off).
  final double pauseSeconds;

  const TtsControls({this.speed = 1.0, this.pauseSeconds = 0.0});

  bool get isDefault =>
      (speed - 1.0).abs() < 0.001 && pauseSeconds <= 0;

  /// Cache-key suffix so a 1.25x file never collides with the 1.0x
  /// file of the same text + voice.
  String get cacheSuffix {
    if (isDefault) return '';
    final s = speed.toStringAsFixed(2);
    final p = pauseSeconds.toStringAsFixed(1);
    return '|s$s|p$p';
  }
}

/// Sentence boundaries (character offsets) in [text], split on
/// sentence-ending punctuation (Latin + Urdu). The final sentence has
/// no trailing boundary.
List<int> sentenceBoundaries(String text) {
  final boundaries = <int>[];
  final pattern = RegExp(r'[.!?؟۔]\s+');
  for (final m in pattern.allMatches(text)) {
    boundaries.add(m.end);
  }
  return boundaries;
}

/// Apply [controls] to Gemini WAV [bytes] for [text]. Returns the
/// processed WAV bytes. No-op (same bytes back) when the controls are
/// default. Throws when the input is not a supported WAV.
Uint8List applyTtsControls(
  Uint8List bytes, {
  required String text,
  required TtsControls controls,
}) {
  if (controls.isDefault) return Uint8List.fromList(bytes);
  var out = bytes;
  if ((controls.speed - 1.0).abs() >= 0.001) {
    out = resampleWav(out, controls.speed);
  }
  if (controls.pauseSeconds > 0) {
    final wav = parseWav(out);
    if (wav == null) throw Exception('Not a supported WAV file.');
    final totalChars = text.length;
    if (totalChars > 0) {
      final duration = wav.durationSeconds;
      final at = <double>[];
      for (final boundary in sentenceBoundaries(text)) {
        at.add(boundary / totalChars * duration);
      }
      out = insertSilenceWav(out, at, controls.pauseSeconds);
    }
  }
  return out;
}
