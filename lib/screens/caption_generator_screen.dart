import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../services/ads_service.dart';
import '../services/audio_download_service.dart';
import '../services/caption_service.dart';
import '../services/caption_styles.dart';
import '../services/coins_service.dart';
import '../services/remote_config_service.dart';
import '../widgets/caption_style_picker.dart';
import '../widgets/help_whatsapp_button.dart';
import '../widgets/styled_caption_text.dart';

/// AI Caption Generator (v1.0.3 batch 2, styles in v1.0.6): pick an
/// audio or video file, transcribe it via the proxy's POST /transcribe,
/// then style the captions — 11 CapCut-style looks (Nigraan Karaoke,
/// Bold Pop, Pop Up, Karaoke Fill, Highlight Box, Typewriter, One Word,
/// Classic, News Ticker, Spotlight, Minimal), English + Urdu, with
/// position / size / highlight-colour / font controls and a live animated
/// preview. Caption lines can be edited (fix misheard words) or
/// deleted. Exports: plain SRT + a styled ASS file (opens in CapCut
/// and any ASS-capable editor, with the chosen look).
///
/// COINS: 50 per minute of media (same rate as TTS generation), rounded
/// up to whole minutes, minimum 50 — charged through the existing
/// audiobox-spend-coins function BEFORE transcribing (see
/// CaptionService.transcribeCharged; refunded in full if transcription
/// fails). Too few coins → a message pointing at the Coins tab.
///
/// SRT/ASS DELIVERY: the file save goes through the existing
/// AudioDownloadService.downloadBytesWithAd — 1 rewarded video ad,
/// then the file saves to Downloads; fail-soft when ads are off or no
/// ad loads; skip = no delivery. Copying captions is free (no ad).
class CaptionGeneratorScreen extends StatefulWidget {
  final CoinsService coins;

  const CaptionGeneratorScreen({super.key, required this.coins});

  @override
  State<CaptionGeneratorScreen> createState() =>
      _CaptionGeneratorScreenState();
}

class _CaptionGeneratorScreenState extends State<CaptionGeneratorScreen> {
  File? _file;
  String? _fileName;
  Duration? _duration;
  String _lang = 'ur';
  bool _busy = false;
  bool _probing = false;
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

  // Live preview clock: loops through the segments.
  Timer? _previewTimer;
  double _previewSeconds = 0;

  int get _cost =>
      CaptionService.costForDuration(_duration, widget.coins.coinsPerMinute);

  @override
  void dispose() {
    _previewTimer?.cancel();
    super.dispose();
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
      _result = null;
      _segments = [];
      _message = null;
      _probing = true;
    });
    final duration = await CaptionService.probeMediaDuration(file);
    if (!mounted) return;
    setState(() {
      _duration = duration;
      _probing = false;
      if (duration != null &&
          duration.inSeconds > CaptionService.maxDurationSeconds) {
        _message = 'Media is too long — max 10 minutes.';
        _file = null;
        _fileName = null;
        _duration = null;
      }
    });
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
      });
      _startPreview();
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
    await Clipboard.setData(
      ClipboardData(text: CaptionService.buildSrt(_segments)),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Captions copied.')),
    );
  }

  Future<void> _saveSrt() async {
    final name = _fileName;
    if (_segments.isEmpty || name == null) return;
    final base = name.contains('.')
        ? name.substring(0, name.lastIndexOf('.'))
        : name;
    await AudioDownloadService.downloadBytesWithAds(
      context,
      adsRequired:
          RemoteConfigService.instance.config.downloadAdsRequired,
      fileName: '$base.srt',
      bytes: utf8.encode(CaptionService.buildSrt(_segments)),
    );
  }

  Future<void> _saveAss() async {
    final name = _fileName;
    if (_segments.isEmpty || name == null) return;
    final base = name.contains('.')
        ? name.substring(0, name.lastIndexOf('.'))
        : name;
    await AudioDownloadService.downloadBytesWithAds(
      context,
      adsRequired:
          RemoteConfigService.instance.config.downloadAdsRequired,
      fileName: '$base.ass',
      bytes: utf8.encode(
        CaptionService.buildAss(
          _segments,
          _style,
          position: _position,
          size: _size,
          highlightColor: _highlight,
          fontFamily: _font.family,
        ),
      ),
    );
  }

  Future<void> _editSegment(int index) async {
    final seg = _segments[index];
    final controller = TextEditingController(text: seg.text);
    final edited = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          Localizations.localeOf(context).languageCode == 'ur'
              ? 'کیپشن بدلیں'
              : 'Edit caption',
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (edited == null || edited.isEmpty || !mounted) return;
    setState(() {
      _segments[index] = CaptionSegment(
        start: seg.start,
        end: seg.end,
        text: edited,
      );
    });
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
              'Pick an audio or video file. Its speech is transcribed into '
              'time-stamped captions — 50 coins per minute of media. Then '
              'pick a caption style (11 styles, English + Urdu, Jameel '
              'Noori + display fonts) and save as SRT or styled ASS.',
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
                    'Duration: ${_durationLabel()}  •  Cost: $_cost coins',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: (_busy || result != null) ? null : _transcribe,
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
                          ? 'Captions ready'
                          : 'Transcribe ($_cost coins)',
                ),
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(_message!, style: const TextStyle(color: Colors.red)),
            ],
            if (result != null) ...[
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
                        : StyledCaptionText(
                            text: previewSeg.text,
                            start: previewSeg.start,
                            end: previewSeg.end,
                            positionSeconds: _previewSeconds,
                            style: _style,
                            size: _size,
                            highlightColor: _highlight,
                            lang: _lang,
                            fontFamily: _font.family,
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              CaptionStylePicker(
                selected: _style,
                lang: _lang,
                onStyleSelected: (s) => setState(() {
                  _style = s;
                  _position = s.position;
                  _highlight = s.highlightColor;
                }),
              ),
              const SizedBox(height: 12),
              CaptionStyleControls(
                position: _position,
                onPositionChanged: (p) => setState(() => _position = p),
                size: _size,
                onSizeChanged: (s) => setState(() => _size = s),
                highlightColor: _highlight,
                onHighlightChanged: (c) => setState(() => _highlight = c),
                lang: _lang,
                font: _font,
                onFontChanged: (f) => setState(() => _font = f),
              ),
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
                  TextButton.icon(
                    onPressed: _saveSrt,
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Save SRT'),
                  ),
                  TextButton.icon(
                    onPressed: _saveAss,
                    icon: const Icon(Icons.style, size: 18),
                    label: const Text('Save ASS'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < _segments.length; i++)
                Card(
                  child: ListTile(
                    leading: Chip(
                      label: Text(
                        _segments[i].timeLabel,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    title: Text(_segments[i].text),
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
                          onPressed: () => setState(
                            () => _segments.removeAt(i),
                          ),
                        ),
                      ],
                    ),
                  ),
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
}
