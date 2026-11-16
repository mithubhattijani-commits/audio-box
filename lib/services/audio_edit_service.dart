import 'dart:io';
import 'dart:typed_data';

import 'caption_service.dart';
import 'mp3_utils.dart';
import 'wav_utils.dart';

/// Audio Trimmer & Joiner — fully on-device (v1.0.8, free).
///
/// WAV: sample-accurate trim + join (same format required on join).
/// MP3: frame-accurate trim + join (frames are self-contained, so
/// joining is a plain concatenation). Other formats (m4a/aac/ogg/flac)
/// are NOT supported on-device — the screen only offers wav/mp3, and
/// the error here says so plainly. No server, no paid API, no ffmpeg.
///
/// Inputs are capped at 50 MB so a huge file cannot exhaust the
/// phone's memory (all work is in-memory byte slices).
class AudioEditService {
  static const int maxFileBytes = 50 * 1024 * 1024;

  static const List<String> supportedExtensions = ['wav', 'mp3'];

  static String extensionOf(String path) =>
      path.split('.').last.toLowerCase();

  static bool isSupported(String path) =>
      supportedExtensions.contains(extensionOf(path));

  /// Fast duration from the file's own frames/headers (no player).
  /// Falls back to the caption service's player-based probe.
  static Future<Duration?> probeDuration(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final ext = extensionOf(file.path);
      if (ext == 'wav') {
        final wav = parseWav(bytes);
        if (wav != null) {
          return Duration(
            milliseconds: (wav.durationSeconds * 1000).round(),
          );
        }
      } else if (ext == 'mp3') {
        final seconds = mp3DurationSeconds(bytes);
        if (seconds > 0) {
          return Duration(milliseconds: (seconds * 1000).round());
        }
      }
    } catch (_) {
      // Fall through to the player-based probe.
    }
    return CaptionService.probeMediaDuration(file);
  }

  static Future<Uint8List> _readChecked(File file) async {
    final size = await file.length();
    if (size > maxFileBytes) {
      throw Exception('File is too large — max 50 MB.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) throw Exception('The picked file is empty.');
    return bytes;
  }

  /// Trim [start]..[end] out of [file] and return the new file bytes.
  /// The extension of the output matches the input.
  static Future<Uint8List> trim(
    File file,
    Duration start,
    Duration end,
  ) async {
    final bytes = await _readChecked(file);
    final ext = extensionOf(file.path);
    if (start >= end) throw Exception('Pick an end after the start.');
    if (ext == 'wav') {
      return sliceWav(
        bytes,
        start.inMilliseconds / 1000,
        end.inMilliseconds / 1000,
      );
    }
    if (ext == 'mp3') {
      return trimMp3(
        bytes,
        start.inMilliseconds / 1000,
        end.inMilliseconds / 1000,
      );
    }
    throw Exception(
      'Trim works for WAV and MP3 only — this is a .$ext file.',
    );
  }

  /// Join [files] end to end (in the given order) and return the new
  /// file bytes. All files must be the same format (all WAV or all
  /// MP3); WAV files must also share sample rate / channels / bit
  /// depth. Returns the output bytes; the caller picks the extension
  /// from the first file.
  static Future<Uint8List> join(List<File> files) async {
    if (files.isEmpty) throw Exception('Pick at least one file to join.');
    if (files.length == 1) {
      return _readChecked(files.first);
    }
    final exts = files.map((f) => extensionOf(f.path)).toSet();
    if (exts.length != 1) {
      throw Exception(
        'Join needs all files in the same format — picked: '
        '${exts.join(', ')}.',
      );
    }
    final ext = exts.first;
    final byteList = <Uint8List>[];
    for (final file in files) {
      byteList.add(await _readChecked(file));
    }
    if (ext == 'wav') return concatWav(byteList);
    if (ext == 'mp3') return concatMp3(byteList);
    throw Exception(
      'Join works for WAV and MP3 only — picked .$ext files.',
    );
  }
}
