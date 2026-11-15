import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../models/tts_voice.dart';
import 'remote_config_service.dart';

/// Result of generating one text chunk.
class GeneratedAudio {
  /// Audio bytes ready to save (WAV for Gemini, MP3 for Edge).
  final Uint8List bytes;
  final String ext; // 'wav' | 'mp3'
  final String model; // proxy-reported model, '' for Edge

  /// True when the Gemini call failed (quota/429) and the generation was
  /// completed with an Edge voice instead.
  final bool fellBackToEdge;

  const GeneratedAudio({
    required this.bytes,
    required this.ext,
    this.model = '',
    this.fellBackToEdge = false,
  });
}

/// Calls the Nigraan TV TTS proxy — the SAME proxy and voices the website
/// uses (Gemini Aoede/Charon via POST /tts, Edge Asad/Uzma via
/// POST /edge-tts). No API key lives in the app: keys stay server-side
/// in the Worker (adding keys 5–6 later is a Worker secret update, no
/// app rebuild). What the remote config DOES control: which voices are
/// offered, Gemini vs Edge on/off, coins per minute, daily cap.
class TtsService {
  static const String _base = AppConfig.ttsProxyBase;

  /// Max chars per proxy call (≈1 minute of speech per chunk).
  static const int geminiMaxChars = 1500;
  static const int edgeMaxChars = 550;

  /// Voices offered in TTS Studio, from the remote config (voice ids +
  /// engine on/off). Falls back to all four voices when the config is
  /// unreachable (bundled defaults).
  static List<TtsVoice> availableVoices() {
    final cfg = RemoteConfigService.instance.config.tts;
    return TtsVoice.all.where((v) {
      if (!cfg.voices.contains(v.id)) return false;
      if (v.engine == TtsEngine.gemini && !cfg.geminiEnabled) return false;
      if (v.engine == TtsEngine.edge && !cfg.edgeEnabled) return false;
      return true;
    }).toList();
  }

  /// Same-gender Edge voice used as the Gemini fallback.
  static TtsVoice edgeFallbackFor(TtsVoice geminiVoice) =>
      geminiVoice.gender == 'Male' ? TtsVoice.byId('asad') : TtsVoice.byId('uzma');

  /// Split [text] into ~1-minute chunks for [voice].
  /// Splits on sentence boundaries first, then on words for long sentences.
  static List<String> chunkText(String text, TtsVoice voice) {
    final maxChars =
        voice.engine == TtsEngine.gemini ? geminiMaxChars : edgeMaxChars;
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return [];
    if (clean.length <= maxChars) return [clean];

    final sentences = clean.split(RegExp(r'(?<=[.!?؟۔])\s+'));
    final chunks = <String>[];
    var current = StringBuffer();
    void flush() {
      final s = current.toString().trim();
      if (s.isNotEmpty) chunks.add(s);
      current = StringBuffer();
    }

    for (final sentence in sentences) {
      if (sentence.length > maxChars) {
        // Very long sentence: split on words.
        flush();
        final words = sentence.split(' ');
        for (final word in words) {
          if (current.length + word.length + 1 > maxChars) flush();
          if (current.isNotEmpty) current.write(' ');
          current.write(word);
        }
        flush();
      } else {
        if (current.length + sentence.length + 1 > maxChars) flush();
        if (current.isNotEmpty) current.write(' ');
        current.write(sentence);
      }
    }
    flush();
    return chunks;
  }

  /// Generate audio for ONE chunk of text, with automatic fallback:
  /// if the Gemini endpoint fails (quota/429/any error) the generation
  /// is retried with the same-gender Edge voice (Asad/Uzma), which is
  /// free. The caller shows a note when [GeneratedAudio.fellBackToEdge]
  /// is true. Throws only when BOTH engines fail.
  Future<GeneratedAudio> generateChunkWithFallback(
    String text,
    TtsVoice voice, {
    String lang = 'ur',
  }) async {
    final cfg = RemoteConfigService.instance.config.tts;
    final useGemini =
        voice.engine == TtsEngine.gemini && cfg.geminiEnabled;
    if (!useGemini) {
      // Edge voice selected, or Gemini disabled remotely: Edge directly.
      final edgeVoice = voice.engine == TtsEngine.edge
          ? voice
          : edgeFallbackFor(voice);
      final gen = await _generateEdge(text, edgeVoice);
      return GeneratedAudio(
        bytes: gen.bytes,
        ext: gen.ext,
        fellBackToEdge: voice.engine == TtsEngine.gemini,
      );
    }
    try {
      return await _generateGemini(text, voice, lang);
    } catch (e) {
      // Gemini busy / quota / error -> fall back to free Edge voice.
      if (!cfg.edgeEnabled) rethrow;
      final edgeVoice = edgeFallbackFor(voice);
      final gen = await _generateEdge(text, edgeVoice);
      return GeneratedAudio(
        bytes: gen.bytes,
        ext: gen.ext,
        fellBackToEdge: true,
      );
    }
  }

