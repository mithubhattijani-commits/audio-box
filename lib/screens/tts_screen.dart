import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/audio_item.dart';
import '../models/tts_voice.dart';
import '../services/ads_service.dart';
import '../services/audio_download_service.dart';
import '../services/audio_library_service.dart';
import '../services/coins_service.dart';
import '../services/mp3_utils.dart';
import '../services/remote_config_service.dart';
import '../services/shared_text_service.dart';
import '../services/tts_history_service.dart';
import '../services/tts_processing.dart';
import '../services/tts_service.dart';
import '../services/wav_utils.dart';
import '../widgets/audio_player_bar.dart';

/// TTS Studio (v1.0.10, white interface per the approved mockup):
/// type text, pick a voice, generate audio.
///
/// - Cost: coinsPerMinute (remote config, default 50) per ~1-minute
///   chunk. Repeat generations of the same text + voice are free
///   (on-device cache). Daily cap (remote config tts.daily_cap,
///   default 10/day) is enforced — one tap = one generation.
/// - Long text auto-splits at sentence boundaries (chunkText) and the
///   parts are joined into ONE file (WAV: concatWav, MP3: concatMp3;
///   mixed Gemini+Edge-fallback parts go through ffmpeg to WAV first).
/// - If Gemini fails (quota/429), the generation automatically falls
///   back to the same-gender free Edge voice.
/// - Speed also changes the pitch (resample) — the UI says so plainly.
///   Pitch-only control is NOT possible (needs a phase vocoder).
/// - Voice previews cost NO coins: one short proxy call per voice per
///   install, cached locally under tts_previews/ (it does use a little
///   Gemini quota the first time each voice is previewed).
/// - Background music: an on-device generated soft pad mixed under the
///   voice. The mix is AD-UNLOCKED (1 rewarded ad, fail-soft — see
///   [_unlockMusicMix]); the unlock ad IS the ad for that file, so its
///   download shows NO second ad. No ad is ever added to the
///   coin-charged generation itself.
///
/// Download of a generated file = 1 rewarded ad, fail-soft (via
/// [AudioDownloadService.downloadWithAd]), except when the music
/// unlock ad already paid for that file (then a direct download).
class TtsScreen extends StatefulWidget {
  final CoinsService coins;
  final AudioLibraryService library;
  final ValueNotifier<Locale> appLocale;
  final String initialText;
  final String initialLang;

  const TtsScreen({
    super.key,
    required this.coins,
    required this.library,
    required this.appLocale,
    this.initialText = '',
    this.initialLang = 'ur',
  });

  @override
  State<TtsScreen> createState() => _TtsScreenState();
}

/// Outcome of the background-music ad unlock (v1.0.10, user rule
/// 17 Nov 2026: 1 rewarded ad before the music mix, fail-soft).
enum _MusicUnlock {
  /// Ad watched fully — mix runs, and the unlock ad IS the ad for
  /// this file (no second ad at download).
  allowedWithAd,

  /// No ad could be shown (ads off / not configured / no fill /
  /// error) — mix runs anyway (fail-soft).
  allowedNoAd,

  /// User skipped / closed the ad early — mix does NOT run; generate
  /// without music instead and tell the user.
  skipped,
}

class _ChunkBytes {
  final Uint8List bytes;
  final String ext; // 'wav' | 'mp3'
  const _ChunkBytes(this.bytes, this.ext);
}

/// Tone presets: speed + pause-between-sentences combos.
class _TonePreset {
  final String name;
  final double speed;
  final double pauseSeconds;
  const _TonePreset(this.name, this.speed, this.pauseSeconds);
}

const _tonePresets = [
  _TonePreset('News', 1.0, 0.2),
  _TonePreset('Story', 0.9, 0.5),
  _TonePreset('Ad', 1.15, 0.1),
];

const _speedChips = [0.75, 1.0, 1.25, 1.5, 2.0];

const _urduPreviewSample =
    'Assalam-o-Alaikum, main Nigraan TV se bol raha hoon. '
    'Ye meri awaz ka sample hai.';
const _englishPreviewSample =
    'Hello, this is a voice sample from Nigraan TV.';

const _newsSample =
    'Islamabad: Wazir-e-Azam ne aaj qom se khitab mein kaha ke mulk '
    'ki maeeshat behtari ki taraf ja rahi hai. Unhon ne kaha ke '
    'mehngai mein kami aur rozgar ke naye mawaqe paida karna hukumat '
    'ki pehli tarjeeh hai. Awam ko sahulat dene ke liye naye '
    'mansubon ka elaan jald kiya jayega.';
