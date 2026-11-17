import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/audio_item.dart';

/// One entry in the TTS Studio generation history.
///
/// History points at the file already saved in the audio library
/// ([AudioLibraryService] owns the file); deleting a history entry
/// only forgets the row — the file stays in My Audio. Re-download and
/// share rebuild an [AudioItem] from the entry, so they keep working
/// as long as the file still exists.
class TtsHistoryEntry {
  final String id;
  final String title;
  final String filePath;
  final String ext; // 'wav' | 'mp3'
  final String voiceId;
  final String voiceLabel;
  final String engine; // 'gemini' | 'edge'
  final int createdAtMs;
  final int charCount;
  final int coinsSpent;

  /// True when background music was mixed into this file.
  final bool musicUsed;

  /// True when a rewarded ad already paid for this file (the music
  /// unlock ad). Re-download then uses a direct download — NO second
  /// ad for the same file. False = the normal 1-ad download applies.
  final bool adPaid;

  /// First 200 chars of the source text (for display only).
  final String textSnippet;

  const TtsHistoryEntry({
    required this.id,
    required this.title,
    required this.filePath,
    required this.ext,
    required this.voiceId,
    required this.voiceLabel,
    required this.engine,
    required this.createdAtMs,
    required this.charCount,
    required this.coinsSpent,
    this.musicUsed = false,
    this.adPaid = false,
    this.textSnippet = '',
  });

  /// The library item this entry points at (for download / share).
  AudioItem get asAudioItem => AudioItem(
    id: id,
    title: title,
    text: textSnippet,
    voiceId: voiceId,
    engine: engine,
    filePath: filePath,
    ext: ext,
    createdAtMs: createdAtMs,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'filePath': filePath,
    'ext': ext,
    'voiceId': voiceId,
    'voiceLabel': voiceLabel,
    'engine': engine,
    'createdAtMs': createdAtMs,
    'charCount': charCount,
    'coinsSpent': coinsSpent,
    'musicUsed': musicUsed,
    'adPaid': adPaid,
    'textSnippet': textSnippet,
  };

  factory TtsHistoryEntry.fromJson(Map<String, dynamic> json) =>
      TtsHistoryEntry(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        filePath: json['filePath'] as String? ?? '',
        ext: json['ext'] as String? ?? 'wav',
        voiceId: json['voiceId'] as String? ?? 'aoede',
        voiceLabel: json['voiceLabel'] as String? ?? '',
        engine: json['engine'] as String? ?? 'gemini',
        createdAtMs: json['createdAtMs'] as int? ?? 0,
        charCount: json['charCount'] as int? ?? 0,
        coinsSpent: json['coinsSpent'] as int? ?? 0,
        musicUsed: json['musicUsed'] as bool? ?? false,
        adPaid: json['adPaid'] as bool? ?? false,
        textSnippet: json['textSnippet'] as String? ?? '',
      );

  factory TtsHistoryEntry.fromAudioItem(
    AudioItem item, {
    required String voiceLabel,
    required int charCount,
    required int coinsSpent,
    bool musicUsed = false,
    bool adPaid = false,
  }) {
    final text = item.text;
    return TtsHistoryEntry(
      id: item.id,
      title: item.title,
      filePath: item.filePath,
      ext: item.ext,
      voiceId: item.voiceId,
      voiceLabel: voiceLabel,
      engine: item.engine,
      createdAtMs: item.createdAtMs,
      charCount: charCount,
      coinsSpent: coinsSpent,
      musicUsed: musicUsed,
      adPaid: adPaid,
      textSnippet: text.length <= 200 ? text : text.substring(0, 200),
    );
  }
}

/// Generated-audio history for TTS Studio, persisted locally as JSON
/// in SharedPreferences (same pattern as the audio library's JSON
/// index). Newest first, capped at 50 entries.
class TtsHistoryService {
  static const String _key = 'ab_tts_history_v1';
  static const int maxEntries = 50;

  List<TtsHistoryEntry> _entries = [];
  bool _loaded = false;

  List<TtsHistoryEntry> get entries => List.unmodifiable(_entries);

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        _entries = list
            .map((e) => TtsHistoryEntry.fromJson(e as Map<String, dynamic>))
            .where((e) => e.id.isNotEmpty && e.filePath.isNotEmpty)
            .toList();
      }
    } catch (_) {
      _entries = [];
    }
    _loaded = true;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_entries.map((e) => e.toJson()).toList()),
    );
  }

  /// Record a freshly generated [AudioItem]. Newest first.
  Future<void> record(
    AudioItem item, {
    required String voiceLabel,
    required int charCount,
    required int coinsSpent,
    bool musicUsed = false,
    bool adPaid = false,
  }) async {
    await load();
    _entries.removeWhere((e) => e.id == item.id);
    _entries.insert(
      0,
      TtsHistoryEntry.fromAudioItem(
        item,
        voiceLabel: voiceLabel,
        charCount: charCount,
        coinsSpent: coinsSpent,
        musicUsed: musicUsed,
        adPaid: adPaid,
      ),
    );
    if (_entries.length > maxEntries) {
      _entries = _entries.sublist(0, maxEntries);
    }
    await _save();
  }

  /// Forget one entry (the audio file itself stays in My Audio).
  Future<void> remove(TtsHistoryEntry entry) async {
    await load();
    _entries.removeWhere((e) => e.id == entry.id);
    await _save();
  }

  Future<void> clear() async {
    await load();
    _entries = [];
    await _save();
  }
}
