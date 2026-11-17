import 'package:flutter/services.dart';

/// Receives text shared into the app from other apps (Android
/// ACTION_SEND, text/plain).
///
/// How it works (v1.0.10):
/// 1. AndroidManifest.xml declares an ACTION_SEND intent-filter
///    (text/plain) on MainActivity, so "Share → Magic Box From Jaani"
///    appears in other apps.
/// 2. MainActivity.kt stashes Intent.EXTRA_TEXT on launch / new intent
///    and serves it over the `nigraan.tts/share` MethodChannel
///    (`getSharedText`, one-shot — reading clears it).
/// 3. TTS Studio calls [takeSharedText] on start and whenever the app
///    is foregrounded, and pre-fills the text box with what it gets.
///
/// There is deliberately no plugin dependency for this: the native
/// side is ~20 lines in MainActivity.kt and this file is the Dart half.
/// main.dart is NOT touched — the channel is owned entirely by this
/// service and the TTS screen that reads it.
class SharedTextService {
  static const MethodChannel _channel = MethodChannel(
    'nigraan.tts/share',
  );

  /// Take the pending shared text, if any. Returns null when nothing
  /// was shared (or the channel is unavailable). One-shot: a second
  /// call returns null until new text is shared.
  static Future<String?> takeSharedText() async {
    try {
      final text = await _channel.invokeMethod<String>('getSharedText');
      if (text == null || text.trim().isEmpty) return null;
      return text;
    } catch (_) {
      // Channel missing (e.g. old build without the native half) —
      // sharing just does nothing instead of crashing.
      return null;
    }
  }
}
