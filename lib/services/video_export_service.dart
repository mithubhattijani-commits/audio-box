import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';

import 'ads_service.dart';
import 'remote_config_service.dart';

/// Burn-in quality for the video export (v1.0.10).
enum VideoExportQuality {
  p720,
  p1080;

  String get label => switch (this) {
        VideoExportQuality.p720 => '720p',
        VideoExportQuality.p1080 => '1080p',
      };

  /// Target height for a horizontal video / target width for a
  /// vertical one.
  int get target => switch (this) {
        VideoExportQuality.p720 => 720,
        VideoExportQuality.p1080 => 1080,
      };
}

/// Video dimensions + duration from ffprobe.
class VideoSize {
  const VideoSize({
    required this.width,
    required this.height,
    this.durationSeconds,
  });

  final int width;
  final int height;

  /// Media duration in seconds (from MediaInformation.getDuration()),
  /// null when ffprobe did not report one.
  final double? durationSeconds;

  bool get isVertical => height > width;

  /// ASS canvas for this video: portrait 1080x1920 for vertical
  /// video, landscape 1280x720 for horizontal.
  ({int x, int y}) get assCanvas =>
      isVertical ? (x: 1080, y: 1920) : (x: 1280, y: 720);
}

/// Result of one burn-in export attempt.
class VideoExportResult {
  const VideoExportResult({
    required this.success,
    this.outputPath,
    this.error,
  });

  final bool success;
  final String? outputPath;
  final String? error;
}

/// Outcome of the pre-export ad unlock (v1.0.10 ad rule).
enum VideoExportUnlock {
  /// The burn-in may run: the ad was watched fully, or no ad could
  /// be shown at all (ads off / SDK not ready / no fill / show
  /// failed) — fail-soft, the user is never blocked from their own
  /// video by an unavailable ad.
  allowed,

  /// The user skipped / closed the ad early — the burn-in must NOT
  /// run.
  denied,
}

/// On-device video export (v1.0.10): burns the styled ASS captions
/// INTO an MP4 with ffmpeg_kit_flutter_new (the maintained fork —
/// the abandoned ffmpeg_kit_flutter package is NOT used).
///
/// AD RULE (user, 17 Nov): ONE rewarded ad unlocks the export, shown
/// BEFORE the burn-in runs, and that same ad satisfies the export —
/// no second ad is shown at download for the same file. SRT/ASS
/// downloads keep their own 2-ad gate (unchanged, in the screens).
/// Fail-soft: skipped = no export + a short message; unavailable =
/// export runs anyway.
///
/// The ASS subtitles filter is tried first (full style: colours,
/// karaoke, outline, position). If it fails, a per-line drawtext
/// fallback runs instead. If both fail, the error (with the ffmpeg
/// log tail) is returned — never a silent skip, never a crash.
class VideoExportService {
  /// Read the video stream size (+ duration) with ffprobe. Null
  /// when the file cannot be probed — callers then fall back to the
  /// landscape canvas / horizontal scale.
  static Future<VideoSize?> probeVideoSize(File video) async {
    try {
      final session =
          await FFprobeKit.getMediaInformation(video.path);
      final info = session.getMediaInformation();
      final duration =
          double.tryParse(info?.getDuration() ?? '');
      final streams = info?.getStreams();
      if (streams == null) return null;
      for (final s in streams) {
        if (s.getType() == 'video') {
          final w = s.getWidth();
          final h = s.getHeight();
          if (w != null && h != null && w > 0 && h > 0) {
            return VideoSize(
              width: w,
              height: h,
              durationSeconds: duration,
            );
          }
        }
      }
    } catch (_) {
      // Probe failure: caller falls back to landscape.
    }
    return null;
  }

