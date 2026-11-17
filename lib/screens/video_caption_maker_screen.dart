import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../l10n/strings.dart';
import '../services/ads_service.dart';
import '../services/audio_download_service.dart';
import '../services/caption_draft_service.dart';
import '../services/caption_service.dart';
import '../services/caption_styles.dart';
import '../services/coins_service.dart';
import '../services/remote_config_service.dart';
import '../services/video_export_service.dart';
import '../widgets/caption_editor_widgets.dart';
import '../widgets/help_whatsapp_button.dart';
import '../widgets/styled_caption_text.dart';
import 'caption_translator_screen.dart';

/// Video Caption Maker (AI) (v1.0.3 batch 2, styles in v1.0.6,
/// Caption Studio redesign v1.0.10): pick a video file, transcribe
/// its audio via the proxy's POST /transcribe, then style the
/// captions — 11 CapCut-style looks (Nigraan Karaoke, Bold Pop,
/// Pop Up, Karaoke Fill, Highlight Box, Typewriter, One Word,
/// Classic, News Ticker, Spotlight, Minimal), English + Urdu, with
/// position / size / highlight-colour / font controls. The player
/// preview plays the video with the styled caption overlaid, synced
/// to playback. Caption lines can be edited (fix misheard words),
/// split, merged, re-timed, shifted, or deleted. Exports: SRT, ASS,
/// VTT, TXT, plain-text copy, and the video itself with captions
/// burned in (on-device ffmpeg, 720p/1080p).
///
/// COINS + SRT/ASS/VTT/TXT AD GATE: exactly the same as the AI
/// Caption Generator — 50 coins per minute (rounded up, min 50)
/// charged BEFORE transcribing (refunded in full if transcription
/// fails), and the caption-file save goes through
/// AudioDownloadService.downloadBytesWithAds with the remote-config
/// downloadAdsRequired count (default 2, both fully watched).
/// VIDEO EXPORT AD: ONE rewarded ad, shown BEFORE the burn-in runs
/// (ad-unlock, fail-soft — skipped = no export, unavailable = the
/// export runs anyway); that same ad covers the download, no second
/// ad for the same file.
///
/// WORD TIMING: the proxy returns real Whisper word timings, so the
/// karaoke / pop / typewriter styles highlight the word actually
/// being spoken — no even-split guessing (manual lines without word
/// timings fall back to even-split).
class VideoCaptionMakerScreen extends StatefulWidget {
  final CoinsService coins;

  const VideoCaptionMakerScreen({super.key, required this.coins});

  @override
  State<VideoCaptionMakerScreen> createState() =>
      _VideoCaptionMakerScreenState();
}

class _VideoCaptionMakerScreenState extends State<VideoCaptionMakerScreen> {
  static const String _draftKey = 'video_caption_maker';

  File? _file;
  String? _fileName;
  VideoPlayerController? _controller;
  bool _playerReady = false;
  String _lang = 'ur';
  bool _busy = false;
  bool _exporting = false;
  String? _message;
  TranscriptionResult? _result;

  // v1.0.6 — caption styling (editable segment list + style choices).
  List<CaptionSegment> _segments = [];
  CaptionStyle _style = CaptionStyles.all.first;
  CaptionPosition _position = CaptionPosition.bottom;
  CaptionSize _size = CaptionSize.medium;
  int _highlight = CaptionStyles.green;
  // Default font follows the default language (Urdu = Jameel Noori).
  CaptionFont _font = CaptionFonts.jameelKasheeda;

  // v1.0.10 — Caption Studio: FX toggles, dual captions, presets,
  // editor selection, undo/redo, draft auto-save, export quality.
  bool _fxOutline = true;
  bool _fxShadow = true;
  bool _fxBackground = false;
  bool _dualLanguage = false;
  String _presetId = CaptionPresets.nigraanNews.id;
  int _selectedIndex = -1;
  VideoExportQuality _quality = VideoExportQuality.p720;
  final List<List<CaptionSegment>> _undoStack = [];
  final List<List<CaptionSegment>> _redoStack = [];
  Timer? _draftTimer;
  bool _draftRestored = false;

  Duration? get _duration =>
      _playerReady ? _controller?.value.duration : null;

  int get _cost =>
      CaptionService.costForDuration(_duration, widget.coins.coinsPerMinute);

  bool get _isVertical {
    final controller = _controller;
    if (controller == null || !_playerReady) return false;
    return controller.value.aspectRatio < 1.0;
  }

  ({int x, int y}) get _assCanvas =>
      _isVertical ? (x: 1080, y: 1920) : (x: 1280, y: 720);

