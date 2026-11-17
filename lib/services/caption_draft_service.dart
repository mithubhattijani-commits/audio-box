import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'caption_service.dart';

/// Draft auto-save for the caption tools (v1.0.10).
///
/// While the user edits captions, the screen saves its state
/// (segments incl. word timings + translations, style choices, FX,
/// dual-language flag, picked file path) to SharedPreferences every
/// time it changes (debounced by the caller). Reopening the screen
/// restores the draft when the picked file still exists on the phone,
/// so work survives the app being closed mid-edit. Drafts are plain
/// local JSON — no coins, no ads, no network. Clearing happens when
/// the user starts a fresh file or the draft's file is gone.
class CaptionDraftService {
  static String _key(String screenKey) => 'caption_draft_$screenKey';

  /// Save a draft for [screenKey] ('video_caption_maker' or
  /// 'caption_generator'). [data] must be JSON-encodable.
  static Future<void> saveDraft(
    String screenKey,
    Map<String, dynamic> data,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(screenKey), jsonEncode(data));
    } catch (_) {
      // Draft save is best-effort — never break the editor.
    }
  }

  /// Load the saved draft for [screenKey], or null when there is
  /// none / it is corrupt.
  static Future<Map<String, dynamic>?> loadDraft(String screenKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(screenKey));
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Corrupt draft: treat as no draft.
    }
    return null;
  }

  /// Delete the draft for [screenKey].
  static Future<void> clearDraft(String screenKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key(screenKey));
    } catch (_) {}
  }

  /// Encode one caption draft from its parts. Segments keep their
  /// word timings and dual-language translations so a restored draft
  /// keeps real karaoke timing.
  static Map<String, dynamic> encodeDraft({
    required String filePath,
    required String fileName,
    required String lang,
    required List<CaptionSegment> segments,
    required String styleId,
    required String position,
    required String size,
    required int highlightColor,
    required String fontId,
    required bool outline,
    required bool shadow,
    required bool background,
    required bool dualLanguage,
    required String presetId,
    required int selectedIndex,
  }) {
    return {
      'filePath': filePath,
      'fileName': fileName,
      'lang': lang,
      'segments': segments.map((s) => s.toJson()).toList(),
      'styleId': styleId,
      'position': position,
      'size': size,
      'highlightColor': highlightColor,
      'fontId': fontId,
      'outline': outline,
      'shadow': shadow,
      'background': background,
      'dualLanguage': dualLanguage,
      'presetId': presetId,
      'selectedIndex': selectedIndex,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// Decode the segments list out of a loaded draft map.
  static List<CaptionSegment> decodeSegments(Map<String, dynamic> draft) {
    final raw = draft['segments'];
    final out = <CaptionSegment>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          try {
            out.add(CaptionSegment.fromJson(e));
          } catch (_) {
            // Skip one bad line; keep the rest.
          }
        } else if (e is Map) {
          try {
            out.add(
              CaptionSegment.fromJson(
                e.map((k, v) => MapEntry(k.toString(), v)),
              ),
            );
          } catch (_) {}
        }
      }
    }
    return out;
  }
}
