import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

/// AI Caption Generator (v1.0.3 batch 2, styles in v1.0.6, Caption
/// Studio redesign v1.0.10): pick an audio or video file, transcribe
/// it via the proxy's POST /transcribe, then style the captions — 11
/// CapCut-style looks (Nigraan Karaoke, Bold Pop, Pop Up, Karaoke
/// Fill, Highlight Box, Typewriter, One Word, Classic, News Ticker,
/// Spotlight, Minimal), English + Urdu, with position / size /
/// highlight-colour / font controls and a live animated preview.
/// Caption lines can be edited (fix misheard words), split, merged,
/// re-timed, shifted, or deleted. Exports: SRT, ASS, VTT, TXT,
/// plain-text copy — and, for a video file, the video itself with
/// captions burned in (on-device ffmpeg, 720p/1080p).
///
/// COINS: 50 per minute of media (same rate as TTS generation),
/// rounded up to whole minutes, minimum 50 — charged through the
/// existing audiobox-spend-coins function BEFORE transcribing (see
/// CaptionService.transcribeCharged; refunded in full if
/// transcription fails). Too few coins → a message pointing at the
/// Coins tab.
///
/// SRT/ASS/VTT/TXT DELIVERY: the file save goes through the existing
/// AudioDownloadService.downloadBytesWithAds with the remote-config
/// downloadAdsRequired count (default 2, both fully watched).
/// VIDEO EXPORT AD: ONE rewarded ad, shown BEFORE the burn-in runs
/// (ad-unlock, fail-soft — skipped = no export, unavailable = the
/// export runs anyway); that same ad covers the download, no second
/// ad for the same file. Copying captions is free (no ad).
///
/// WORD TIMING: the proxy returns real Whisper word timings, so the
/// karaoke / pop / typewriter styles highlight the word actually
/// being spoken — no even-split guessing (manual lines without word
/// timings fall back to even-split).
class CaptionGeneratorScreen extends StatefulWidget {
  final CoinsService coins;

  const CaptionGeneratorScreen({super.key, required this.coins});

  @override
  State<CaptionGeneratorScreen> createState() =>
      _CaptionGeneratorScreenState();
}

class _CaptionGeneratorScreenState extends State<CaptionGeneratorScreen> {
  static const String _draftKey = 'caption_generator';

  File? _file;
  String? _fileName;
  Duration? _duration;
  VideoSize? _videoSize;
  String _lang = 'ur';
  bool _busy = false;
  bool _probing = false;
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

  // Live preview clock: loops through the segments.
  Timer? _previewTimer;
  double _previewSeconds = 0;

  int get _cost =>
      CaptionService.costForDuration(_duration, widget.coins.coinsPerMinute);

  bool get _isVideoFile =>
      _fileName != null && CaptionService.isVideoPath(_fileName!);

  ({int x, int y}) get _assCanvas =>
      _videoSize?.assCanvas ?? (x: 1280, y: 720);

  @override
  void initState() {
    super.initState();
    _restoreDraft();
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    _previewTimer?.cancel();
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
    final duration = await CaptionService.probeMediaDuration(file);
    if (!mounted) return;
    if (duration != null &&
        duration.inSeconds > CaptionService.maxDurationSeconds) {
      await CaptionDraftService.clearDraft(_draftKey);
      return;
    }
    final videoSize = _isVideoPathFor(path)
        ? await VideoExportService.probeVideoSize(file)
        : null;
    if (!mounted) return;
    setState(() {
      _file = file;
      _fileName = (draft['fileName'] ?? '').toString();
      _duration = duration;
      _videoSize = videoSize;
      _applyDraftSettings(draft);
      _draftRestored = true;
      _message = 'Draft restored — your last captions are back.';
    });
    if (_segments.isNotEmpty) _startPreview();
  }

  bool _isVideoPathFor(String path) => CaptionService.isVideoPath(path);

  /// Apply a loaded draft's settings (shared by pick + init).
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
    setState(() {
      _selectedIndex = index;
      _previewSeconds = _segments[index].start;
    });
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