const _storySample =
    'Chhota sa gaon, bare khwab. Ali roz subah apni cycle par school '
    'jata tha — chahe barish ho ya dhoop. Ustaad kehte the, mehnat '
    'kabhi zaya nahi hoti. Aaj Ali usi gaon ka pehla doctor hai, aur '
    'har bacha us jaisa banna chahta hai.';
const _adSample =
    'Nigraan TV — khabar, sab se pehle, sab se sahi! Taza tareen '
    'khabrain, dilchasp program aur apki awaz — sab kuch aik jagah. '
    'Abhi Nigraan TV ko follow karein aur har khabar se bakhabar rahein!';

class _TtsScreenState extends State<TtsScreen>
    with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();
  final TtsService _tts = TtsService();
  final TtsHistoryService _history = TtsHistoryService();

  TtsVoice _voice = TtsVoice.byId('aoede');

  /// 'auto' | 'ur' | 'en'. Auto detects from the text (Urdu script →
  /// Urdu, else English) and shows the detected language.
  String _langMode = 'auto';
  bool _busy = false;
  String? _note;
  List<AudioItem> _results = [];

  /// "MP3 • Billo • 00:38 • 1.0 MB" per result item id.
  final Map<String, String> _resultMeta = {};

  /// True when a rewarded ad already paid for this file (music unlock)
  /// — its download is direct, no second ad.
  final Map<String, bool> _adPaidByItemId = {};

  // v1.0.8 — voice controls (on-device WAV processing, free):
  // speed (resample) + pause between sentences (silence). Apply to
  // Gemini voices only (WAV); Edge voices return MP3 and ignore them.
  double _speed = 1.0;
  double _pauseSeconds = 0.0;
  String? _tone; // 'News' | 'Story' | 'Ad' | null (custom)

  /// 'mp3' | 'wav' — the download format for the generated audio.
  String _format = 'mp3';

  /// Background music under the voice (off by default).
  bool _musicOn = false;

  bool _showAllVoices = false;
  bool _showAllHistory = false;

  // Voice preview playback (one player; cached sample per voice).
  final AudioPlayer _previewPlayer = AudioPlayer();
  String? _previewingVoiceId;
  String? _previewLoadingVoiceId;

  // History playback (one player).
  final AudioPlayer _historyPlayer = AudioPlayer();
  String? _historyPlayingId;

  TtsControls get _controls =>
      TtsControls(speed: _speed, pauseSeconds: _pauseSeconds);

  /// Effective language for generation / preview: the chosen one, or
  /// the auto-detected one when mode is Auto.
  String get _effectiveLang => _langMode == 'auto'
      ? TtsService.detectLanguage(_textController.text)
      : _langMode;

  TtsVoice get _effectiveVoice => _voice;

  bool get _isEdgeVoice => _effectiveVoice.engine == TtsEngine.edge;

  /// Live cost estimate while typing (real chunking × coins/minute).
  int get _estimatedCost => TtsService.estimatedCostCoins(
    _textController.text,
    _effectiveVoice,
    widget.coins.coinsPerMinute,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _textController.text = widget.initialText;
    _langMode = widget.initialLang == 'en' ? 'en' : 'auto';
    _textController.addListener(_onTextChanged);
    _previewPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _previewingVoiceId = null);
    });
    _historyPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _historyPlayingId = null);
    });
    unawaited(_history.load().then((_) {
      if (mounted) setState(() {});
    }));
    unawaited(_checkSharedText());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkSharedText());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    _previewPlayer.dispose();
    _historyPlayer.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    // Refresh the counter, live cost and detected language.
    if (mounted) setState(() {});
  }

  /// Text shared into the app from another app (ACTION_SEND): pre-fill
  /// the text box. One-shot — the native side clears it on read.
  Future<void> _checkSharedText() async {
    final shared = await SharedTextService.takeSharedText();
    if (shared == null || !mounted) return;
    setState(() {
      _textController.text = shared.trim();
      _note = 'Shared text loaded into TTS Studio.';
    });
  }

  void _applyTone(_TonePreset preset) {
    setState(() {
      _tone = preset.name;
      _speed = preset.speed;
      _pauseSeconds = preset.pauseSeconds;
    });
  }

  void _setSpeed(double value) {
    setState(() {
      _speed = value;
      _tone = null; // Manual change = custom tone.
    });
  }

  void _setPause(double value) {
    setState(() {
      _pauseSeconds = value;
      _tone = null;
    });
  }

  void _fillSample(String sample) {
    setState(() {
      _textController.text = sample;
      _note = null;
    });
  }

  Future<void> _importTxt() async {
    try {
      // file_picker 13.x: FilePicker.pickFiles returns the picked
      // files directly (empty list = cancelled); there is no
      // FilePicker.platform / FilePickerResult any more.
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt'],
      );
      if (files.isEmpty) return;
      final picked = files.single;
      String content;
      if (picked.path != null) {
        content = await File(picked.path!).readAsString();
      } else {
        // No local path (e.g. web/blob) — read the bytes directly.
        content = utf8.decode(await picked.readAsBytes());
      }
      if (!mounted) return;
      if (content.trim().isEmpty) {
        setState(() => _note = 'That .txt file is empty.');
        return;
      }
      setState(() {
        _textController.text = content.trim();
        _note = null;
      });
    } catch (e) {
      if (mounted) setState(() => _note = 'Import failed: $e');
    }
  }

  // -----------------------------------------------------------------
  // Voice preview (feature 1): free, cached per voice per install.
  // -----------------------------------------------------------------

  Future<void> _playPreview(TtsVoice voice) async {
    if (_previewLoadingVoiceId != null) return;
    if (_previewingVoiceId == voice.id) {
      await _previewPlayer.stop();
      if (mounted) setState(() => _previewingVoiceId = null);
      return;
    }
    setState(() => _previewLoadingVoiceId = voice.id);
    try {
      final lang = _effectiveLang;
      final dir = await getApplicationDocumentsDirectory();
      final prevDir = Directory('${dir.path}/tts_previews');
      if (!await prevDir.exists()) {
        await prevDir.create(recursive: true);
      }
      File? cached;
      for (final ext in const ['wav', 'mp3']) {
        final f = File('${prevDir.path}/${voice.id}_$lang.$ext');
        if (await f.exists()) cached = f;
      }
      final File file;
      if (cached != null) {
        file = cached;
      } else {
        // One short proxy call per voice per install, cached locally.
        // NO coins are charged for previews (no spend, no
        // recordGeneration). If Gemini is busy the call falls back to
        // the same-gender Edge voice, so a preview still plays.
        final sample = lang == 'ur'
            ? _urduPreviewSample
            : _englishPreviewSample;
        final gen = await _tts.generateChunkWithFallback(
          sample,
          voice,
          lang: lang,
        );
        file = File('${prevDir.path}/${voice.id}_$lang.${gen.ext}');
        await file.writeAsBytes(gen.bytes);
      }
      await _previewPlayer.stop();
      await _previewPlayer.play(DeviceFileSource(file.path));
      if (mounted) setState(() => _previewingVoiceId = voice.id);
    } catch (e) {
      if (mounted) setState(() => _note = 'Preview failed: $e');
    } finally {
      if (mounted) setState(() => _previewLoadingVoiceId = null);
    }
  }

  // -----------------------------------------------------------------
  // Background-music ad unlock (v1.0.10, user rule 17 Nov 2026).
  // -----------------------------------------------------------------

  /// Show ONE rewarded ad BEFORE the music mix runs. Returns what
  /// happened so the caller can act on it:
  /// - completed → mix runs, ad counts for this file (no 2nd ad at
  ///   download);
  /// - skipped → mix does NOT run (generate without music, tell user);
  /// - unavailable (ads off / not configured / no fill / error) →
  ///   mix runs anyway (fail-soft).
  ///
  /// Wired on [UnityAdsService.loadRewardedAd] + [showRewardedAd],
  /// which return the real outcome ([UnityAdResult.completed] /
  /// .skipped / .failed). [UnityAdsService.showNRewardedAds] is NOT
  /// used here: it returns only bool, so it cannot tell "skipped"
  /// apart from "unavailable", and the rule needs them apart.
  Future<_MusicUnlock> _unlockMusicMix() async {
    final adsOn =
        UnityAdsService.adsEnabledNow &&
        RemoteConfigService.instance.config.rewardedEnabled &&
        UnityAdsService.adsConfigured;
    if (!adsOn) return _MusicUnlock.allowedNoAd;
    await UnityAdsService.init();
    final loaded = await UnityAdsService.loadRewardedAd();
    if (!loaded) return _MusicUnlock.allowedNoAd; // No fill — fail-soft.
    final result = await UnityAdsService.showRewardedAd();
    if (result == UnityAdResult.completed) {
      return _MusicUnlock.allowedWithAd;
    }
    if (result == UnityAdResult.skipped) return _MusicUnlock.skipped;
    return _MusicUnlock.allowedNoAd; // Failed — fail-soft.
  }

  // -----------------------------------------------------------------
  // Generation (features 3, 4, 10, 11): split, join, music, format.
  // -----------------------------------------------------------------

  /// Cached bytes for one chunk, if already generated (cache file in
  /// either ext — a Gemini chunk may have fallen back to Edge MP3 —
  /// or the matching library item when controls are default).
  Future<_ChunkBytes?> _cachedChunk(
    String chunk,
    TtsVoice voice,
    String lang,
  ) async {
    for (final ext in const ['wav', 'mp3']) {
      final f = await TtsService.cacheFile(
        chunk,
        voice,
        lang,
        ext,
        speed: _speed,
        pauseSeconds: _pauseSeconds,
      );
      if (await f.exists()) {
        return _ChunkBytes(await f.readAsBytes(), ext);
      }
    }
    if (_controls.isDefault) {
      final existing = widget.library.items
          .where((e) => e.text == chunk && e.voiceId == voice.id)
          .toList();
      if (existing.isNotEmpty) {
        final file = File(existing.first.filePath);
        if (await file.exists()) {
          return _ChunkBytes(await file.readAsBytes(), existing.first.ext);
        }
      }
    }
    return null;
  }

  Future<void> _generate() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _busy) return;
    final voice = _effectiveVoice;
    final lang = _effectiveLang;

    if (!widget.coins.canGenerate) {
      setState(() => _note = 'Daily limit reached (10 generations/day).');
      return;
    }
    await widget.library.load();
    final chunks = TtsService.chunkText(text, voice);
    if (chunks.isEmpty) return;

    // Cached chunks are free: only uncached chunks cost coins.
    // The cache key includes the voice controls, so a 1.25x file is
    // never confused with the 1.0x file of the same text.
    var uncached = 0;
    for (final chunk in chunks) {
      if (await _cachedChunk(chunk, voice, lang) == null) uncached++;
    }
    final cost = uncached * widget.coins.coinsPerMinute;
    if (cost > 0 && !widget.coins.canAfford(cost)) {
      setState(() => _note = 'Not enough coins for this audio.');
      return;
    }

    setState(() {
      _busy = true;
      _note = null;
      _results = [];
    });
    var fellBack = false;
    final generated = <AudioItem>[];
    var spent = false;
    String? note;
    try {
      if (cost > 0) {
        final ok = await widget.coins.spend(cost);
        if (!ok) {
          if (mounted) {
            setState(() => _note = 'Not enough coins for this audio.');
          }
          return;
        }
        spent = true;
      }

      // 1. Generate (or reuse) every part.
      final partBytes = <Uint8List>[];
      final partExts = <String>[];
      for (final chunk in chunks) {
        final cached = await _cachedChunk(chunk, voice, lang);
        Uint8List bytes;
        String ext;
        if (cached != null) {
          bytes = cached.bytes;
          ext = cached.ext;
        } else {
          final gen = await _tts.generateChunkWithFallback(
            chunk,
            voice,
            lang: lang,
          );
          if (gen.fellBackToEdge) fellBack = true;
          bytes = gen.bytes;
          ext = gen.ext;
          // Voice controls (v1.0.8): speed + pauses are applied to
          // the Gemini WAV here, on-device, before saving. Edge MP3
          // output skips them (no decoder on-device).
          if (ext == 'wav' && !_controls.isDefault) {
            bytes = applyTtsControls(bytes, text: chunk, controls: _controls);
          }
          final cacheFile = await TtsService.cacheFile(
            chunk,
            voice,
            lang,
            ext,
            speed: _speed,
            pauseSeconds: _pauseSeconds,
          );
          await cacheFile.writeAsBytes(bytes);
        }
        partBytes.add(bytes);
        partExts.add(ext);
      }

      // 2. Join the parts into ONE file.
      AudioItem? joinedItem;
      var musicApplied = false;
      var musicAdPaid = false;
      try {
        Uint8List joinedBytes;
        String joinedExt;
        if (partExts.every((e) => e == 'wav')) {
          joinedBytes = concatWav(partBytes);
          joinedExt = 'wav';
        } else if (partExts.every((e) => e == 'mp3')) {
          joinedBytes = concatMp3(partBytes);
          joinedExt = 'mp3';
        } else {
          // Mixed (some parts fell back to Edge MP3): convert the MP3
          // parts to WAV with ffmpeg, then join as WAV.
          final wavParts = <Uint8List>[];
          for (var i = 0; i < partBytes.length; i++) {
            wavParts.add(
              partExts[i] == 'wav'
                  ? partBytes[i]
                  : await convertAudioBytes(
                      partBytes[i],
                      fromExt: 'mp3',
                      toExt: 'wav',
                    ),
            );
          }
          joinedBytes = concatWav(wavParts);
          joinedExt = 'wav';
        }

        // 3. Background music (ad-unlocked, fail-soft).
        if (_musicOn) {
          final unlock = await _unlockMusicMix();
          if (unlock == _MusicUnlock.skipped) {
            note = 'Ad skipped — generated without background music.';
          } else {
            try {
              joinedBytes = joinedExt == 'wav'
                  ? mixWavWithMusic(joinedBytes)
                  : await mixMp3WithMusic(joinedBytes);
              musicApplied = true;
              musicAdPaid = unlock == _MusicUnlock.allowedWithAd;
            } catch (_) {
              note = 'Background music failed — saved without music.';
            }
          }
        }

        // 4. Download format (MP3 / WAV) via on-device ffmpeg.
        if (joinedExt != _format) {
          try {
            joinedBytes = await convertAudioBytes(
              joinedBytes,
              fromExt: joinedExt,
              toExt: _format,
            );
            joinedExt = _format;
          } catch (_) {
            note =
                'Could not convert to ${_format.toUpperCase()} — saved '
                'as ${joinedExt.toUpperCase()} instead.';
          }
        }

        joinedItem = await widget.library.save(
          title: _titleFor(text),
          text: text,
          voice: voice,
          bytes: joinedBytes,
          ext: joinedExt,
        );
        generated.add(joinedItem);
        _adPaidByItemId[joinedItem.id] = musicAdPaid;
        _resultMeta[joinedItem.id] =
            '${joinedExt.toUpperCase()} • ${voice.label} • '
            '${formatDuration(audioDurationSeconds(joinedBytes, joinedExt))} • '
            '${formatAudioSize(joinedBytes.length)}';
        await _history.record(
          joinedItem,
          voiceLabel: voice.label,
          charCount: text.length,
          coinsSpent: cost,
          musicUsed: musicApplied,
          adPaid: musicAdPaid,
        );
        await widget.coins.recordGeneration();
      } catch (_) {
        // Join failed: fall back to saving each part separately.
        generated.clear();
        for (var i = 0; i < partBytes.length; i++) {
          final item = await widget.library.save(
            title: _titleFor(text),
            text: chunks[i],
            voice: voice,
            bytes: partBytes[i],
            ext: partExts[i],
            chunkIndex: i + 1,
            chunkCount: partBytes.length,
          );
          generated.add(item);
          await _history.record(
            item,
            voiceLabel: voice.label,
            charCount: chunks[i].length,
            coinsSpent: cost,
            musicUsed: false,
            adPaid: false,
          );
          await widget.coins.recordGeneration();
        }
        note =
            'Long audio saved as ${generated.length} parts (join failed).';
      }

      if (mounted) {
        setState(() {
          _results = generated;
          _note = note ??
              (fellBack
                  ? 'Gemini was busy — generated with the free Edge voice instead.'
                  : null);
        });
      }
    } catch (e) {
      // Refund the spend when nothing was generated.
      if (spent && generated.isEmpty && cost > 0) {
        await widget.coins.add(cost, reason: 'generation_failed_refund');
      }
      if (mounted) {
        setState(() => _note = 'Generation failed: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _titleFor(String text) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= 40 ? t : '${t.substring(0, 40)}…';
  }

  // -----------------------------------------------------------------
  // Result / history actions.
  // -----------------------------------------------------------------

  /// Download a result: direct when a rewarded ad already paid for
  /// this file (music unlock), else the normal 1-ad download gate.
  Future<void> _downloadResult(AudioItem item) async {
    if (_adPaidByItemId[item.id] == true) {
      await AudioDownloadService.downloadDirect(context, item);
    } else {
      await AudioDownloadService.downloadWithAd(context, item);
    }
  }

  Future<void> _downloadHistory(TtsHistoryEntry entry) async {
    final file = File(entry.filePath);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File no longer on this device.')),
      );
      return;
    }
    if (entry.adPaid) {
      if (!mounted) return;
      await AudioDownloadService.downloadDirect(context, entry.asAudioItem);
    } else {
      if (!mounted) return;
      await AudioDownloadService.downloadWithAd(context, entry.asAudioItem);
    }
  }

  Future<void> _shareItem(AudioItem item) async {
    await AudioDownloadService.share(context, item);
  }

  Future<void> _toggleHistoryPlay(TtsHistoryEntry entry) async {
    if (_historyPlayingId == entry.id) {
      await _historyPlayer.stop();
      if (mounted) setState(() => _historyPlayingId = null);
      return;
    }
    final file = File(entry.filePath);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File no longer on this device.')),
      );
      return;
    }
    try {
      await _historyPlayer.stop();
      await _historyPlayer.play(DeviceFileSource(file.path));
      if (mounted) setState(() => _historyPlayingId = entry.id);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not play this audio.')),
      );
    }
  }

  String _dateLabel(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.day}/${dt.month}/${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  // -----------------------------------------------------------------
  // UI (white interface per the approved mockup).
  // -----------------------------------------------------------------

  Color get _red => Theme.of(context).colorScheme.primary;

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
    );
  }

  Widget _choiceChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _red : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? _red : Colors.grey.shade300,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.black87,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _whiteCard({required Widget child}) {
    return Card(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: child,
      ),
    );
  }

  String _engineLabel(TtsVoice voice) {
    // Short voice label under the name (as in the mockup).
    // NOTE: the 15 Nov rule said "no provider/model names in the UI";
    // the approved 17 Nov TTS mockup itself shows Aoede / Charon /
    // "Urdu Neural" under the voice names, so the mockup wins here.
    if (voice.engine == TtsEngine.gemini) return voice.apiVoice;
    return 'Urdu Neural';
  }

  Widget _voiceCard(TtsVoice voice) {
    final selected = _voice.id == voice.id;
    final isPreviewing = _previewingVoiceId == voice.id;
    final isPreviewLoading = _previewLoadingVoiceId == voice.id;
    return InkWell(
      onTap: () => setState(() => _voice = voice),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? _red : Colors.grey.shade300,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            InkWell(
              onTap: () => _playPreview(voice),
              borderRadius: BorderRadius.circular(20),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _red.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isPreviewLoading
                      ? Icons.hourglass_top
                      : isPreviewing
                          ? Icons.pause
                          : Icons.play_arrow,
                  color: _red,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    voice.label,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    '${voice.gender == 'Female' ? '♀ Female' : '♂ Male'} • ${_engineLabel(voice)}',
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check, color: _red, size: 22),
          ],
        ),
      ),
    );
  }

  Widget _voiceGrid(List<TtsVoice> voices) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 2.4,
      ),
      itemCount: voices.length,
      itemBuilder: (context, i) => _voiceCard(voices[i]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = _textController.text;
    final charCount = text.length;
    final displayMax = TtsService.displayMaxChars(_effectiveVoice);
    final estCost = _estimatedCost;
    final estMinutes = TtsService.estimatedMinutes(text);
    final chunks = text.trim().isEmpty
        ? 0
        : TtsService.chunkText(text, _effectiveVoice).length;
    final allVoices = TtsVoice.all;
    final firstVoices = allVoices.sublist(0, 4);
    final moreVoices = allVoices.sublist(4);
    final historyEntries = _history.entries;
    final String toneLine;
    if (_tone != null) {
      final preset = _tonePresets.firstWhere((p) => p.name == _tone);
      toneLine =
          '${preset.name}: ${preset.speed.toStringAsFixed(2)}x • ${preset.pauseSeconds.toStringAsFixed(1)}s pause';
    } else {
      toneLine =
          'Custom: ${_speed.toStringAsFixed(2)}x • ${_pauseSeconds.toStringAsFixed(1)}s pause';
    }

    return Scaffold(
      appBar: AppBar(title: const Text('TTS Studio')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Balance + daily free pill.
            Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder<int>(
                    valueListenable: widget.coins.balance,
                    builder: (context, balance, _) {
                      return Text(
                        'Balance: $balance coins',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      );
                    },
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFFA5D6A7),
                    ),
                  ),
                  child: const Text(
                    'Daily free: 50 coins',
                    style: TextStyle(
                      color: Color(0xFF1B7A3D),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Language: Auto / اردو / EN.
            _sectionTitle('Language'),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'auto', label: Text('Auto')),
                ButtonSegment(value: 'ur', label: Text('اردو')),
                ButtonSegment(value: 'en', label: Text('EN')),
              ],
              selected: {_langMode},
              onSelectionChanged: (s) =>
                  setState(() => _langMode = s.first),
            ),
            const SizedBox(height: 4),
            Text(
              _langMode == 'auto'
                  ? 'Auto — text dekh ke Urdu ya English khud pehchan le.'
                      '${text.trim().isEmpty ? '' : ' Detected: ${_effectiveLang == 'ur' ? 'Urdu' : 'English'}.'}'
                  : _langMode == 'ur'
                      ? 'Urdu voice mein generate hoga.'
                      : 'English voice mein generate hoga.',
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 12),

            // Text box + char counter + live cost.
            _whiteCard(
              child: Column(
                children: [
                  TextField(
                    controller: _textController,
                    maxLines: 8,
                    minLines: 5,
                    decoration: const InputDecoration(
                      hintText: 'Type or paste your text here...',
                      border: InputBorder.none,
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        '$charCount / $displayMax chars',
                        style: const TextStyle(color: Colors.grey),
                      ),
                      const Spacer(),
                      Text(
                        '≈ $estCost coins',
                        style: TextStyle(
                          color: _red,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  if (chunks > 1)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Long text: $chunks parts, auto-joined into one '
                        'audio (≈ $estMinutes min).',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Sample texts + import.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _choiceChip(
                  label: 'News sample',
                  selected: false,
                  onTap: () => _fillSample(_newsSample),
                ),
                _choiceChip(
                  label: 'Story sample',
                  selected: false,
                  onTap: () => _fillSample(_storySample),
                ),
                _choiceChip(
                  label: 'Ad sample',
                  selected: false,
                  onTap: () => _fillSample(_adSample),
                ),
                _choiceChip(
                  label: 'Import .txt',
                  selected: false,
                  onTap: _importTxt,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Voice grid (8 voices, +4 more expandable).
            _sectionTitle('Voice  —  tap ▶ to preview'),
            const SizedBox(height: 8),
            _voiceGrid(firstVoices),
            const SizedBox(height: 10),
            if (!_showAllVoices)
              InkWell(
                onTap: () => setState(() => _showAllVoices = true),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Text(
                    '+ 4 more voices  —  Noor  •  Veer  •  Chand  •  Hawa',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              )
            else ...[
              _voiceGrid(moreVoices),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => setState(() => _showAllVoices = false),
                child: const Text('Show less'),
              ),
            ],
            const SizedBox(height: 16),

            // Tone presets.
            _sectionTitle('Tone'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _tonePresets.map((preset) {
                return _choiceChip(
                  label: preset.name,
                  selected: _tone == preset.name,
                  onTap: _isEdgeVoice ? () {} : () => _applyTone(preset),
                );
              }).toList(),
            ),
            const SizedBox(height: 4),
            Text(
              toneLine,
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 16),

            // Speed slider + quick chips.
            _sectionTitle('Speed'),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _speed,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    label: '${_speed.toStringAsFixed(2)}x',
                    onChanged: _isEdgeVoice ? null : _setSpeed,
                  ),
                ),
                Text(
                  '${_speed.toStringAsFixed(2)}x',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 6),
                const Text(
                  '0.5x – 2.0x',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              children: _speedChips.map((chip) {
                return _choiceChip(
                  label: '${chip}x',
                  selected: (_speed - chip).abs() < 0.001,
                  onTap: _isEdgeVoice ? () {} : () => _setSpeed(chip),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            // Pause slider.
            _sectionTitle('Pause between sentences'),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _pauseSeconds,
                    min: 0,
                    max: 2.0,
                    divisions: 8,
                    label: '${_pauseSeconds.toStringAsFixed(2)}s',
                    onChanged: _isEdgeVoice ? null : _setPause,
                  ),
                ),
                Text(
                  '${_pauseSeconds.toStringAsFixed(2)}s',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            Text(
              _isEdgeVoice
                  ? 'Speed, pause and tone need a Gemini voice (Asad / Uzma return MP3).'
                  : 'Speed also changes the pitch. Pause adds silence '
                      'between sentences. Same price — no extra coins.',
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),

            // Download format.
            _sectionTitle('Download format'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                _choiceChip(
                  label: 'MP3',
                  selected: _format == 'mp3',
                  onTap: () => setState(() => _format = 'mp3'),
                ),
                _choiceChip(
                  label: 'WAV',
                  selected: _format == 'wav',
                  onTap: () => setState(() => _format = 'wav'),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Background music.
            _sectionTitle('Background music'),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Off')),
                ButtonSegment(value: true, label: Text('Soft music')),
              ],
              selected: {_musicOn},
              onSelectionChanged: (s) =>
                  setState(() => _musicOn = s.first),
            ),
            if (_musicOn) ...[
              const SizedBox(height: 4),
              const Text(
                'Soft music: 1 ad unlocks the mix for this audio. '
                'No ad available = mix still runs. No second ad at '
                'download for a music file.',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ],
            const SizedBox(height: 16),

            // Generate.
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _busy ? null : _generate,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.graphic_eq),
                label: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    _busy
                        ? 'Generating...'
                        : 'Generate Audio (${estCost > 0 ? '≈ $estCost' : '50'} coins)',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _red,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<RemoteConfig>(
              valueListenable: RemoteConfigService.instance.notifier,
              builder: (context, cfg, _) {
                return Text(
                  '${widget.coins.coinsPerMinute} coins per ~1 min • '
                  'Daily: ${widget.coins.generationsUsedToday}'
                  '/${cfg.tts.dailyCap == 0 ? '∞' : cfg.tts.dailyCap} '
                  'generations • Long text auto-splits',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                );
              },
            ),
            if (_note != null) ...[
              const SizedBox(height: 12),
              Text(
                _note!,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center,
              ),
            ],

            // Result card (green).
            for (final item in _results) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFFA5D6A7),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.check_circle,
                          color: Color(0xFF1B7A3D),
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Audio ready!',
                          style: TextStyle(
                            color: Color(0xFF1B7A3D),
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${item.id}.${item.ext}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      _resultMeta[item.id] ??
                          '${item.ext.toUpperCase()} • ${item.voiceId}',
                      style: const TextStyle(color: Colors.grey),
                    ),
                    AudioPlayerBar(
                      file: File(item.filePath),
                      title: item.displayTitle,
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () => _downloadResult(item),
                          icon: const Icon(Icons.download, size: 18),
                          label: Text(
                            _adPaidByItemId[item.id] == true
                                ? 'Download'
                                : 'Download • 1 ad',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1E9E4A),
                            foregroundColor: Colors.white,
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _shareItem(item),
                          icon: const Icon(Icons.share, size: 18),
                          label: const Text('Share'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],

            // History.
            if (historyEntries.isNotEmpty) ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(child: _sectionTitle('History')),
                  TextButton(
                    onPressed: () async {
                      await _history.clear();
                      if (mounted) setState(() {});
                    },
                    child: const Text('Clear'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final entry
                  in _showAllHistory
                      ? historyEntries
                      : historyEntries.take(5))
                Card(
                  color: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Colors.grey.shade200),
                  ),
                  child: ListTile(
                    leading: IconButton(
                      icon: Icon(
                        _historyPlayingId == entry.id
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        size: 36,
                        color: _red,
                      ),
                      onPressed: () => _toggleHistoryPlay(entry),
                    ),
                    title: Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${entry.voiceLabel.isNotEmpty ? entry.voiceLabel : entry.voiceId}'
                      ' • ${_dateLabel(entry.createdAtMs)}'
                      ' • ${entry.coinsSpent} coins'
                      '${entry.musicUsed ? ' • ♪ Music' : ''}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.download, size: 20),
                          tooltip: entry.adPaid
                              ? 'Download (no ad — already paid)'
                              : 'Download (1 ad)',
                          onPressed: () => _downloadHistory(entry),
                        ),
                        IconButton(
                          icon: const Icon(Icons.share, size: 20),
                          tooltip: 'Share',
                          onPressed: () =>
                              _shareItem(entry.asAudioItem),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, size: 20),
                          tooltip: 'Remove from history',
                          onPressed: () async {
                            await _history.remove(entry);
                            if (mounted) setState(() {});
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              if (historyEntries.length > 5)
                TextButton(
                  onPressed: () =>
                      setState(() => _showAllHistory = !_showAllHistory),
                  child: Text(
                    _showAllHistory
                        ? 'Show less'
                        : 'Show all ${historyEntries.length} entries',
                  ),
                ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
