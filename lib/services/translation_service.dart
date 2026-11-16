import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import 'caption_service.dart';
import 'coins_service.dart';

/// Caption translation Urdu↔English (v1.0.8, free) — fully on-device
/// with ML Kit. No server, no paid API, no keys.
///
/// Why on-device: the TTS proxy has NO text endpoint — it only serves
/// POST /tts, /edge-tts and /transcribe (see tts-proxy/worker.js).
/// There is nothing to "reuse" for translation server-side, so the
/// translation runs in the app with ML Kit's downloaded language
/// models. The models download once on first use (about 30 MB per
/// language, over any connection — mobile data included); after that
/// translation works offline.
///
/// Coin cost: 25 coins per started minute of media (same rounding as
/// captions: rounded up, minimum 25, capped at 10 minutes). Charged
/// BEFORE translating, refunded in full when translation fails — the
/// exact pattern CaptionService.transcribeCharged uses.
class TranslationService {
  /// Coins per started minute of media for translation.
  static const int coinsPerMinute = 25;

  /// Same rounding as captions: ceil to whole minutes, min 1, cap 10.
  static int costForDuration(Duration? duration) {
    if (duration == null) return coinsPerMinute;
    var minutes = (duration.inSeconds / 60).ceil();
    if (minutes < 1) minutes = 1;
    if (minutes > 10) minutes = 10;
    return minutes * coinsPerMinute;
  }

  static TranslateLanguage _mlKitLang(String lang) {
    if (lang == 'ur') return TranslateLanguage.urdu;
    if (lang == 'en') return TranslateLanguage.english;
    throw Exception('Translation supports Urdu and English only.');
  }

  /// Download the two language models if missing. Returns normally
  /// once both are ready; throws when the download fails (offline,
  /// Play services missing, …). Mobile data is allowed.
  static Future<void> ensureModels({
    required String fromLang,
    required String toLang,
  }) async {
    final manager = OnDeviceTranslatorModelManager();
    for (final lang in {_mlKitLang(fromLang), _mlKitLang(toLang)}) {
      final code = lang.bcpCode;
      final downloaded = await manager.isModelDownloaded(code);
      if (!downloaded) {
        final ok = await manager.downloadModel(
          code,
          isWifiRequired: false,
        );
        if (!ok) {
          throw Exception(
            'Could not download the translation model ($code). '
            'Check the internet and try again.',
          );
        }
      }
    }
  }

  /// Translate caption lines one by one (line-by-line keeps the 1:1
  /// timing — every translated line keeps its original start/end).
  /// Empty lines stay empty. [onProgress] reports (done, total).
  static Future<List<String>> translateLines({
    required List<String> lines,
    required String fromLang,
    required String toLang,
    void Function(int done, int total)? onProgress,
  }) async {
    final translator = OnDeviceTranslator(
      sourceLanguage: _mlKitLang(fromLang),
      targetLanguage: _mlKitLang(toLang),
    );
    try {
      final out = <String>[];
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trim().isEmpty) {
          out.add('');
        } else {
          out.add(await translator.translateText(line));
        }
        onProgress?.call(i + 1, lines.length);
      }
      return out;
    } finally {
      await translator.close();
    }
  }

  /// Translate timed caption segments, keeping every segment's
  /// start/end. Returns the translated segments in the same order.
  static Future<List<CaptionSegment>> translateSegments({
    required List<CaptionSegment> segments,
    required String fromLang,
    required String toLang,
    void Function(int done, int total)? onProgress,
  }) async {
    final texts = await translateLines(
      lines: segments.map((s) => s.text).toList(),
      fromLang: fromLang,
      toLang: toLang,
      onProgress: onProgress,
    );
    return [
      for (var i = 0; i < segments.length; i++)
        CaptionSegment(
          start: segments[i].start,
          end: segments[i].end,
          text: texts[i],
        ),
    ];
  }

  /// Charge-then-translate, in that order (same pattern as
  /// CaptionService.transcribeCharged): the coin cost is checked and
  /// spent BEFORE any work. If translation then fails, the spend is
  /// refunded in full. Throws [InsufficientCoinsException] when the
  /// balance is too low (nothing is spent in that case).
  static Future<List<CaptionSegment>> translateCharged({
    required CoinsService coins,
    required List<CaptionSegment> segments,
    required String fromLang,
    required String toLang,
    Duration? duration,
    void Function(int done, int total)? onProgress,
  }) async {
    final cost = costForDuration(duration);
    if (!coins.canAfford(cost)) {
      throw InsufficientCoinsException(cost);
    }
    final spent = await coins.spend(cost, reason: 'caption_translation');
    if (!spent) {
      throw InsufficientCoinsException(cost);
    }
    try {
      await ensureModels(fromLang: fromLang, toLang: toLang);
      return await translateSegments(
        segments: segments,
        fromLang: fromLang,
        toLang: toLang,
        onProgress: onProgress,
      );
    } catch (e) {
      // Translation failed after the charge: refund in full.
      await coins.add(cost, reason: 'caption_translation_refund');
      rethrow;
    }
  }

  /// Parse an SRT document into timed segments (for the paste / pick
  /// flow: the user pastes SRT text or picks an .srt file). Malformed
  /// blocks are skipped; an SRT with no usable blocks throws.
  static List<CaptionSegment> parseSrt(String srt) {
    final segments = <CaptionSegment>[];
    final blocks = srt.split(RegExp(r'\r?\n\r?\n'));
    final timePattern = RegExp(
      r'(\d+):(\d+):(\d+)[,.](\d+)\s*-->\s*(\d+):(\d+):(\d+)[,.](\d+)',
    );
    for (final block in blocks) {
      final lines =
          block.split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty).toList();
      if (lines.isEmpty) continue;
      var timeLineIndex = -1;
      RegExpMatch? match;
      for (var i = 0; i < lines.length; i++) {
        match = timePattern.firstMatch(lines[i]);
        if (match != null) {
          timeLineIndex = i;
          break;
        }
      }
      if (match == null) continue;
      double toSeconds(String h, String m, String s, String ms) =>
          int.parse(h) * 3600 +
          int.parse(m) * 60 +
          int.parse(s) +
          int.parse(ms) / 1000;
      final start = toSeconds(
        match.group(1)!,
        match.group(2)!,
        match.group(3)!,
        match.group(4)!,
      );
      final end = toSeconds(
        match.group(5)!,
        match.group(6)!,
        match.group(7)!,
        match.group(8)!,
      );
      final text = lines.sublist(timeLineIndex + 1).join('\n').trim();
      if (text.isEmpty || end <= start) continue;
      segments.add(
        CaptionSegment(start: start, end: end, text: text),
      );
    }
    if (segments.isEmpty) {
      throw Exception('No captions found in that SRT text.');
    }
    segments.sort((a, b) => a.start.compareTo(b.start));
    return segments;
  }
}
