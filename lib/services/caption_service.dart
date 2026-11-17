import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import 'coins_service.dart';
import 'caption_styles.dart';
import 'remote_config_service.dart';

/// One word with its real spoken timing, as returned by the
/// /transcribe proxy (Whisper word timestamps). When a segment has
/// no words, callers fall back to even-split timing.
class CaptionWord {
  final String word;
  final double start;
  final double end;

  const CaptionWord({
    required this.word,
    required this.start,
    required this.end,
  });

  factory CaptionWord.fromJson(Map<String, dynamic> j) {
    return CaptionWord(
      word: (j['word'] ?? j['text'] ?? j['w'] ?? '').toString().trim(),
      start: (j['start'] as num?)?.toDouble() ??
          (j['s'] as num?)?.toDouble() ??
          0,
      end: (j['end'] as num?)?.toDouble() ??
          (j['e'] as num?)?.toDouble() ??
          0,
    );
  }

  Map<String, dynamic> toJson() => {
        'word': word,
        'start': start,
        'end': end,
      };
}

/// One timed caption line returned by POST /transcribe.
class CaptionSegment {
  /// Start time in seconds (may be fractional).
  final double start;

  /// End time in seconds.
  final double end;

  final String text;

  /// Real Whisper word timings for this line (empty = unknown, use
  /// even-split fallback). Emoji stay attached to their word — the
  /// proxy returns them inside the word text, never stripped.
  final List<CaptionWord> words;

  /// Second-language line for dual captions (e.g. the English line
  /// under an Urdu line). Empty = no second line. Set by the
  /// translator screen or typed by hand in the line editor.
  final String translation;

  const CaptionSegment({
    required this.start,
    required this.end,
    required this.text,
    this.words = const [],
    this.translation = '',
  });

  factory CaptionSegment.fromJson(Map<String, dynamic> j) {
    final words = <CaptionWord>[];
    final rawWords = j['words'] ?? j['word_timings'];
    if (rawWords is List) {
      for (final e in rawWords) {
        if (e is Map<String, dynamic>) {
          final w = CaptionWord.fromJson(e);
          if (w.word.isNotEmpty) words.add(w);
        } else if (e is Map) {
          final w = CaptionWord.fromJson(
            e.map((k, v) => MapEntry(k.toString(), v)),
          );
          if (w.word.isNotEmpty) words.add(w);
        }
      }
    }
    return CaptionSegment(
      start: (j['start'] as num?)?.toDouble() ?? 0,
      end: (j['end'] as num?)?.toDouble() ?? 0,
      text: (j['text'] ?? '').toString().trim(),
      words: words,
      translation: (j['translation'] ??
              j['translated_text'] ??
              j['english'] ??
              '')
          .toString()
          .trim(),
    );
  }

  CaptionSegment copyWith({
    double? start,
    double? end,
    String? text,
    List<CaptionWord>? words,
    String? translation,
  }) {
    return CaptionSegment(
      start: start ?? this.start,
      end: end ?? this.end,
      text: text ?? this.text,
      words: words ?? this.words,
      translation: translation ?? this.translation,
    );
  }

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'text': text,
        'words': words.map((w) => w.toJson()).toList(),
        'translation': translation,
      };

  /// `MM:SS – MM:SS` label for the list UI.
  String get timeLabel =>
      '${CaptionService.formatClock(start)} – ${CaptionService.formatClock(end)}';
}

/// Result of one POST /transcribe call.
class TranscriptionResult {
  final List<CaptionSegment> segments;

  /// Full SRT document (from the server, or rebuilt locally from
  /// [segments] when the server sent none).
  final String srt;

  /// Media duration in seconds, as reported by the server (echoes the
  /// duration the app sent, when it sent one).
  final double? durationSeconds;

  /// Proxy-reported model id (internal only — never shown in the UI).
  final String model;

  const TranscriptionResult({
    required this.segments,
    required this.srt,
    this.durationSeconds,
    this.model = '',
  });

