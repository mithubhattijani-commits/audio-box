import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/audio_item.dart';
import 'ads_service.dart';
import 'audio_download_service.dart';
import 'remote_config_service.dart';

/// Output formats the Audio Converter offers.
enum ConvertFormat {
  mp3,
  wav,
  m4a,
  ogg;

  String get ext => name;

  String get label => name.toUpperCase();

  /// ffmpeg audio encoder for this format.
  String get encoder => switch (this) {
        ConvertFormat.mp3 => 'libmp3lame',
        ConvertFormat.wav => 'pcm_s16le',
        ConvertFormat.m4a => 'aac',
        ConvertFormat.ogg => 'libvorbis',
      };

  /// True when the format takes a bitrate (-b:a). WAV is PCM, so a
  /// bitrate flag is meaningless (and rejected) for it.
  bool get isLossy => this != ConvertFormat.wav;
}

/// All manual options for one conversion run. Everything is chosen
/// BEFORE converting; the screen builds one of these per run.
class ConvertOptions {
  final ConvertFormat format;
  final int bitrateKbps; // 128 / 192 / 320 (lossy formats only)
  final int sampleRateHz; // 44100 / 48000
  final int channels; // 1 = mono, 2 = stereo
  final String voiceId; // 'asad' | 'uzma' — Re-generate mode only
  final double? trimStartSec; // null = no trim
  final double? trimEndSec; // null = to end of file
  final double speed; // 0.5–2.0, 1.0 = unchanged
  final double volumeGain; // 1.0 = unchanged, up to 2.0 = boost
  final bool normalize; // loudnorm (wins over volumeGain when on)
  final double fadeInSec; // 0 = none
  final double fadeOutSec; // 0 = none
  final String title; // ID3/metadata title, '' = none
  final String artist; // ID3/metadata artist, '' = none

  const ConvertOptions({
    this.format = ConvertFormat.mp3,
    this.bitrateKbps = 192,
    this.sampleRateHz = 44100,
    this.channels = 2,
    this.voiceId = 'asad',
    this.trimStartSec,
    this.trimEndSec,
    this.speed = 1.0,
    this.volumeGain = 1.0,
    this.normalize = false,
    this.fadeInSec = 0,
    this.fadeOutSec = 0,
    this.title = '',
    this.artist = '',
  });

  ConvertOptions copyWith({ConvertFormat? format, String? voiceId}) =>
      ConvertOptions(
        format: format ?? this.format,
        bitrateKbps: bitrateKbps,
        sampleRateHz: sampleRateHz,
        channels: channels,
        voiceId: voiceId ?? this.voiceId,
        trimStartSec: trimStartSec,
        trimEndSec: trimEndSec,
        speed: speed,
        volumeGain: volumeGain,
        normalize: normalize,
        fadeInSec: fadeInSec,
        fadeOutSec: fadeOutSec,
        title: title,
        artist: artist,
      );

  /// True when any effect beyond plain format/bitrate/rate/channels
  /// is active (trim, speed, volume, normalize, fade, tags).
  bool get hasEffects =>
      trimStartSec != null ||
      trimEndSec != null ||
      (speed - 1.0).abs() > 0.001 ||
      (volumeGain - 1.0).abs() > 0.001 ||
      normalize ||
      fadeInSec > 0 ||
      fadeOutSec > 0 ||
      title.isNotEmpty ||
      artist.isNotEmpty;
}

/// One converted file, as stored in the converter history
/// (SharedPreferences JSON, key [_historyKey]).
class ConvertedFile {
  final String id;
  final String fileName;
  final String filePath;
  final String format; // 'mp3' | 'wav' | 'm4a' | 'ogg'
  final String bitrateLabel; // e.g. '192 kbps' / 'PCM 16-bit'
  final int sampleRateHz;
  final int channels;
  final double durationSec;
  final int sizeBytes;
  final int createdAtMs;

  /// True when this file was produced by an ad-unlocked run (batch
  /// convert or video-to-audio): the unlock ad IS that file's ad, so
  /// downloading it must NOT show a second ad. Single-file converts
  /// are false — their download plays the usual 1 rewarded ad.
  final bool adUnlocked;