  /// Run one ffmpeg command asynchronously and wait for its
  /// completion callback. [onProgress] (0.0–1.0) fires from the
  /// statistics callback when [durationSeconds] is known.
  static Future<FFmpegSession> _execute(
    List<String> args, {
    void Function(double progress)? onProgress,
    double? durationSeconds,
  }) async {
    final done = Completer<FFmpegSession>();
    await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) {
        if (!done.isCompleted) done.complete(session);
      },
      null,
      (stats) {
        if (onProgress != null &&
            durationSeconds != null &&
            durationSeconds > 0) {
          onProgress(
            (stats.getTime() / 1000 / durationSeconds).clamp(0.0, 1.0),
          );
        }
      },
    );
    return done.future;
  }

  /// The ad-unlock gate for the video export. Shows ONE rewarded ad
  /// BEFORE the burn-in runs.
  ///
  /// Wired to [UnityAdsService.showRewardedAd], which returns a
  /// [UnityAdResult]: completed = watched fully, skipped = closed
  /// early, failed = the ad could not be shown. The API DOES
  /// distinguish "skipped" from "unavailable":
  /// - completed → allowed.
  /// - skipped → DENIED (burn-in does not run).
  /// - failed / not loaded / SDK not initialised / ads off → ALLOWED
  ///   (fail-soft: an unavailable ad never blocks the export).
  /// A load failure ([UnityAdsService.loadRewardedAd] false = no
  /// fill) is also treated as unavailable → allowed.
  static Future<VideoExportUnlock> requestUnlock() async {
    final adsOn = UnityAdsService.adsEnabledNow &&
        RemoteConfigService.instance.config.rewardedEnabled;
    if (!adsOn) return VideoExportUnlock.allowed;
    await UnityAdsService.init();
    if (!UnityAdsService.isInitialized) {
      return VideoExportUnlock.allowed; // SDK unavailable → fail-soft.
    }
    final loaded = await UnityAdsService.loadRewardedAd();
    if (!loaded) {
      return VideoExportUnlock.allowed; // No fill → fail-soft.
    }
    final result = await UnityAdsService.showRewardedAd();
    if (result == UnityAdResult.completed) {
      return VideoExportUnlock.allowed;
    }
    if (result == UnityAdResult.skipped) {
      return VideoExportUnlock.denied;
    }
    // failed to show (error after load) → unavailable → fail-soft.
    return VideoExportUnlock.allowed;
  }

  /// Burn [assContent] into [inputVideo] and write the captioned MP4
  /// to the phone's Download folder. No ad is shown here — the caller
  /// must have run [requestUnlock] first; the exported file is
  /// delivered directly (no second ad). [onProgress] fires 0.0–1.0
  /// while ffmpeg runs (only when ffprobe reported a duration).
  static Future<VideoExportResult> exportVideo({
    required File inputVideo,
    required String assContent,
    required VideoExportQuality quality,
    required String baseName,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final tmp = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final assFile = File('${tmp.path}/caption_burn_$stamp.ass');
      await assFile.writeAsString(assContent);

      final extDir = await getExternalStorageDirectory();
      final downloads = Directory('${extDir?.path}/Download');
      if (!await downloads.exists()) {
        await downloads.create(recursive: true);
      }
      final outPath =
          '${downloads.path}/${baseName}_captioned_${quality.label}.mp4';

      final size = await probeVideoSize(inputVideo);
      final vertical = size?.isVertical ?? false;
      final scale = vertical
          ? 'scale=${quality.target}:-2'
          : 'scale=-2:${quality.target}';
      final escapedAss = _escapeFilterPath(assFile.path);

      // Attempt 1: styled ASS burn-in (subtitles filter).
      var session = await _execute(
        [
          '-y',
          '-i',
          inputVideo.path,
          '-vf',
          '$scale,subtitles=$escapedAss',
          '-c:v',
          'libx264',
          '-preset',
          'veryfast',
          '-crf',
          '23',
          '-c:a',
          'copy',
          '-movflags',
          '+faststart',
          outPath,
        ],
        onProgress: onProgress,
        durationSeconds: size?.durationSeconds,
      );
      var rc = await session.getReturnCode();
      if (ReturnCode.isSuccess(rc)) {
        return VideoExportResult(success: true, outputPath: outPath);
      }
      final assLogs = await session.getAllLogsAsString() ?? '';

      // Attempt 2: drawtext fallback (one drawtext per line). The
      // style is plainer (no karaoke), but the captions still land
      // in the video instead of failing outright.
      final drawtextFilter = await _drawtextFilter(
        assContent: assContent,
        scale: scale,
        quality: quality,
        vertical: vertical,
      );
      if (drawtextFilter != null) {
        session = await _execute(
          [
            '-y',
            '-i',
            inputVideo.path,
            '-vf',
            drawtextFilter,
            '-c:v',
            'libx264',
            '-preset',
            'veryfast',
            '-crf',
            '23',
            '-c:a',
            'copy',
            '-movflags',
            '+faststart',
            outPath,
          ],
          onProgress: onProgress,
          durationSeconds: size?.durationSeconds,
        );
        rc = await session.getReturnCode();
        if (ReturnCode.isSuccess(rc)) {
          return VideoExportResult(success: true, outputPath: outPath);
        }
      }
      final logs = await session.getAllLogsAsString() ?? '';
      final tail = (assLogs.isNotEmpty ? assLogs : logs).trim();
      final shown = tail.length > 600
          ? tail.substring(tail.length - 600)
          : tail;
      return VideoExportResult(
        success: false,
        error: shown.isEmpty
            ? 'ffmpeg failed (no log output).'
            : 'ffmpeg failed: $shown',
      );
    } catch (e) {
      return VideoExportResult(success: false, error: e.toString());
    }
  }

  /// Escape a file path for use inside an ffmpeg filter argument:
  /// backslash, colon and single-quote all need escaping.
  static String _escapeFilterPath(String path) => path
      .replaceAll(r'\', r'\\')
      .replaceAll(':', r'\:')
      .replaceAll("'", r"\'");

  /// Build the drawtext fallback filter from the ASS text: parses the
  /// Dialogue lines back out of [assContent] (start/end/text) and
  /// makes one drawtext per line. Null when no lines parse.
  static Future<String?> _drawtextFilter({
    required String assContent,
    required String scale,
    required VideoExportQuality quality,
    required bool vertical,
  }) async {
    final lines = <({double start, double end, String text})>[];
    for (final raw in assContent.split('\n')) {
      final line = raw.trim();
      if (!line.startsWith('Dialogue:')) continue;
      final parts = line.substring('Dialogue:'.length).split(',');
      // Dialogue: Layer, Start, End, Style, Name, MarginL, MarginR,
      // MarginV, Effect, Text (text may itself contain commas).
      if (parts.length < 10) continue;
      final start = _assSeconds(parts[1].trim());
      final end = _assSeconds(parts[2].trim());
      final text = parts.sublist(9).join(',').trim();
      if (start == null || end == null || text.isEmpty) continue;
      final clean = text
          .replaceAll(RegExp(r'\{[^}]*\}'), '')
          .replaceAll(r'\N', ' ')
          .trim();
      if (clean.isNotEmpty) {
        lines.add((start: start, end: end, text: clean));
      }
    }
    if (lines.isEmpty) return null;

    final fontFile = await _findFontFile();
    final fontSize = vertical
        ? (quality == VideoExportQuality.p1080 ? 84 : 56)
        : (quality == VideoExportQuality.p1080 ? 72 : 48);
    final yPos = quality == VideoExportQuality.p1080 ? 'h-260' : 'h-160';
    final filters = <String>[scale];
    for (final l in lines) {
      final text = l.text
          .replaceAll(r'\', r'\\')
          .replaceAll(':', r'\:')
          .replaceAll("'", r"\'")
          .replaceAll('%', r'\%');
      final fontPart = fontFile != null
          ? "fontfile='$_escapeFilterPath(fontFile)'"
          : 'font=sans-serif';
      filters.add(
        "drawtext=text='$text':$fontPart:fontsize=$fontSize:"
        "fontcolor=white:borderw=2:bordercolor=black:"
        "x=(w-text_w)/2:y=$yPos:box=1:boxcolor=black@0.5:"
        "enable='between(t,${l.start},${l.end})'",
      );
    }
    return filters.join(',');
  }

  static double? _assSeconds(String stamp) {
    // H:MM:SS.cc
    final parts = stamp.split(':');
    if (parts.length != 3) return null;
    final h = double.tryParse(parts[0]);
    final m = double.tryParse(parts[1]);
    final s = double.tryParse(parts[2]);
    if (h == null || m == null || s == null) return null;
    return h * 3600 + m * 60 + s;
  }

  /// Best system font for drawtext on Android (Urdu-capable first).
  /// Null when none of the known paths exists — the caller then uses
  /// fontconfig's sans-serif instead.
  static Future<String?> _findFontFile() async {
    const candidates = [
      '/system/fonts/NotoNaskhArabic-Regular.ttf',
      '/system/fonts/NotoNastaliqUrdu-Regular.ttf',
      '/system/fonts/DroidSans.ttf',
      '/system/fonts/Roboto-Regular.ttf',
    ];
    for (final path in candidates) {
      try {
        if (await File(path).exists()) return path;
      } catch (_) {}
    }
    return null;
  }
}