  factory TranscriptionResult.fromJson(Map<String, dynamic> j) {
    final rawSegments = j['segments'];
    final segments = <CaptionSegment>[];
    if (rawSegments is List) {
      for (final e in rawSegments) {
        if (e is Map<String, dynamic>) {
          final seg = CaptionSegment.fromJson(e);
          if (seg.text.isNotEmpty) segments.add(seg);
        } else if (e is Map) {
          final seg = CaptionSegment.fromJson(
            e.map((k, v) => MapEntry(k.toString(), v)),
          );
          if (seg.text.isNotEmpty) segments.add(seg);
        }
      }
    }
    var srt = (j['srt'] ?? '').toString();
    if (srt.trim().isEmpty && segments.isNotEmpty) {
      srt = CaptionService.buildSrt(segments);
    }
    return TranscriptionResult(
      segments: segments,
      srt: srt,
      durationSeconds: (j['duration_seconds'] as num?)?.toDouble(),
      model: (j['model'] ?? '').toString(),
    );
  }
}

/// Thrown by [CaptionService.transcribeCharged] when the balance cannot
/// cover the caption cost. The screen turns this into the "open the
/// Coins tab" message — no coins are spent in that case.
class InsufficientCoinsException implements Exception {
  final int cost;

  const InsufficientCoinsException(this.cost);

  @override
  String toString() => 'InsufficientCoinsException(cost: $cost)';
}

/// Audio/video → captions, via the TTS proxy Worker's POST /transcribe.
///
/// The app NEVER holds a transcription key: the file is uploaded to the
/// proxy (base64 JSON, same JSON style as POST /tts) and the Worker
/// calls the transcription model server-side with its own rotated keys.
/// See the README ("POST /transcribe") for the endpoint contract.
class CaptionService {
  /// Hard server limit (also enforced by the Worker): 25 MB.
  static const int maxFileBytes = 25 * 1024 * 1024;

  /// Hard server limit (also enforced by the Worker): 10 minutes.
  static const int maxDurationSeconds = 600;

  /// Audio extensions the picker offers for the Caption Generator.
  static const List<String> audioExtensions = [
    'mp3',
    'wav',
    'm4a',
    'aac',
    'ogg',
    'flac',
  ];

  /// Video extensions the picker offers.
  static const List<String> videoExtensions = [
    'mp4',
    'mov',
    'mkv',
    'webm',
    'm4v',
  ];

  static const List<String> allMediaExtensions = [
    ...audioExtensions,
    ...videoExtensions,
  ];

  static String get _base =>
      RemoteConfigService.instance.config.tts.proxyUrl;