  const ConvertedFile({
    required this.id,
    required this.fileName,
    required this.filePath,
    required this.format,
    required this.bitrateLabel,
    required this.sampleRateHz,
    required this.channels,
    required this.durationSec,
    required this.sizeBytes,
    required this.createdAtMs,
    this.adUnlocked = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'filePath': filePath,
        'format': format,
        'bitrateLabel': bitrateLabel,
        'sampleRateHz': sampleRateHz,
        'channels': channels,
        'durationSec': durationSec,
        'sizeBytes': sizeBytes,
        'createdAtMs': createdAtMs,
        'adUnlocked': adUnlocked,
      };

  factory ConvertedFile.fromJson(Map<String, dynamic> json) =>
      ConvertedFile(
        id: json['id'] as String? ?? '',
        fileName: json['fileName'] as String? ?? '',
        filePath: json['filePath'] as String? ?? '',
        format: json['format'] as String? ?? 'mp3',
        bitrateLabel: json['bitrateLabel'] as String? ?? '',
        sampleRateHz: json['sampleRateHz'] as int? ?? 44100,
        channels: json['channels'] as int? ?? 2,
        durationSec: (json['durationSec'] as num?)?.toDouble() ?? 0,
        sizeBytes: json['sizeBytes'] as int? ?? 0,
        createdAtMs: json['createdAtMs'] as int? ?? 0,
        adUnlocked: json['adUnlocked'] as bool? ?? false,
      );
}

/// Real on-device format conversion via ffmpeg_kit_flutter_new
/// 4.6.8 (the maintained fork — the original ffmpeg_kit_flutter
/// package is abandoned and is NOT used).
///
/// Convert-file mode transcodes the ORIGINAL audio — it never
/// re-generates speech. Re-generate mode (Edge TTS Asad/Uzma) lives
/// in the screen and feeds its MP3 bytes through here so the chosen
/// format / bitrate / sample rate / channels still apply.
///
/// ffmpeg entry points (verified in the 4.6.8 pub cache — there is
/// NO `ffmpeg_kit_flutter_new.dart` barrel file, so the imports are
/// the per-file ones the package's own example uses):
/// `FFmpegKit.executeWithArgumentsAsync` + `ReturnCode.isSuccess`,
/// `FFprobeKit.getMediaInformation` + `MediaInformation.getDuration`.
class AudioConvertService {
  static const String historyKey = 'converter_history_v1';
  static const int maxHistoryEntries = 50;
  static const int maxInputBytes = 100 * 1024 * 1024;

  /// Directory converted files are saved in (app documents dir).
  static Future<Directory> convertedDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final out = Directory('${dir.path}/converted_audio');
    if (!await out.exists()) await out.create(recursive: true);
    return out;
  }

  /// Duration of [file] in seconds via ffprobe (works for wav, mp3,
  /// m4a, ogg, mp4…). Returns null when ffprobe cannot read it — the
  /// caller treats that as "unknown duration" (progress becomes
  /// indeterminate, fade-out is skipped), never as a crash.
  static Future<double?> probeDurationSec(File file) async {
    try {
      final session = await FFprobeKit.getMediaInformation(file.path);
      final info = session.getMediaInformation();
      final raw = info?.getDuration();
      final seconds = raw == null ? null : double.tryParse(raw);
      if (seconds != null && seconds > 0) return seconds;
    } catch (_) {
      // Fall through to null — duration unknown.
    }
    return null;
  }