  void _startPreview() {
    _previewTimer?.cancel();
    _previewSeconds = 0;
    _previewTimer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!mounted || _segments.isEmpty) return;
      setState(() {
        _previewSeconds += 0.15;
        final end = _segments.last.end;
        if (_previewSeconds >= end) _previewSeconds = 0;
      });
    });
  }

  CaptionSegment? _previewSegment() {
    if (_segments.isEmpty) return null;
    for (final seg in _segments) {
      if (_previewSeconds >= seg.start && _previewSeconds < seg.end) {
        return seg;
      }
    }
    return null;
  }

  Alignment _positionAlign() => switch (_position) {
        CaptionPosition.top => Alignment.topCenter,
        CaptionPosition.middle => Alignment.center,
        CaptionPosition.bottom => Alignment.bottomCenter,
      };

  Future<void> _pickFile() async {
    if (_busy) return;
    // file_picker 13.x API: FilePicker.pickFile() returns a single
    // PlatformFile (null on cancel); the old FilePicker.platform
    // + FilePickerResult API is gone in 13.x.
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: CaptionService.allMediaExtensions,
    );
    if (picked == null) return;
    final path = picked.path;
    if (path == null) {
      if (mounted) {
        setState(() => _message = 'Could not read that file.');
      }
      return;
    }
    final file = File(path);
    final size = await file.length();
    if (size > CaptionService.maxFileBytes) {
      if (!mounted) return;
      setState(() {
        _file = null;
        _fileName = null;
        _duration = null;
        _videoSize = null;
        _result = null;
        _segments = [];
        _message = 'File is too large — max 25 MB.';
      });
      return;
    }
    setState(() {
      _file = file;
      _fileName = picked.name;
      _duration = null;
      _videoSize = null;
      _result = null;
      _segments = [];
      _selectedIndex = -1;
      _undoStack.clear();
      _redoStack.clear();
      _message = null;
      _probing = true;
    });
    final duration = await CaptionService.probeMediaDuration(file);
    final videoSize = CaptionService.isVideoPath(path)
        ? await VideoExportService.probeVideoSize(file)
        : null;
    if (!mounted) return;
    setState(() {
      _duration = duration;
      _videoSize = videoSize;
      _probing = false;
      if (duration != null &&
          duration.inSeconds > CaptionService.maxDurationSeconds) {
        _message = 'Media is too long — max 10 minutes.';
        _file = null;
        _fileName = null;
        _duration = null;
        _videoSize = null;
      }
    });
    // Same file as the saved draft? Restore the draft's captions.
    if (_file != null) {
      final draft = await CaptionDraftService.loadDraft(_draftKey);
      if (!mounted || _file == null) return;
      if (draft != null &&
          (draft['fileName'] ?? '') == picked.name &&
          (draft['segments'] is List) &&
          (draft['segments'] as List).isNotEmpty) {
        setState(() {
          _applyDraftSettings(draft);
          _draftRestored = true;
          _message = 'Draft restored — your last captions are back.';
        });
        _startPreview();
      }
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
      _startPreview();
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
    if (file == null || !_isVideoFile || _segments.isEmpty || _exporting) {
      if (file != null && !_isVideoFile && mounted) {
        setState(
          () => _message = 'Video export needs a video file — '
              'this one is audio only.',
        );
      }
      return;
    }
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
    if (_duration != null && start > _duration!.inSeconds) {
      setState(() => _message = 'Start time is past the media length.');
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

  String _durationLabel() {
    final d = _duration;
    if (d == null) return _probing ? 'Reading duration…' : 'Duration unknown';
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context);
    final result = _result;
    final previewSeg = _previewSegment();
    return Scaffold(
      appBar: AppBar(
        title: Text(AppStrings.tr('caption_generator', locale)),
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
              'Pick an audio or video file. Its speech is transcribed '
              'into time-stamped captions — 50 coins per minute of '
              'media. Pick a caption style first if you like (11 '
              'styles, English + Urdu, Jameel Noori + display fonts), '
              'then transcribe, edit the lines, and save as SRT, ASS, '
              'VTT or TXT. Pick a video file to also export it with '
              'captions burned in.',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickFile,
              icon: const Icon(Icons.attach_file),
              label: const Text('Pick audio or video file'),
            ),
            if (_fileName != null) ...[
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: Icon(
                    CaptionService.isVideoPath(_fileName!)
                        ? Icons.video_file
                        : Icons.audio_file,
                  ),
                  title: Text(_fileName!),
                  subtitle: Text(
                    'Duration: ${_durationLabel()}  •  Cost: $_cost coins'
                    '${(_videoSize?.isVertical ?? false) ? '  •  Vertical video (1080×1920 captions)' : ''}',
                  ),
                ),
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
              // Live animated preview of the styled captions.
              Container(
                height: 180,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Align(
                  alignment: _positionAlign(),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: previewSeg == null
                        ? const SizedBox.shrink()
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              StyledCaptionText(
                                text: previewSeg.text,
                                start: previewSeg.start,
                                end: previewSeg.end,
                                positionSeconds: _previewSeconds,
                                style: _style,
                                size: _size,
                                highlightColor: _highlight,
                                lang: _lang,
                                fontFamily: _font.family,
                                words: previewSeg.words,
                                outline: _fxOutline,
                                shadow: _fxShadow,
                                background: _fxBackground,
                              ),
                              if (_dualLanguage &&
                                  previewSeg.translation.trim().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    previewSeg.translation,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: _style.fontSizePx *
                                          CaptionStyles.sizeScale(_size) *
                                          0.7,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
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
              if (_isVideoFile) ...[
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
              ],
              const SizedBox(height: 6),
              Text(
                'Export: SRT • ASS • VTT • TXT'
                '${_isVideoFile ? ' • Video MP4 (burned)' : ''}\n'
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
  /// video quality, and dual captions, then export. The Video MP4
  /// tile is disabled for audio-only files.
  Future<void> _showExportSheet() async {
    if (_segments.isEmpty) return;
    var format = CaptionExportFormat.srt;
    var quality = _quality;
    var dual = _dualLanguage;
    final videoAvailable = _isVideoFile;
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
            bool enabled = true,
          }) {
            final selected = format == f;
            return GestureDetector(
              onTap: enabled
                  ? () => setSheetState(() => format = f)
                  : null,
              child: Opacity(
                opacity: enabled ? 1 : 0.4,
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
                          videoAvailable
                              ? 'Captions video mein burned — TikTok ready'
                              : 'Video MP4 needs a video file',
                          isNew: true,
                          enabled: videoAvailable,
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
                              color: dual ? Colors.red : Colors.white54,
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

  String _exportLabel(CaptionExportFormat format) =>
      switch (format) {
        CaptionExportFormat.srt => 'SRT',
        CaptionExportFormat.ass => 'ASS',
        CaptionExportFormat.vtt => 'VTT',
        CaptionExportFormat.txt => 'TXT',
        CaptionExportFormat.copy => 'Copy text',
        CaptionExportFormat.video => 'Video MP4 (burned)',
      };
}