  @override
  void initState() {
    super.initState();
    _restoreDraft();
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  // ---- draft auto-save / restore ----

  void _scheduleDraftSave() {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 800), () {
      final file = _file;
      if (file == null || !mounted) return;
      unawaited(
        CaptionDraftService.saveDraft(
          _draftKey,
          CaptionDraftService.encodeDraft(
            filePath: file.path,
            fileName: _fileName ?? '',
            lang: _lang,
            segments: _segments,
            styleId: _style.id,
            position: _position.name,
            size: _size.name,
            highlightColor: _highlight,
            fontId: _font.id,
            outline: _fxOutline,
            shadow: _fxShadow,
            background: _fxBackground,
            dualLanguage: _dualLanguage,
            presetId: _presetId,
            selectedIndex: _selectedIndex,
          ),
        ),
      );
    });
  }

  Future<void> _restoreDraft() async {
    final draft = await CaptionDraftService.loadDraft(_draftKey);
    if (draft == null || !mounted) return;
    final path = (draft['filePath'] ?? '').toString();
    if (path.isEmpty || !await File(path).exists()) {
      await CaptionDraftService.clearDraft(_draftKey);
      return;
    }
    final file = File(path);
    final size = await file.length();
    if (size > CaptionService.maxFileBytes) {
      await CaptionDraftService.clearDraft(_draftKey);
      return;
    }
    final controller = VideoPlayerController.file(file);
    try {
      await controller.initialize();
    } catch (_) {
      await controller.dispose();
      return;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    if (controller.value.duration.inSeconds >
        CaptionService.maxDurationSeconds) {
      await controller.dispose();
      return;
    }
    await _controller?.dispose();
    setState(() {
      _file = file;
      _fileName = (draft['fileName'] ?? '').toString();
      _controller = controller;
      _playerReady = true;
      _lang = (draft['lang'] ?? 'ur').toString();
      _segments = CaptionDraftService.decodeSegments(draft);
      _style = CaptionStyles.byId(
        (draft['styleId'] ?? '').toString(),
      );
      _position = CaptionPosition.values.firstWhere(
        (p) => p.name == draft['position'],
        orElse: () => _style.position,
      );
      _size = CaptionSize.values.firstWhere(
        (s) => s.name == draft['size'],
        orElse: () => CaptionSize.medium,
      );
      _highlight = (draft['highlightColor'] as num?)?.toInt() ?? _highlight;
      _font = CaptionFonts.byId((draft['fontId'] ?? '').toString());
      _fxOutline = draft['outline'] == true;
      _fxShadow = draft['shadow'] == true;
      _fxBackground = draft['background'] == true;
      _dualLanguage = draft['dualLanguage'] == true;
      _presetId = (draft['presetId'] ?? '').toString();
      _selectedIndex = (draft['selectedIndex'] as num?)?.toInt() ?? -1;
      _draftRestored = true;
      _message = 'Draft restored — your last captions are back.';
    });
  }

  /// Apply a restored/loaded draft's settings (shared by pick + init).
  void _applyDraftSettings(Map<String, dynamic> draft) {
    _lang = (draft['lang'] ?? _lang).toString();
    _segments = CaptionDraftService.decodeSegments(draft);
    _style = CaptionStyles.byId((draft['styleId'] ?? '').toString());
    _position = CaptionPosition.values.firstWhere(
      (p) => p.name == draft['position'],
      orElse: () => _style.position,
    );
    _size = CaptionSize.values.firstWhere(
      (s) => s.name == draft['size'],
      orElse: () => CaptionSize.medium,
    );
    _highlight =
        (draft['highlightColor'] as num?)?.toInt() ?? _highlight;
    _font = CaptionFonts.byId((draft['fontId'] ?? '').toString());
    _fxOutline = draft['outline'] == true;
    _fxShadow = draft['shadow'] == true;
    _fxBackground = draft['background'] == true;
    _dualLanguage = draft['dualLanguage'] == true;
    _presetId = (draft['presetId'] ?? '').toString();
    _selectedIndex = (draft['selectedIndex'] as num?)?.toInt() ?? -1;
  }

  // ---- undo / redo + segment edits ----

  void _pushUndo() {
    _undoStack.add(List.of(_segments));
    if (_undoStack.length > 50) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  void _setSegments(List<CaptionSegment> next) {
    _pushUndo();
    setState(() => _segments = next);
    _scheduleDraftSave();
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(List.of(_segments));
    setState(() {
      _segments = _undoStack.removeLast();
      if (_selectedIndex >= _segments.length) _selectedIndex = -1;
    });
    _scheduleDraftSave();
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(List.of(_segments));
    setState(() {
      _segments = _redoStack.removeLast();
      if (_selectedIndex >= _segments.length) _selectedIndex = -1;
    });
    _scheduleDraftSave();
  }

  void _selectSegment(int index) {
    final controller = _controller;
    setState(() => _selectedIndex = index);
    if (controller != null && _playerReady) {
      controller.seekTo(
        Duration(milliseconds: (_segments[index].start * 1000).round()),
      );
    }
  }

  /// Split the selected line in two at its middle word boundary.
  void _splitSelected() {
    if (_selectedIndex < 0 || _selectedIndex >= _segments.length) {
      setState(() => _message = 'Tap a caption line first, then Split.');
      return;
    }
    final seg = _segments[_selectedIndex];
    final words = CaptionStyles.wordsOf(seg.text);
    if (words.length < 2) {
      setState(() => _message = 'That line is too short to split.');
      return;
    }
    final cut = words.length ~/ 2;
    final mid = (seg.start + seg.end) / 2;
    final firstWords = words.sublist(0, cut);
    final secondWords = words.sublist(cut);
    List<CaptionWord> splitWords(List<CaptionWord> all, bool first) {
      if (all.isEmpty) return const [];
      return all.where((w) => first ? w.end <= mid : w.start >= mid).toList();
    }

    final next = List.of(_segments);
    next[_selectedIndex] = seg.copyWith(
      end: mid,
      text: firstWords.join(' '),
      words: splitWords(seg.words, true),
    );
    next.insert(
      _selectedIndex + 1,
      seg.copyWith(
        start: mid,
        text: secondWords.join(' '),
        words: splitWords(seg.words, false),
      ),
    );
    _setSegments(next);
  }

  /// Merge the selected line with the next one.
  void _mergeSelected() {
    if (_selectedIndex < 0 || _selectedIndex >= _segments.length) {
      setState(() => _message = 'Tap a caption line first, then Merge.');
      return;
    }
    if (_selectedIndex + 1 >= _segments.length) {
      setState(() => _message = 'No next line to merge with.');
      return;
    }
    final a = _segments[_selectedIndex];
    final b = _segments[_selectedIndex + 1];
    final next = List.of(_segments);
    next[_selectedIndex] = CaptionSegment(
      start: a.start,
      end: b.end,
      text: '${a.text} ${b.text}'.trim(),
      words: [...a.words, ...b.words],
      translation: [a.translation, b.translation]
          .where((t) => t.trim().isNotEmpty)
          .join(' '),
    );
    next.removeAt(_selectedIndex + 1);
    _setSegments(next);
  }

  /// Shift every caption by [deltaSeconds] (negative = earlier).
  /// Clamped so no line starts before 0.
  void _shiftAll(double deltaSeconds) {
    if (_segments.isEmpty) return;
    final minStart =
        _segments.map((s) => s.start).reduce((a, b) => a < b ? a : b);
    var shift = deltaSeconds;
    if (minStart + shift < 0) shift = -minStart;
    if (shift == 0) return;
    _setSegments(
      _segments
          .map(
            (s) => s.copyWith(
              start: s.start + shift,
              end: s.end + shift,
              words: s.words
                  .map(
                    (w) => CaptionWord(
                      word: w.word,
                      start: w.start + shift,
                      end: w.end + shift,
                    ),
                  )
                  .toList(),
            ),
          )
          .toList(),
    );
  }

  /// Nudge the selected line by [deltaSeconds] (±0.1s buttons).
  void _nudgeSelected(double deltaSeconds) {
    if (_selectedIndex < 0 || _selectedIndex >= _segments.length) {
      setState(() => _message = 'Tap a caption line first.');
      return;
    }
    final seg = _segments[_selectedIndex];
    var start = seg.start + deltaSeconds;
    var end = seg.end + deltaSeconds;
    if (start < 0) {
      end -= start;
      start = 0;
    }
    if (end <= start + 0.2) end = start + 0.2;
    final shift = start - seg.start;
    final next = List.of(_segments);
    next[_selectedIndex] = seg.copyWith(
      start: start,
      end: end,
      words: seg.words
          .map(
            (w) => CaptionWord(
              word: w.word,
              start: w.start + shift,
              end: w.end + shift,
            ),
          )
          .toList(),
    );
    _setSegments(next);
  }

  void _applyPreset(CaptionPreset preset) {
    setState(() {
      _presetId = preset.id;
      _style = CaptionStyles.byId(preset.styleId);
      _position = preset.position;
      _size = preset.size;
      _highlight = preset.highlightColor;
      _fxOutline = preset.outline;
      _fxShadow = preset.shadow;
      _fxBackground = preset.background;
      final offered = CaptionFonts.forLang(_lang);
      if (offered.any((f) => f.id == preset.fontId)) {
        _font = CaptionFonts.byId(preset.fontId);
      }
    });
    _scheduleDraftSave();
  }

  Future<void> _pickVideo() async {
    if (_busy) return;
    // file_picker 13.x API: FilePicker.pickFile() returns a single
    // PlatformFile (null on cancel); the old FilePicker.platform
    // + FilePickerResult API is gone in 13.x.
    final picked = await FilePicker.pickFile(
      type: FileType.video,
    );
    if (picked == null) return;
    final path = picked.path;
    if (path == null) {
      if (mounted) {
        setState(() => _message = 'Could not read that video.');
      }
      return;
    }
    final file = File(path);
    final size = await file.length();
    if (size > CaptionService.maxFileBytes) {
      if (!mounted) return;
      setState(() {
        _message = 'Video is too large — max 25 MB.';
        _result = null;
        _segments = [];
      });
      return;
    }
    await _controller?.dispose();
    final controller = VideoPlayerController.file(file);
    setState(() {
      _file = file;
      _fileName = picked.name;
      _controller = controller;
      _playerReady = false;
      _result = null;
      _segments = [];
      _selectedIndex = -1;
      _undoStack.clear();
      _redoStack.clear();
      _message = null;
    });
    try {
      await controller.initialize();
      if (!mounted) return;
      if (controller.value.duration.inSeconds >
          CaptionService.maxDurationSeconds) {
        setState(() {
          _message = 'Video is too long — max 10 minutes.';
          _file = null;
          _fileName = null;
        });
        await controller.dispose();
        if (mounted) setState(() => _controller = null);
        return;
      }
      // Same file as the saved draft? Restore the draft's captions.
      final draft = await CaptionDraftService.loadDraft(_draftKey);
      if (!mounted) return;
      setState(() {
        _playerReady = true;
        if (draft != null &&
            (draft['fileName'] ?? '') == picked.name &&
            (draft['segments'] is List) &&
            (draft['segments'] as List).isNotEmpty) {
          _applyDraftSettings(draft);
          _draftRestored = true;
          _message = 'Draft restored — your last captions are back.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Could not play that video: $e');
    }
  }

  Future<void> _transcribe() async {
    final file = _file;
    if (file == null || _busy) return;
    final locale = Localizations.localeOf(context);
    if (!widget.coins.canAfford(_cost)) {
      setState(
        () => _message = AppStrings.tr('not_enough_coins_captions', locale),
      );
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await CaptionService.transcribeCharged(
        coins: widget.coins,
        file: file,
        lang: _lang,
        duration: _duration,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _segments = List.of(result.segments);
        _selectedIndex = _segments.isEmpty ? -1 : 0;
        _undoStack.clear();
        _redoStack.clear();
      });
      _scheduleDraftSave();
    } on InsufficientCoinsException {
      if (!mounted) return;
      setState(
        () => _message = AppStrings.tr('not_enough_coins_captions', locale),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Transcription failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyCaptions() async {
    if (_segments.isEmpty) return;
    // Copy copies PLAIN TEXT (not SRT) — paste it anywhere.
    await Clipboard.setData(
      ClipboardData(
        text: CaptionService.buildPlainText(
          _segments,
          dualLanguage: _dualLanguage,
        ),
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Captions copied as plain text.')),
    );
  }

  String _baseName() {
    final name = _fileName ?? 'captions';
    return name.contains('.')
        ? name.substring(0, name.lastIndexOf('.'))
        : name;
  }

  String _assContent() {
    final canvas = _assCanvas;
    return CaptionService.buildAss(
      _segments,
      _style,
      position: _position,
      size: _size,
      highlightColor: _highlight,
      fontFamily: _font.family,
      playResX: canvas.x,
      playResY: canvas.y,
      outline: _fxOutline,
      shadow: _fxShadow,
      background: _fxBackground,
      dualLanguage: _dualLanguage,
    );
  }

  Future<void> _saveSrt() async {
    if (_segments.isEmpty) return;
    await AudioDownloadService.downloadBytesWithAds(
      context,
      adsRequired:
          RemoteConfigService.instance.config.downloadAdsRequired,
      fileName: '${_baseName()}.srt',
      bytes: utf8.encode(CaptionService.buildSrt(_segments)),
    );
  }

  Future<void> _saveAss() async {
    if (_segments.isEmpty) return;
    await AudioDownloadService.downloadBytesWithAds(
      context,
      adsRequired:
          RemoteConfigService.instance.config.downloadAdsRequired,
      fileName: '${_baseName()}.ass',
      bytes: utf8.encode(_assContent()),
    );
  }

  Future<void> _saveVtt() async {
    if (_segments.isEmpty) return;
    await AudioDownloadService.downloadBytesWithAds(
      context,
      adsRequired:
          RemoteConfigService.instance.config.downloadAdsRequired,
      fileName: '${_baseName()}.vtt',
      bytes: utf8.encode(
        CaptionService.buildVtt(
          _segments,
          dualLanguage: _dualLanguage,
        ),
      ),
    );
  }

  Future<void> _saveTxt() async {
    if (_segments.isEmpty) return;
    await AudioDownloadService.downloadBytesWithAds(
      context,
      adsRequired:
          RemoteConfigService.instance.config.downloadAdsRequired,
      fileName: '${_baseName()}.txt',
      bytes: utf8.encode(
        CaptionService.buildTxt(
          _segments,
          dualLanguage: _dualLanguage,
        ),
      ),
    );
  }

  /// Video export: ONE rewarded ad BEFORE the burn-in (ad-unlock).
  /// Skipped ad = no export + a short message. No ad available =
  /// fail-soft, the export runs anyway. The same ad covers the
  /// download — no second ad is shown for this file.
  Future<void> _exportVideo() async {
    final file = _file;
    if (file == null || _segments.isEmpty || _exporting) return;
    setState(() {
      _exporting = true;
      _message = null;
    });
    final unlock = await VideoExportService.requestUnlock();
    if (!mounted) return;
    if (unlock == VideoExportUnlock.denied) {
      setState(() {
        _exporting = false;
        _message = 'Watch the full ad to export the video.';
      });
      return;
    }
    final result = await VideoExportService.exportVideo(
      inputVideo: file,
      assContent: _assContent(),
      quality: _quality,
      baseName: _baseName(),
    );
    if (!mounted) return;
    setState(() {
      _exporting = false;
      _message = result.success
          ? 'Video saved to ${result.outputPath}'
          : 'Video export failed: ${result.error}';
    });
  }

  Future<void> _editSegment(int index) async {
    final seg = _segments[index];
    final textController = TextEditingController(text: seg.text);
    final translationController =
        TextEditingController(text: seg.translation);
    final startController =
        TextEditingController(text: seg.start.toStringAsFixed(2));
    final endController =
        TextEditingController(text: seg.end.toStringAsFixed(2));
    final edited = await showDialog<EditedCaptionLine>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          Localizations.localeOf(context).languageCode == 'ur'
              ? 'کیپشن بدلیں'
              : 'Edit caption',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: textController,
                autofocus: true,
                maxLines: 3,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Caption text (emoji allowed 🙂)',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: translationController,
                maxLines: 2,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Second line — English (dual captions)',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: startController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Start (s)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: endController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'End (s)',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(
              EditedCaptionLine(
                text: textController.text.trim(),
                translation: translationController.text.trim(),
                start: double.tryParse(startController.text.trim()),
                end: double.tryParse(endController.text.trim()),
              ),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    textController.dispose();
    translationController.dispose();
    startController.dispose();
    endController.dispose();
    if (edited == null || edited.text.isEmpty || !mounted) return;
    final start = edited.start;
    final end = edited.end;
    if (start != null && end != null && end <= start) {
      setState(() => _message = 'End time must be after start time.');
      return;
    }
    final next = List.of(_segments);
    // The words no longer match if the text itself changed — drop
    // the word timings then (even-split fallback applies).
    final textChanged = edited.text != seg.text;
    next[index] = seg.copyWith(
      text: edited.text,
      translation: edited.translation,
      start: start ?? seg.start,
      end: end ?? seg.end,
      words: textChanged ? const [] : seg.words,
    );
    _setSegments(next);
  }

  /// Manual line: type the text + set start/end time, no AI.
  Future<void> _addManualLine() async {
    final duration = _duration;
    final textController = TextEditingController();
    final startController = TextEditingController(
      text: _segments.isEmpty
          ? '0'
          : _segments.last.end.toStringAsFixed(2),
    );
    final endController = TextEditingController(
      text: _segments.isEmpty
          ? '2'
          : (_segments.last.end + 2).toStringAsFixed(2),
    );
    final added = await showDialog<EditedCaptionLine>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add caption line'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: textController,
                autofocus: true,
                maxLines: 3,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Caption text (emoji allowed 🙂)',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: startController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Start (s)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: endController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'End (s)',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(
              EditedCaptionLine(
                text: textController.text.trim(),
                translation: '',
                start: double.tryParse(startController.text.trim()),
                end: double.tryParse(endController.text.trim()),
              ),
            ),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    textController.dispose();
    startController.dispose();
    endController.dispose();
    if (added == null || added.text.isEmpty || !mounted) return;
    final start = added.start ?? 0;
    final end = added.end ?? (start + 2);
    if (end <= start) {
      setState(() => _message = 'End time must be after start time.');
      return;
    }
    if (duration != null && start > duration.inSeconds) {
      setState(() => _message = 'Start time is past the video length.');
      return;
    }
    final next = List.of(_segments)
      ..add(CaptionSegment(start: start, end: end, text: added.text))
      ..sort((a, b) => a.start.compareTo(b.start));
    _setSegments(next);
    setState(
      () => _selectedIndex =
          next.indexWhere((s) => s.text == added.text && s.start == start),
    );
  }

  /// The caption line whose time range contains [position], if any.
  CaptionSegment? _currentCaption(Duration position) {
    if (_segments.isEmpty) return null;
    final pos = position.inMilliseconds / 1000;
    for (final seg in _segments) {
      if (pos >= seg.start && pos < seg.end) return seg;
    }
    return null;
  }

  String _clockLabel(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Alignment _positionAlign() => switch (_position) {
        CaptionPosition.top => Alignment.topCenter,
        CaptionPosition.middle => Alignment.center,
        CaptionPosition.bottom => Alignment.bottomCenter,
      };

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context);
    final controller = _controller;
    final result = _result;
    return Scaffold(
      appBar: AppBar(
        title: Text(AppStrings.tr('video_caption_maker', locale)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'AI',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder<int>(
                    valueListenable: widget.coins.balance,
                    builder: (context, balance, _) {
                      return Text(
                        '${AppStrings.tr('balance', locale)}: $balance coins',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      );
                    },
                  ),
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'ur', label: Text('اردو')),
                    ButtonSegment(value: 'en', label: Text('EN')),
                  ],
                  selected: {_lang},
                  onSelectionChanged: (s) => setState(() {
                    _lang = s.first;
                    // Font follows the language: Urdu = Jameel Noori,
                    // English = system font.
                    _font = CaptionFonts.forLang(_lang).first;
                  }),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Pick a video. Its audio is transcribed into captions — '
              '50 coins per minute. Pick a caption style first if you '
              'like (11 styles, English + Urdu, Jameel Noori + display '
              'fonts), then transcribe, edit the lines, and save as '
              'SRT, ASS, VTT or TXT — or export the video with the '
              'captions burned in.',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickVideo,
              icon: const Icon(Icons.video_file),
              label: const Text('Pick a video file'),
            ),
            if (controller != null && _playerReady) ...[
              const SizedBox(height: 12),
              AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: Stack(
                  children: [
                    VideoPlayer(controller),
                    // Styled in-player caption preview, synced to
                    // playback, in the chosen style + position.
                    ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: controller,
                      builder: (context, value, _) {
                        final caption = _currentCaption(value.position);
                        if (caption == null) {
                          return const SizedBox.shrink();
                        }
                        return Align(
                          alignment: _positionAlign(),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                StyledCaptionText(
                                  text: caption.text,
                                  start: caption.start,
                                  end: caption.end,
                                  positionSeconds:
                                      value.position.inMilliseconds / 1000,
                                  style: _style,
                                  size: _size,
                                  highlightColor: _highlight,
                                  lang: _lang,
                                  fontFamily: _font.family,
                                  words: caption.words,
                                  outline: _fxOutline,
                                  shadow: _fxShadow,
                                  background: _fxBackground,
                                ),
                                if (_dualLanguage &&
                                    caption.translation
                                        .trim()
                                        .isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      caption.translation,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: _style.fontSizePx *
                                                CaptionStyles.sizeScale(
                                                  _size,
                                                ) *
                                                0.7,
                                        fontWeight: FontWeight.w600,
                                        shadows: const [
                                          Shadow(
                                            color: Colors.black,
                                            offset: Offset(1, 1),
                                            blurRadius: 2,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: controller,
                builder: (context, value, _) {
                  final total = value.duration;
                  final pos = value.position;
                  return Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          value.isPlaying ? Icons.pause : Icons.play_arrow,
                        ),
                        onPressed: () {
                          if (value.isPlaying) {
                            controller.pause();
                          } else {
                            controller.play();
                          }
                        },
                      ),
                      Text(_clockLabel(pos)),
                      Expanded(
                        child: Slider(
                          value: total.inMilliseconds > 0
                              ? (pos.inMilliseconds / total.inMilliseconds)
                                  .clamp(0.0, 1.0)
                              : 0,
                          onChanged: (v) {
                            controller.seekTo(
                              Duration(
                                milliseconds:
                                    (v * total.inMilliseconds).round(),
                              ),
                            );
                          },
                        ),
                      ),
                      Text(_clockLabel(total)),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              Text(
                'Duration: ${_clockLabel(_duration ?? Duration.zero)}'
                '  •  Cost: $_cost coins'
                '${_isVertical ? '  •  Vertical video (1080×1920 captions)' : ''}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _busy ? null : _transcribe,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.closed_caption),
                label: Text(
                  _busy
                      ? 'Transcribing…'
                      : result != null
                          ? 'Transcribe again ($_cost coins)'
                          : 'Transcribe ($_cost coins)',
                ),
              ),
              const SizedBox(height: 16),
              // Style panel (dark editor look, mockup v3): visible as
              // soon as a file is picked — not only after a result.
              CaptionStylePanel(
                lang: _lang,
                style: _style,
                onStyleSelected: (s) => setState(() {
                  _style = s;
                  _position = s.position;
                  _highlight = s.highlightColor;
                  _presetId = '';
                  _scheduleDraftSave();
                }),
                presetId: _presetId,
                onPresetSelected: _applyPreset,
                position: _position,
                onPositionChanged: (p) => setState(() {
                  _position = p;
                  _scheduleDraftSave();
                }),
                size: _size,
                onSizeChanged: (s) => setState(() {
                  _size = s;
                  _scheduleDraftSave();
                }),
                highlight: _highlight,
                onHighlightChanged: (c) => setState(() {
                  _highlight = c;
                  _scheduleDraftSave();
                }),
                font: _font,
                onFontChanged: (f) => setState(() {
                  _font = f;
                  _scheduleDraftSave();
                }),
                fxOutline: _fxOutline,
                onOutlineChanged: (v) => setState(() {
                  _fxOutline = v;
                  _scheduleDraftSave();
                }),
                fxShadow: _fxShadow,
                onShadowChanged: (v) => setState(() {
                  _fxShadow = v;
                  _scheduleDraftSave();
                }),
                fxBackground: _fxBackground,
                onBackgroundChanged: (v) => setState(() {
                  _fxBackground = v;
                  _scheduleDraftSave();
                }),
                dualLanguage: _dualLanguage,
                onDualChanged: (v) => setState(() {
                  _dualLanguage = v;
                  _scheduleDraftSave();
                }),
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(_message!, style: const TextStyle(color: Colors.red)),
            ],
            if (_segments.isNotEmpty) ...[
              const SizedBox(height: 16),
              // Editor toolbar (dark, mockup v3).
              CaptionEditorToolbar(
                total: _duration ?? Duration.zero,
                canUndo: _undoStack.isNotEmpty,
                canRedo: _redoStack.isNotEmpty,
                onSplit: _splitSelected,
                onMerge: _mergeSelected,
                onAddLine: _addManualLine,
                onUndo: _undo,
                onRedo: _redo,
                onTranslate: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CaptionTranslatorScreen(
                      coins: widget.coins,
                      segments: _segments,
                      sourceLang: _lang,
                      mediaDuration: _duration,
                      fileName: _fileName,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Timeline strip + selected-line editor (dark).
              CaptionTimelineStrip(
                segments: _segments,
                selectedIndex: _selectedIndex,
                onSelect: _selectSegment,
              ),
              if (_selectedIndex >= 0 &&
                  _selectedIndex < _segments.length) ...[
                const SizedBox(height: 8),
                SelectedCaptionLineCard(
                  segment: _segments[_selectedIndex],
                  onNudge: _nudgeSelected,
                  onEdit: () => _editSegment(_selectedIndex),
                  onDelete: () {
                    _pushUndo();
                    setState(() {
                      _segments.removeAt(_selectedIndex);
                      _selectedIndex = -1;
                    });
                    _scheduleDraftSave();
                  },
                ),
              ],
              const SizedBox(height: 16),
              // Download notice, in the user's exact words: the ad must
              // be watched fully — one ad watched, second skipped = no
              // download, watch the ads again.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _lang == 'ur'
                      ? '📺 ویڈیو ڈاؤن لوڈ کرنے کے لیے ایڈ کو مکمل دیکھیں — اگر ایک ایڈ دیکھی اور دوسری نہ دیکھی تو ویڈیو ڈاؤن لوڈ نہیں ہوگی۔'
                      : '📺 Watch the ad completely to download the video — if you watch one ad and not the second, the video will not download.',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_segments.length} caption lines',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _copyCaptions,
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy'),
                  ),
                  FilledButton.icon(
                    onPressed: () => _showExportSheet(),
                    icon: const Icon(Icons.ios_share, size: 18),
                    label: const Text('Export'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Shift all captions ±0.5s.
              Row(
                children: [
                  const Text('Shift all:'),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => _shiftAll(-0.5),
                    child: const Text('−0.5s'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => _shiftAll(0.5),
                    child: const Text('+0.5s'),
                  ),
                  const Spacer(),
                  if (_draftRestored)
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.save, size: 16, color: Colors.green),
                        SizedBox(width: 4),
                        Text(
                          'Draft auto-saved',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.green,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < _segments.length; i++)
                Card(
                  color: i == _selectedIndex
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  child: ListTile(
                    onTap: () => _selectSegment(i),
                    leading: Chip(
                      label: Text(
                        _segments[i].timeLabel,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    title: Text(_segments[i].text),
                    subtitle: _segments[i].translation.trim().isNotEmpty
                        ? Text(_segments[i].translation)
                        : null,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit, size: 20),
                          tooltip: 'Edit',
                          onPressed: () => _editSegment(i),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, size: 20),
                          tooltip: 'Delete',
                          onPressed: () {
                            _pushUndo();
                            setState(() => _segments.removeAt(i));
                            _scheduleDraftSave();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              // Video export — captions burned in (1 rewarded ad
              // before the burn-in; that ad covers the download).
              FilledButton.icon(
                onPressed: _exporting ? null : _exportVideo,
                icon: _exporting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.movie),
                label: Text(
                  _exporting
                      ? 'Exporting video…'
                      : 'Export Video — captions burned in • 1 ad',
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Export: SRT • ASS • VTT • TXT • Video MP4 (burned)\n'
                'Word-by-word karaoke uses Whisper\'s real timing — '
                'each word highlights as it is spoken.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
              const SizedBox(height: 16),
              // For Help — very end of the screen.
              HelpWhatsAppRow(lang: _lang),
            ],
          ],
        ),
      ),
      bottomNavigationBar: const UnityBannerAdWidget(zone: 'tools'),
    );
  }

  /// Export sheet (dark, mockup v3-export): pick the format, the
  /// video quality, and dual captions, then export.
  Future<void> _showExportSheet() async {
    if (_segments.isEmpty) return;
    var format = CaptionExportFormat.srt;
    var quality = _quality;
    var dual = _dualLanguage;
    final adsRequired =
        RemoteConfigService.instance.config.downloadAdsRequired;
    final chosen = await showModalBottomSheet<CaptionExportChoice>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          Widget tile(
            CaptionExportFormat f,
            String title,
            String sub, {
            bool isNew = false,
          }) {
            final selected = format == f;
            return GestureDetector(
              onTap: () => setSheetState(() => format = f),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: selected ? Colors.red.shade900 : Colors.white12,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected ? Colors.red : Colors.white24,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        if (isNew)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'NEW',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      sub,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Export',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () => Navigator.of(sheetContext).pop(),
                      ),
                    ],
                  ),
                  const Text(
                    'Captions kis format mein chahiye?',
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: tile(
                          CaptionExportFormat.srt,
                          'SRT',
                          'SubRip — har player mein chalta hai',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: tile(
                          CaptionExportFormat.ass,
                          'ASS',
                          'Styled — font, colour, karaoke',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: tile(
                          CaptionExportFormat.vtt,
                          'VTT',
                          'Web captions — YouTube / web',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: tile(
                          CaptionExportFormat.txt,
                          'TXT',
                          'Saada text — sirf bolay gaye alfaaz',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: tile(
                          CaptionExportFormat.video,
                          'Video MP4',
                          'Captions video mein burned — TikTok ready',
                          isNew: true,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: tile(
                          CaptionExportFormat.copy,
                          'Copy text',
                          'Captions copy karein — paste kahin bhi',
                        ),
                      ),
                    ],
                  ),
                  if (format == CaptionExportFormat.video) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Text(
                          'Video quality',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 12),
                        ChoiceChip(
                          label: const Text('720p'),
                          selected: quality == VideoExportQuality.p720,
                          selectedColor: Colors.red,
                          labelStyle: TextStyle(
                            color: quality == VideoExportQuality.p720
                                ? Colors.white
                                : Colors.white70,
                          ),
                          backgroundColor: Colors.white12,
                          onSelected: (_) => setSheetState(
                            () => quality = VideoExportQuality.p720,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('1080p'),
                          selected: quality == VideoExportQuality.p1080,
                          selectedColor: Colors.red,
                          labelStyle: TextStyle(
                            color: quality == VideoExportQuality.p1080
                                ? Colors.white
                                : Colors.white70,
                          ),
                          backgroundColor: Colors.white12,
                          onSelected: (_) => setSheetState(
                            () => quality = VideoExportQuality.p1080,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () => setSheetState(() => dual = !dual),
                    child: Row(
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: dual ? Colors.red : Colors.transparent,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color:
                                  dual ? Colors.red : Colors.white54,
                            ),
                          ),
                          child: dual
                              ? const Icon(
                                  Icons.check,
                                  size: 16,
                                  color: Colors.white,
                                )
                              : null,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Dual captions — Urdu + English, aik saath',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade900.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.amber.shade700),
                    ),
                    child: Text(
                      'Video export: 1 rewarded ad • SRT / ASS / VTT / TXT: '
                      '$adsRequired ads (donon poori dekhein)\n'
                      'Ad skip ki to file save nahi hogi — dobara download dabayein.',
                      style: const TextStyle(color: Colors.amberAccent),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(sheetContext).pop(
                        CaptionExportChoice(
                          format: format,
                          quality: quality,
                          dualLanguage: dual,
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: Text(
                        'Export — ${_exportLabel(format)}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Draft auto-save hota hai — kaam band kar ke baad mein bhi khol sakty hen.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _quality = chosen.quality;
      _dualLanguage = chosen.dualLanguage;
    });
    switch (chosen.format) {
      case CaptionExportFormat.srt:
        await _saveSrt();
      case CaptionExportFormat.ass:
        await _saveAss();
      case CaptionExportFormat.vtt:
        await _saveVtt();
      case CaptionExportFormat.txt:
        await _saveTxt();
      case CaptionExportFormat.copy:
        await _copyCaptions();
      case CaptionExportFormat.video:
        await _exportVideo();
    }
  }

  String _exportLabel(CaptionExportFormat format) => switch (format) {
        CaptionExportFormat.srt => 'SRT',
        CaptionExportFormat.ass => 'ASS',
        CaptionExportFormat.vtt => 'VTT',
        CaptionExportFormat.txt => 'TXT',
        CaptionExportFormat.copy => 'Copy text',
        CaptionExportFormat.video => 'Video MP4 (burned)',
      };
}