  /// Transcode in-memory audio bytes to MP3 bytes (v1.0.11).
  ///
  /// Used when an Edge TTS call silently fell back to Gemini: Gemini
  /// returns WAV while Edge returns MP3, and the MP3-concat / MP3-save
  /// flows need real MP3 bytes. Writes [bytes] to a temp file with its
  /// real extension, re-encodes with ffmpeg (libmp3lame, 192 kbps) and
  /// returns the MP3 bytes. Temp files are always cleaned up. Throws
  /// when ffmpeg fails — the caller treats that like any other
  /// generation failure.
  static Future<Uint8List> transcodeBytesToMp3(
    Uint8List bytes,
    String ext,
  ) async {
    final dir = await convertedDir();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final input = File('${dir.path}/norm_tmp_$stamp.$ext');
    final output = File('${dir.path}/norm_tmp_$stamp.mp3');
    try {
      await input.writeAsBytes(bytes);
      final args = <String>[
        '-y',
        '-i',
        input.path,
        '-vn',
        '-c:a',
        'libmp3lame',
        '-b:a',
        '192k',
        output.path,
      ];
      final completer = Completer<FFmpegSession>();
      final session = await FFmpegKit.executeWithArgumentsAsync(
        args,
        (s) {
          if (!completer.isCompleted) completer.complete(s);
        },
      );
      final doneSession = await completer.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          unawaited(FFmpegKit.cancel(session.getSessionId()));
          throw TimeoutException('MP3 normalize timed out after 2 minutes.');
        },
      );
      final returnCode = await doneSession.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        throw Exception(
          'ffmpeg normalize failed (code ${returnCode?.getValue()})',
        );
      }
      if (!await output.exists()) {
        throw Exception('ffmpeg normalize produced no file.');
      }
      final outBytes = await output.readAsBytes();
      if (outBytes.isEmpty) {
        throw Exception('ffmpeg normalize produced an empty file.');
      }
      return outBytes;
    } finally {
      for (final f in [input, output]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  /// ffmpeg audio filter chain for [options], or null when no filter
  /// is needed. [effectiveDurationSec] is the output length after
  /// trim + speed (when known) — it positions the fade-out.
  static String? buildFilter(
    ConvertOptions options,
    double? effectiveDurationSec,
  ) {
    final parts = <String>[];
    if ((options.speed - 1.0).abs() > 0.001) {
      // atempo supports 0.5–2.0 in a single filter — exactly the
      // range the UI offers, so no chaining is needed.
      parts.add('atempo=${options.speed.toStringAsFixed(2)}');
    }
    if (options.normalize) {
      // Single-pass loudnorm. When normalize is on it wins over the
      // manual volume gain (a gain before loudnorm would be undone).
      parts.add('loudnorm=I=-16:TP=-1.5:LRA=11');
    } else if ((options.volumeGain - 1.0).abs() > 0.001) {
      parts.add('volume=${options.volumeGain.toStringAsFixed(2)}');
    }
    if (options.fadeInSec > 0) {
      parts.add(
        'afade=t=in:st=0:d=${options.fadeInSec.toStringAsFixed(2)}',
      );
    }
    if (options.fadeOutSec > 0 && effectiveDurationSec != null) {
      final start = (effectiveDurationSec - options.fadeOutSec)
          .clamp(0, effectiveDurationSec)
          .toDouble();
      parts.add(
        'afade=t=out:st=${start.toStringAsFixed(2)}'
        ':d=${options.fadeOutSec.toStringAsFixed(2)}',
      );
    }
    if (parts.isEmpty) return null;
    return parts.join(',');
  }

  /// Full ffmpeg argument list for one transcode. Arguments (not a
  /// shell string) so file names with spaces never need quoting.
  /// Trim uses input seeking (-ss / -t BEFORE -i).
  static List<String> buildArgs({
    required String inputPath,
    required String outputPath,
    required ConvertOptions options,
    double? inputDurationSec,
    bool stripVideo = false,
  }) {
    final args = <String>['-y'];
    final trimStart = options.trimStartSec;
    final trimEnd = options.trimEndSec;
    if (trimStart != null && trimStart > 0) {
      args.addAll(['-ss', trimStart.toStringAsFixed(3)]);
    }
    if (trimEnd != null && trimEnd > 0) {
      final start = trimStart ?? 0;
      final length = trimEnd - start;
      if (length > 0) args.addAll(['-t', length.toStringAsFixed(3)]);
    }
    args.addAll(['-i', inputPath]);
    if (stripVideo) args.add('-vn');

    // Effective output duration (for fade-out positioning): trim
    // first, then speed stretches/shrinks it.
    double? effective;
    if (inputDurationSec != null) {
      effective = inputDurationSec;
      if (trimStart != null) effective -= trimStart;
      if (trimEnd != null && inputDurationSec > trimEnd) {
        effective = trimEnd - (trimStart ?? 0);
      }
      if ((options.speed - 1.0).abs() > 0.001) {
        effective = effective / options.speed;
      }
    }
    final filter = buildFilter(options, effective);
    if (filter != null) args.addAll(['-af', filter]);

    args.addAll(['-ar', options.sampleRateHz.toString()]);
    args.addAll(['-ac', options.channels.toString()]);
    if (options.format.isLossy) {
      args.addAll(['-b:a', '${options.bitrateKbps}k']);
    }
    if (options.title.isNotEmpty) {
      args.addAll(['-metadata', 'title=${options.title}']);
    }
    if (options.artist.isNotEmpty) {
      args.addAll(['-metadata', 'artist=${options.artist}']);
    }
    args.addAll(['-c:a', options.format.encoder, outputPath]);
    return args;
  }

  static Future<File> _uniqueOutputFile(
    Directory dir,
    String baseName,
    String ext,
  ) async {
    var candidate = File('${dir.path}/$baseName.$ext');
    var n = 2;
    while (await candidate.exists()) {
      candidate = File('${dir.path}/${baseName}_$n.$ext');
      n++;
    }
    return candidate;
  }

  static String baseNameOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }

  /// Transcode [input] to [options] and save the result in the
  /// converted-audio dir. [onProgress] gets 0.0–1.0 while ffmpeg
  /// runs (only when [inputDurationSec] is known). Throws an
  /// [Exception] with the ffmpeg tail log on failure — never a crash,
  /// never a silent skip: the screen shows the message.
  static Future<ConvertedFile> convertFile({
    required File input,
    required String inputName,
    required ConvertOptions options,
    double? inputDurationSec,
    bool stripVideo = false,
    bool adUnlocked = false,
    void Function(double progress)? onProgress,
  }) async {
    final size = await input.length();
    if (size > maxInputBytes) {
      throw Exception('File is too large — max 100 MB.');
    }
    if (size == 0) throw Exception('The picked file is empty.');
    final dir = await convertedDir();
    final outFile = await _uniqueOutputFile(
      dir,
      baseNameOf(inputName),
      options.format.ext,
    );
    final duration =
        inputDurationSec ?? await probeDurationSec(input);
    final args = buildArgs(
      inputPath: input.path,
      outputPath: outFile.path,
      options: options,
      inputDurationSec: duration,
      stripVideo: stripVideo,
    );

    final completer = Completer<FFmpegSession>();
    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (s) {
        if (!completer.isCompleted) completer.complete(s);
      },
      null,
      (stats) {
        if (duration != null && duration > 0 && onProgress != null) {
          final doneSec = stats.getTime() / 1000;
          onProgress((doneSec / duration).clamp(0.0, 1.0));
        }
      },
    );
    FFmpegSession doneSession;
    try {
      doneSession = await completer.future.timeout(
        const Duration(minutes: 10),
        onTimeout: () {
          unawaited(FFmpegKit.cancel(session.getSessionId()));
          throw TimeoutException(
            'Conversion timed out after 10 minutes.',
          );
        },
      );
    } on TimeoutException {
      rethrow;
    }
    final returnCode = await doneSession.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await doneSession.getOutput() ?? '';
      final tail = logs.length > 500
          ? logs.substring(logs.length - 500)
          : logs;
      if (await outFile.exists()) {
        try {
          await outFile.delete();
        } catch (_) {}
      }
      throw Exception(
        'ffmpeg failed (code ${returnCode?.getValue()}): $tail',
      );
    }
    if (!await outFile.exists()) {
      throw Exception('ffmpeg finished but no output file was created.');
    }
    final outSize = await outFile.length();
    if (outSize == 0) {
      throw Exception('ffmpeg produced an empty file.');
    }
    final outDuration =
        await probeDurationSec(outFile) ?? duration ?? 0;
    final bitrateLabel = options.format.isLossy
        ? '${options.bitrateKbps} kbps'
        : 'PCM 16-bit';
    return ConvertedFile(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      fileName: outFile.path.split('/').last,
      filePath: outFile.path,
      format: options.format.ext,
      bitrateLabel: bitrateLabel,
      sampleRateHz: options.sampleRateHz,
      channels: options.channels,
      durationSec: outDuration,
      sizeBytes: outSize,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      adUnlocked: adUnlocked,
    );
  }

  /// Video-to-audio: extract the audio track of [video] as an MP3
  /// (mockup: "MP4 se MP3 nikal lein") at the chosen bitrate /
  /// sample rate / channels. Same ffmpeg path as [convertFile] with
  /// `-vn` (no video stream in the output).
  static Future<ConvertedFile> extractAudioFromVideo({
    required File video,
    required String videoName,
    required ConvertOptions options,
    bool adUnlocked = false,
    void Function(double progress)? onProgress,
  }) async {
    final duration = await probeDurationSec(video);
    return convertFile(
      input: video,
      inputName: videoName,
      options: options.copyWith(format: ConvertFormat.mp3),
      inputDurationSec: duration,
      stripVideo: true,
      adUnlocked: adUnlocked,
      onProgress: onProgress,
    );
  }

  // ---- Converted-files history (SharedPreferences JSON) ----

  static Future<List<ConvertedFile>> loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(historyKey);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List;
      final items = list
          .map((e) => ConvertedFile.fromJson(e as Map<String, dynamic>))
          .where((f) => File(f.filePath).existsSync())
          .toList();
      return items;
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveHistory(List<ConvertedFile> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      historyKey,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  /// Prepend [file] to the history (newest first), capped at
  /// [maxHistoryEntries] — the oldest entry's file is deleted with
  /// it so converted audio cannot fill the phone silently.
  static Future<List<ConvertedFile>> addToHistory(
    ConvertedFile file,
  ) async {
    final items = await loadHistory();
    items.insert(0, file);
    while (items.length > maxHistoryEntries) {
      final dropped = items.removeLast();
      try {
        await File(dropped.filePath).delete();
      } catch (_) {}
    }
    await _saveHistory(items);
    return items;
  }

  /// Remove one history entry and delete its file.
  static Future<List<ConvertedFile>> removeFromHistory(
    String id,
  ) async {
    final items = await loadHistory();
    final match = items.where((f) => f.id == id).toList();
    for (final f in match) {
      try {
        await File(f.filePath).delete();
      } catch (_) {}
    }
    items.removeWhere((f) => f.id == id);
    await _saveHistory(items);
    return items;
  }

  // ---- Rewarded-ad unlock (fail-soft) for heavy features ----

  /// ONE rewarded ad BEFORE a heavy feature runs (batch convert,
  /// video-to-audio). Returns true when the feature may run, false
  /// only when the user SKIPPED / closed the ad early.
  ///
  /// Wired on [UnityAdsService] directly (not the download gate,
  /// whose fail/skip handling differs):
  /// - ads off / IDs not configured / rewarded disabled → true
  ///   (nothing to show — fail-soft, feature runs).
  /// - [UnityAdsService.loadRewardedAd] false (no fill / SDK not
  ///   ready) → true (fail-soft, feature runs).
  /// - [UnityAdsService.showRewardedAd] == completed → true.
  /// - == skipped → false + a short message (feature does NOT run).
  /// - == failed (show error / timeout) → true (fail-soft: "no ad
  ///   can be shown at all" must never break the app).
  ///
  /// The API CAN distinguish skipped from unavailable: load returns
  /// a bool, and show returns the [UnityAdResult] enum
  /// (completed / skipped / failed) — so this is exact, not a guess.
  static Future<bool> playUnlockAd(BuildContext context) async {
    final adsOn = UnityAdsService.adsEnabledNow &&
        RemoteConfigService.instance.config.rewardedEnabled &&
        UnityAdsService.adsConfigured;
    if (!adsOn) return true;
    await UnityAdsService.init();
    final loaded = await UnityAdsService.loadRewardedAd();
    if (!loaded) return true; // No ad available — run anyway.
    final result = await UnityAdsService.showRewardedAd();
    if (result == UnityAdResult.completed) return true;
    if (result == UnityAdResult.skipped) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ad poora dekhein — feature unlock nahi hua.'),
          ),
        );
      }
      return false;
    }
    return true; // failed / error — fail-soft, run anyway.
  }

  /// Download a converted file.
  ///
  /// - [ConvertedFile.adUnlocked] == true (batch / video-to-audio
  ///   run): the unlock ad IS this file's ad — download DIRECTLY
  ///   with no second ad, via [AudioDownloadService.downloadDirect]
  ///   (the converted file is wrapped as an [AudioItem] pointing at
  ///   the same path, so no bytes are copied twice).
  /// - Otherwise: the usual one-ad gate —
  ///   [AudioDownloadService.downloadBytesWithAd] (1 rewarded ad,
  ///   fail-soft when ads are off / no ad loads, skip = no delivery).
  static Future<void> downloadConverted(
    BuildContext context,
    ConvertedFile file,
  ) async {
    if (!await File(file.filePath).exists()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File not found — it may have been deleted.'),
          ),
        );
      }
      return;
    }
    if (file.adUnlocked) {
      if (!context.mounted) return;
      final base = baseNameOf(file.fileName);
      await AudioDownloadService.downloadDirect(
        context,
        AudioItem(
          id: base,
          title: file.fileName,
          text: '',
          voiceId: 'local',
          engine: 'local',
          filePath: file.filePath,
          ext: file.format,
          createdAtMs: file.createdAtMs,
        ),
      );
      return;
    }
    final bytes = await File(file.filePath).readAsBytes();
    if (!context.mounted) return;
    await AudioDownloadService.downloadBytesWithAd(
      context,
      fileName: file.fileName,
      bytes: bytes,
    );
  }
}