  /// Generate audio for ONE chunk with a single engine (no fallback).
  Future<GeneratedAudio> generateChunk(
    String text,
    TtsVoice voice, {
    String lang = 'ur',
  }) async {
    if (voice.engine == TtsEngine.gemini) {
      return _generateGemini(text, voice, lang);
    }
    return _generateEdge(text, voice);
  }

  Future<GeneratedAudio> _generateGemini(
    String text,
    TtsVoice voice,
    String lang,
  ) async {
    final res = await http
        .post(
          Uri.parse('$_base/tts'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'text': text, 'voice': voice.apiVoice, 'lang': lang}),
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      throw Exception('TTS failed (${res.statusCode}): ${res.body}');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final audioB64 = data['audio'] as String?;
    if (audioB64 == null || audioB64.isEmpty) {
      throw Exception('TTS returned no audio');
    }
    final raw = base64Decode(audioB64);
    final format = data['format'] as String? ?? '';
    // The website does the same: raw PCM (24 kHz) gets a WAV header so
    // normal players can play it; WAV stays as-is.
    if (format == 'pcm24k') {
      return GeneratedAudio(
        bytes: pcmToWav(raw),
        ext: 'wav',
        model: data['model'] as String? ?? '',
      );
    }
    return GeneratedAudio(
      bytes: raw,
      ext: 'wav',
      model: data['model'] as String? ?? '',
    );
  }

  Future<GeneratedAudio> _generateEdge(String text, TtsVoice voice) async {
    final res = await http
        .post(
          Uri.parse('$_base/edge-tts'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'text': text, 'voice': voice.apiVoice}),
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode == 429) {
      throw Exception(
        'Daily Edge limit reached (10 minutes/day). Try a Gemini voice or come back tomorrow.',
      );
    }
    if (res.statusCode != 200) {
      throw Exception('Edge TTS failed (${res.statusCode}): ${res.body}');
    }
    return GeneratedAudio(bytes: res.bodyBytes, ext: 'mp3');
  }

  /// Wrap 16-bit mono PCM sampled at 24 kHz in a WAV header.
  /// (Same conversion the nigraantv.xyz website does for Gemini audio.)
  static Uint8List pcmToWav(Uint8List pcm) {
    const sampleRate = 24000;
    const numChannels = 1;
    const bitsPerSample = 16;
    final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign = numChannels * bitsPerSample ~/ 8;
    final dataSize = pcm.length;
    final out = Uint8List(44 + dataSize);
    final d = ByteData.sublistView(out);

    void writeString(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        out[offset + i] = s.codeUnitAt(i);
      }
    }

    writeString(0, 'RIFF');
    d.setUint32(4, 36 + dataSize, Endian.little);
    writeString(8, 'WAVE');
    writeString(12, 'fmt ');
    d.setUint32(16, 16, Endian.little); // Subchunk1Size
    d.setUint16(20, 1, Endian.little); // PCM
    d.setUint16(22, numChannels, Endian.little);
    d.setUint32(24, sampleRate, Endian.little);
    d.setUint32(28, byteRate, Endian.little);
    d.setUint16(32, blockAlign, Endian.little);
    d.setUint16(34, bitsPerSample, Endian.little);
    writeString(36, 'data');
    d.setUint32(40, dataSize, Endian.little);
    out.setRange(44, 44 + dataSize, pcm);
    return out;
  }

  /// On-device cache: same text + voice + lang always returns the same
  /// file, so repeat generations cost no coins and no quota.
  static Future<File> cacheFile(
    String text,
    TtsVoice voice,
    String lang,
    String ext,
  ) async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${dir.path}/audio_cache');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    final hash =
        sha256.convert(utf8.encode('${voice.engine.name}|${voice.id}|$lang|$text')).toString();
    return File('${cacheDir.path}/$hash.$ext');
  }
}