  static String mimeTypeForPath(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'mp3' => 'audio/mpeg',
      'wav' => 'audio/wav',
      'm4a' => 'audio/mp4',
      'aac' => 'audio/aac',
      'ogg' => 'audio/ogg',
      'flac' => 'audio/flac',
      'mp4' || 'm4v' => 'video/mp4',
      'mov' => 'video/quicktime',
      'mkv' => 'video/x-matroska',
      'webm' => 'video/webm',
      _ => 'application/octet-stream',
    };
  }

  static bool isVideoPath(String path) {
    final ext = path.split('.').last.toLowerCase();
    return videoExtensions.contains(ext);
  }

  /// Coins for a media duration: coinsPerMinute (remote config,
  /// default 50) per started minute, rounded UP to whole minutes,
  /// minimum one minute (50 coins at the default rate). Capped at
  /// 10 minutes (the server limit) so a bad duration estimate can
  /// never charge more than 10 minutes' worth.
  static int costForDuration(Duration? duration, int coinsPerMinute) {
    if (duration == null) return coinsPerMinute;
    var minutes = (duration.inSeconds / 60).ceil();
    if (minutes < 1) minutes = 1;
    if (minutes > 10) minutes = 10;
    return minutes * coinsPerMinute;
  }

  /// `MM:SS` clock label (list UI).
  static String formatClock(double seconds) {
    final total = seconds.round();
    final m = total ~/ 60;
    final s = total % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// `HH:MM:SS,mmm` SRT timestamp.
  static String formatSrtTimestamp(double seconds) {
    final totalMs = (seconds * 1000).round();
    final h = totalMs ~/ 3600000;
    final m = (totalMs % 3600000) ~/ 60000;
    final s = (totalMs % 60000) ~/ 1000;
    final ms = totalMs % 1000;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')},'
        '${ms.toString().padLeft(3, '0')}';
  }

  /// Build a full SRT document from segments (client-side fallback
  /// when the server returns segments but no SRT string).
  static String buildSrt(List<CaptionSegment> segments) {
    final buf = StringBuffer();
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      buf.writeln(i + 1);
      buf.writeln(
        '${formatSrtTimestamp(seg.start)} --> ${formatSrtTimestamp(seg.end)}',
      );
      buf.writeln(seg.text);
      buf.writeln();
    }
    return buf.toString();
  }

  /// Build a WebVTT document from segments (YouTube / web players).
  /// [dualLanguage] adds each line's [CaptionSegment.translation]
  /// as a second line in the same cue when it is non-empty.
  static String buildVtt(
    List<CaptionSegment> segments, {
    bool dualLanguage = false,
  }) {
    final buf = StringBuffer()..writeln('WEBVTT')..writeln();
    for (final seg in segments) {
      if (seg.text.trim().isEmpty) continue;
      buf.writeln(
        '${formatVttTimestamp(seg.start)} --> ${formatVttTimestamp(seg.end)}',
      );
      buf.writeln(seg.text);
      if (dualLanguage && seg.translation.trim().isNotEmpty) {
        buf.writeln(seg.translation);
      }
      buf.writeln();
    }
    return buf.toString();
  }

  /// `HH:MM:SS.mmm` WebVTT timestamp (dot, not comma, unlike SRT).
  static String formatVttTimestamp(double seconds) =>
      formatSrtTimestamp(seconds).replaceFirst(',', '.');

  /// Plain-text export: one caption line per text line, no timings.
  /// This is what the Copy button copies. [dualLanguage] adds each
  /// line's translation directly under it when non-empty.
  static String buildPlainText(
    List<CaptionSegment> segments, {
    bool dualLanguage = false,
  }) {
    final lines = <String>[];
    for (final seg in segments) {
      if (seg.text.trim().isEmpty) continue;
      lines.add(seg.text);
      if (dualLanguage && seg.translation.trim().isNotEmpty) {
        lines.add(seg.translation);
      }
    }
    return lines.join('\n');
  }

  /// TXT export file contents — same as [buildPlainText].
  static String buildTxt(
    List<CaptionSegment> segments, {
    bool dualLanguage = false,
  }) =>
      buildPlainText(segments, dualLanguage: dualLanguage);

  // ---- real word timing (Whisper) with even-split fallback ----
  //
  // The proxy returns Whisper word timings on each segment
  // ([CaptionSegment.words]). Karaoke / pop / typewriter use these
  // first; a line with no word timings (manual line, old result)
  // falls back to the even-split helpers in CaptionStyles.

  /// Start of word [index] in [seg] — real timing when known.
  static double wordStartOf(CaptionSegment seg, int index) {
    if (index >= 0 && index < seg.words.length) {
      return seg.words[index].start;
    }
    return CaptionStyles.wordStart(
      start: seg.start,
      end: seg.end,
      text: seg.text,
      index: index,
    );
  }

  /// End of word [index] in [seg] — real timing when known.
  static double wordEndOf(CaptionSegment seg, int index) {
    if (index >= 0 && index < seg.words.length) {
      return seg.words[index].end;
    }
    return CaptionStyles.wordEnd(
      start: seg.start,
      end: seg.end,
      text: seg.text,
      index: index,
    );
  }

  /// Index of the word being spoken at [positionSeconds], or -1 when
  /// outside the line. Real word timings when known, even-split
  /// otherwise.
  static int activeWordIndexOf(
    CaptionSegment seg,
    double positionSeconds,
  ) {
    if (seg.words.isNotEmpty) {
      for (var i = 0; i < seg.words.length; i++) {
        if (positionSeconds >= seg.words[i].start &&
            positionSeconds < seg.words[i].end) {
          return i;
        }
      }
      if (positionSeconds < seg.start) return -1;
      if (positionSeconds >= seg.end) return seg.words.length - 1;
      return -1;
    }
    return CaptionStyles.activeWordIndex(
      start: seg.start,
      end: seg.end,
      text: seg.text,
      positionSeconds: positionSeconds,
    );
  }

  /// Build a styled ASS (Advanced Substation Alpha) document from
  /// segments + a caption style, so the captions open in CapCut / any
  /// editor that reads ASS with the chosen look (colours, size,
  /// position, bold/outline). Word-by-word styles use the REAL
  /// Whisper word timings when the segment carries them
  /// ([wordStartOf]/[wordEndOf]) and even-split timing only as a
  /// fallback. The highlight-box word background has no ASS
  /// equivalent and is skipped here — the line still carries the
  /// style's colours.
  /// - karaoke: one Dialogue per line, {\kf} per word (ASS karaoke
  ///   fills the sung part with SecondaryColour = highlight).
  /// - pop: one Dialogue per word (only that word on screen).
  /// - typewriter: one Dialogue per word, showing words-so-far.
  /// - flash: one plain Dialogue per line.
  /// [playResX]/[playResY] set the ASS canvas: pass 1080x1920 for a
  /// vertical (9:16) video and 1280x720 for a horizontal one — the
  /// font size scales with the canvas height so the captions look
  /// the same size relative to the frame. [outline]/[shadow]/
  /// [background] override the style's FX toggles when given.
  /// [dualLanguage] adds each line's translation as a second,
  /// smaller Dialogue above the main line.
  static String buildAss(
    List<CaptionSegment> segments,
    CaptionStyle style, {
    CaptionPosition position = CaptionPosition.bottom,
    CaptionSize size = CaptionSize.medium,
    int? highlightColor,
    String? fontFamily,
    int playResX = 1280,
    int playResY = 720,
    bool? outline,
    bool? shadow,
    bool? background,
    int? backgroundColor,
    bool dualLanguage = false,
  }) {
    final hl = highlightColor ?? style.highlightColor;
    // Font size scales with the canvas height (style sizes are tuned
    // for a 720p canvas) so captions keep the same relative size on
    // a 1080x1920 portrait canvas.
    final resScale = playResY / 720;
    final fontSize =
        (style.fontSizePt * CaptionStyles.sizeScale(size) * resScale)
            .round();
    final dualFontSize = (fontSize * 0.7).round();
    final marginV = (40 * resScale).round();
    final dualMarginV = marginV + fontSize;
    final alignment = switch (position) {
      CaptionPosition.top => 8,
      CaptionPosition.middle => 5,
      CaptionPosition.bottom => 2,
    };
    final useOutline = outline ?? style.outline;
    final useShadow = shadow ?? style.shadow;
    final useBackground = background ?? (style.backgroundColor != 0);
    final back = useBackground
        ? CaptionStyles.assColor(
            backgroundColor ??
                (style.backgroundColor != 0
                    ? style.backgroundColor
                    : CaptionStyles.black70),
          )
        : '&H80000000';
    // Background ON = opaque box behind the line (BorderStyle 3);
    // otherwise the classic outline + shadow style (BorderStyle 1).
    final borderStyle = useBackground ? 3 : 1;
    final buf = StringBuffer();
    buf.writeln('[Script Info]');
    buf.writeln('Title: Magic Box Captions');
    buf.writeln('ScriptType: v4.00+');
    buf.writeln('WrapStyle: 0');
    buf.writeln('ScaledBorderAndShadow: yes');
    buf.writeln('PlayResX: $playResX');
    buf.writeln('PlayResY: $playResY');
    buf.writeln();
    buf.writeln('[V4+ Styles]');
    buf.writeln(
      'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, '
      'OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, '
      'ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, '
      'Alignment, MarginL, MarginR, MarginV, Encoding',
    );
    buf.writeln(
      'Style: AudioBox,${fontFamily ?? 'Arial'},$fontSize,'
      '${CaptionStyles.assColor(style.textColor)},'
      '${CaptionStyles.assColor(hl)},'
      '&H00000000,$back,${style.bold ? -1 : 0},0,0,0,100,100,0,0,'
      '$borderStyle,${useOutline ? 2 : 1},${useShadow ? 1 : 0},'
      '$alignment,10,10,$marginV,1',
    );
    if (dualLanguage) {
      buf.writeln(
        'Style: AudioBoxDual,${fontFamily ?? 'Arial'},$dualFontSize,'
        '${CaptionStyles.assColor(CaptionStyles.white)},'
        '${CaptionStyles.assColor(CaptionStyles.white)},'
        '&H00000000,$back,${style.bold ? -1 : 0},0,0,0,100,100,0,0,'
        '$borderStyle,${useOutline ? 2 : 1},${useShadow ? 1 : 0},'
        '$alignment,10,10,$dualMarginV,1',
      );
    }
    buf.writeln();
    buf.writeln('[Events]');
    buf.writeln(
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, '
      'MarginV, Effect, Text',
    );
    for (final seg in segments) {
      if (seg.text.trim().isEmpty) continue;
      final words = CaptionStyles.wordsOf(seg.text);
      if (words.isEmpty) continue;
      String show(String w) =>
          style.uppercase ? w.toUpperCase() : w;
      switch (style.animation) {
        case CaptionAnimation.karaoke:
          final line = StringBuffer();
          for (var i = 0; i < words.length; i++) {
            final ws = wordStartOf(seg, i);
            final we = wordEndOf(seg, i);
            final cs = ((we - ws) * 100).round().clamp(1, 6000);
            line.write('{\\kf$cs}${_assEscape(show(words[i]))} ');
          }
          buf.writeln(
            'Dialogue: 0,${_assTimestamp(seg.start)},'
            '${_assTimestamp(seg.end)},AudioBox,,0,0,0,,'
            '${line.toString().trimRight()}',
          );
        case CaptionAnimation.pop:
          for (var i = 0; i < words.length; i++) {
            final ws = wordStartOf(seg, i);
            final we = wordEndOf(seg, i);
            buf.writeln(
              'Dialogue: 0,${_assTimestamp(ws)},${_assTimestamp(we)},'
              'AudioBox,,0,0,0,,${_assEscape(show(words[i]))}',
            );
          }
        case CaptionAnimation.typewriter:
          for (var i = 0; i < words.length; i++) {
            final ws = wordStartOf(seg, i);
            final we = i + 1 < words.length
                ? wordStartOf(seg, i + 1)
                : seg.end;
            final shown =
                words.sublist(0, i + 1).map(show).join(' ');
            buf.writeln(
              'Dialogue: 0,${_assTimestamp(ws)},${_assTimestamp(we)},'
              'AudioBox,,0,0,0,,${_assEscape(shown)}',
            );
          }
        case CaptionAnimation.flash:
          buf.writeln(
            'Dialogue: 0,${_assTimestamp(seg.start)},'
            '${_assTimestamp(seg.end)},AudioBox,,0,0,0,,'
            '${_assEscape(show(seg.text))}',
          );
      }
      if (dualLanguage && seg.translation.trim().isNotEmpty) {
        buf.writeln(
          'Dialogue: 0,${_assTimestamp(seg.start)},'
          '${_assTimestamp(seg.end)},AudioBoxDual,,0,0,0,,'
          '${_assEscape(seg.translation)}',
        );
      }
    }
    return buf.toString();
  }

  /// ASS timestamp `H:MM:SS.cc` (centiseconds).
  static String _assTimestamp(double seconds) {
    final totalCs = (seconds * 100).round();
    final h = totalCs ~/ 360000;
    final m = (totalCs % 360000) ~/ 6000;
    final s = (totalCs % 6000) ~/ 100;
    final cs = totalCs % 100;
    return '$h:${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}.'
        '${cs.toString().padLeft(2, '0')}';
  }

  /// Escape ASS special characters in caption text.
  static String _assEscape(String text) => text
      .replaceAll(r'\', r'\\')
      .replaceAll('{', r'\{')
      .replaceAll('}', r'\}');

  /// Best-effort media duration from the file itself, WITHOUT uploading
  /// anything. Video: video_player initialise. Audio: audioplayers
  /// source duration, else a WAV header parse, else a file-size
  /// estimate (~128 kbps audio / ~1 Mbps video). Returns null only when
  /// every method fails — callers then charge the 1-minute minimum.
  static Future<Duration?> probeMediaDuration(File file) async {
    try {
      if (isVideoPath(file.path)) {
        final controller = VideoPlayerController.file(file);
        try {
          await controller.initialize();
          final d = controller.value.duration;
          if (d != Duration.zero) return d;
        } catch (_) {
          // Fall through to the size estimate.
        } finally {
          await controller.dispose();
        }
      } else {
        final player = AudioPlayer();
        try {
          await player.setSource(DeviceFileSource(file.path));
          final d = await player.getDuration();
          if (d != null && d != Duration.zero) return d;
        } catch (_) {
          // Fall through to the WAV header / size estimate.
        } finally {
          await player.dispose();
        }
        final wav = await _parseWavDuration(file);
        if (wav != null) return wav;
      }
    } catch (_) {
      // Fall through to the size estimate.
    }
    try {
      final size = await file.length();
      final bitrate = isVideoPath(file.path) ? 1000000 : 128000;
      final seconds = size * 8 / bitrate;
      if (seconds > 0) return Duration(seconds: seconds.round());
    } catch (_) {}
    return null;
  }

  /// WAV header duration: data bytes / byte rate. Null for non-WAV.
  static Future<Duration?> _parseWavDuration(File file) async {
    try {
      if (!file.path.toLowerCase().endsWith('.wav')) return null;
      final head = await file.openRead(0, 44).fold<BytesBuilder>(
        BytesBuilder(),
        (b, chunk) => b..add(chunk),
      );
      final bytes = head.takeBytes();
      if (bytes.length < 44) return null;
      final data = ByteData.sublistView(Uint8List.fromList(bytes));
      if (data.getUint32(0, Endian.little) != 0x46464952) return null; // 'RIFF'
      final byteRate = data.getUint32(28, Endian.little);
      final dataSize = data.getUint32(40, Endian.little);
      if (byteRate <= 0 || dataSize <= 0) return null;
      return Duration(
        milliseconds: (dataSize / byteRate * 1000).round(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Raw transcribe call (no coin handling). Throws on any HTTP or
  /// empty-result failure; the caller decides about refunds.
  static Future<TranscriptionResult> transcribe({
    required File file,
    required String lang,
    double? durationSeconds,
  }) async {
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw Exception('The picked file is empty.');
    }
    if (bytes.length > maxFileBytes) {
      throw Exception('File is too large (max 25 MB).');
    }
    if (durationSeconds != null && durationSeconds > maxDurationSeconds) {
      throw Exception('Media is too long (max 10 minutes).');
    }
    final fileName = file.path.split('/').last;
    final res = await http
        .post(
          Uri.parse('$_base/transcribe'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'audio': base64Encode(bytes),
            'mime_type': mimeTypeForPath(file.path),
            'file_name': fileName,
            'lang': lang,
            'duration_seconds': ?durationSeconds,
          }),
        )
        .timeout(const Duration(seconds: 180));
    if (res.statusCode != 200) {
      var detail = res.body;
      try {
        final data = jsonDecode(res.body);
        if (data is Map && data['error'] != null) {
          detail = data['error'].toString();
          if (data['detail'] != null) detail += ': ${data['detail']}';
        }
      } catch (_) {}
      throw Exception('Transcription failed (${res.statusCode}): $detail');
    }
    final result =
        TranscriptionResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    if (result.segments.isEmpty) {
      throw Exception('Transcription returned no captions.');
    }
    return result;
  }

  /// Charge-then-transcribe, in that order (same pattern as TTS
  /// Studio): the coin cost (50/min, rounded up, min 50) is checked
  /// and spent BEFORE the file is uploaded. If transcription then
  /// fails, the spend is refunded in full. Throws
  /// [InsufficientCoinsException] when the balance is too low (nothing
  /// is spent in that case).
  static Future<TranscriptionResult> transcribeCharged({
    required CoinsService coins,
    required File file,
    required String lang,
    Duration? duration,
  }) async {
    final cost = costForDuration(duration, coins.coinsPerMinute);
    if (!coins.canAfford(cost)) {
      throw InsufficientCoinsException(cost);
    }
    final spent = await coins.spend(cost, reason: 'caption_generation');
    if (!spent) {
      throw InsufficientCoinsException(cost);
    }
    try {
      return await transcribe(
        file: file,
        lang: lang,
        durationSeconds: duration?.inSeconds.toDouble(),
      );
    } catch (e) {
      // Transcription failed after the charge: refund in full.
      await coins.add(cost, reason: 'caption_failed_refund');
      rethrow;
    }
  }
}
