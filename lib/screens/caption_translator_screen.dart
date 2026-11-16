import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/audio_download_service.dart';
import '../services/caption_service.dart';
import '../services/caption_styles.dart';
import '../services/coins_service.dart';
import '../services/remote_config_service.dart';
import '../services/translation_service.dart';
import '../widgets/caption_style_picker.dart';
import '../widgets/help_whatsapp_button.dart';

/// Caption Translator (v1.0.8, free) — Urdu↔English, fully on-device
/// with ML Kit. No server, no paid API, no keys.
///
/// Entry points (route/entry name: `CaptionTranslatorScreen`):
/// - Tools list card "Caption Translator".
/// - "Translate" button on the AI Caption Generator and the Video
///   Caption Maker, once captions exist (segments passed in).
/// - Without segments: paste SRT text or pick an .srt file, and the
///   screen parses it into timed segments itself.
///
/// Cost: 25 coins per started minute of media (same rounding as
/// captions), charged BEFORE translating and refunded in full when
/// translation fails. The language models download once on first use
/// (about 30 MB per language, mobile data allowed); after that the
/// translation works offline. Export: translated SRT + styled ASS
/// (same ad gate as other caption downloads).
class CaptionTranslatorScreen extends StatefulWidget {
  final CoinsService coins;

  /// Timed captions to translate (from the Caption Generator / Video
  /// Caption Maker). Null = the user pastes or picks SRT text instead.
  final List<CaptionSegment>? segments;

  /// Language the [segments] are in ('ur' or 'en').
  final String sourceLang;

  /// Media duration, for the coin cost (falls back to the last
  /// segment's end time when null).
  final Duration? mediaDuration;

  /// File name used for the exported SRT/ASS files.
  final String? fileName;

  const CaptionTranslatorScreen({
    super.key,
    required this.coins,
    this.segments,
    this.sourceLang = 'ur',
    this.mediaDuration,
    this.fileName,
  });

  @override
  State<CaptionTranslatorScreen> createState() =>
      _CaptionTranslatorScreenState();
}

class _CaptionTranslatorScreenState extends State<CaptionTranslatorScreen> {
  late String _sourceLang;
  List<CaptionSegment> _segments = [];
  List<CaptionSegment> _translated = [];
  final TextEditingController _srtController = TextEditingController();
  bool _busy = false;
  String? _status;
  String? _message;
  int _done = 0;
  int _total = 0;

  CaptionStyle _style = CaptionStyles.all.first;

  String get _targetLang => _sourceLang == 'ur' ? 'en' : 'ur';

  String get _targetLangName => _targetLang == 'ur' ? 'اردو' : 'English';

  String get _sourceLangName => _sourceLang == 'ur' ? 'اردو' : 'English';

  Duration? get _duration {
    if (widget.mediaDuration != null) return widget.mediaDuration;
    if (_segments.isEmpty) return null;
    return Duration(
      milliseconds: (_segments.last.end * 1000).round(),
    );
  }

  int get _cost => TranslationService.costForDuration(_duration);

  @override
  void initState() {
    super.initState();
    _sourceLang = widget.sourceLang;
    if (widget.segments != null) {
      _segments = List.of(widget.segments!);
    }
  }

  @override
  void dispose() {
    _srtController.dispose();
    super.dispose();
  }

  Future<void> _pickSrtFile() async {
    if (_busy) return;
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['srt', 'txt'],
    );
    if (picked == null || picked.path == null) return;
    try {
      final text = await File(picked.path!).readAsString();
      _loadSrtText(text);
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not read that file: $e');
    }
  }

  void _loadSrtText(String text) {
    try {
      final segments = TranslationService.parseSrt(text);
      setState(() {
        _segments = segments;
        _translated = [];
        _message = null;
      });
    } catch (e) {
      setState(() => _message = e.toString());
    }
  }

  Future<void> _translate() async {
    if (_segments.isEmpty || _busy) return;
    if (!widget.coins.canAfford(_cost)) {
      setState(() => _message =
          'Not enough coins — translation costs $_cost coins. '
          'Open the Coins tab to earn more.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _done = 0;
      _total = _segments.length;
      _status = 'Downloading language models (first use only)…';
    });
    try {
      final translated = await TranslationService.translateCharged(
        coins: widget.coins,
        segments: _segments,
        fromLang: _sourceLang,
        toLang: _targetLang,
        duration: _duration,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
            _status = 'Translating line $done of $total…';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _translated = translated;
        _status = null;
        _style = CaptionStyles.all.first;
      });
    } on InsufficientCoinsException {
      if (!mounted) return;
      setState(() => _message =
          'Not enough coins — translation costs $_cost coins. '
          'Open the Coins tab to earn more.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = 'Translation failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }

  Future<void> _editTranslated(int index) async {
    final seg = _translated[index];
    final controller = TextEditingController(text: seg.text);
    final edited = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit translation'),
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
      _translated[index] = CaptionSegment(
        start: seg.start,
        end: seg.end,
        text: edited,
      );
    });
  }

  Future<void> _copyTranslated() async {
    if (_translated.isEmpty) return;
    await Clipboard.setData(
      ClipboardData(text: CaptionService.buildSrt(_translated)),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Translated captions copied.')),
    );
  }

  String _exportBaseName() {
    final name = widget.fileName;
    if (name == null || name.isEmpty) return 'captions-$_targetLang';
    final base =
        name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
    return '$base-$_targetLang';
  }

  Future<void> _saveSrt() async {
    if (_translated.isEmpty) return;
    await AudioDownloadService.downloadBytesWithAds(
      context,
      adsRequired: RemoteConfigService.instance.config.downloadAdsRequired,
      fileName: '${_exportBaseName()}.srt',
      bytes: utf8.encode(CaptionService.buildSrt(_translated)),
    );
  }

  Future<void> _saveAss() async {
    if (_translated.isEmpty) return;
    await AudioDownloadService.downloadBytesWithAds(
      context,
      adsRequired: RemoteConfigService.instance.config.downloadAdsRequired,
      fileName: '${_exportBaseName()}.ass',
      bytes: utf8.encode(
        CaptionService.buildAss(
          _translated,
          _style,
          position: CaptionPosition.bottom,
          size: CaptionSize.medium,
          fontFamily: CaptionFonts.forLang(_targetLang).first.family,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context);
    final hasSegments = _segments.isNotEmpty;
    final translatedReady = _translated.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          locale.languageCode == 'ur'
              ? 'کیپشن مترجم'
              : 'Caption Translator',
        ),
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
                        'Balance: $balance coins',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      );
                    },
                  ),
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'ur', label: Text('اردو → EN')),
                    ButtonSegment(value: 'en', label: Text('EN → اردو')),
                  ],
                  selected: {_sourceLang},
                  onSelectionChanged: (s) => setState(() {
                    _sourceLang = s.first;
                    _translated = [];
                  }),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Translates captions from $_sourceLangName to '
              '$_targetLangName, on your phone — no server, no extra '
              'cost beyond $_cost coins for this file. The language '
              'models download once on first use.',
            ),
            const SizedBox(height: 12),
            if (!hasSegments) ...[
              TextField(
                controller: _srtController,
                maxLines: 6,
                minLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Paste SRT captions here…',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _loadSrtText(_srtController.text),
                      icon: const Icon(Icons.text_fields),
                      label: const Text('Use pasted SRT'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _pickSrtFile,
                      icon: const Icon(Icons.attach_file),
                      label: const Text('Pick .srt file'),
                    ),
                  ),
                ],
              ),
            ] else ...[
              Card(
                child: ListTile(
                  leading: const Icon(Icons.closed_caption),
                  title: Text('${_segments.length} caption lines loaded'),
                  subtitle: Text(
                    '$_sourceLangName → $_targetLangName  •  Cost: $_cost coins',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Clear',
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _segments = [];
                              _translated = [];
                            }),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: (_busy || translatedReady) ? null : _translate,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.translate),
                label: Text(
                  _busy
                      ? 'Translating…'
                      : translatedReady
                          ? 'Translated'
                          : 'Translate ($_cost coins)',
                ),
              ),
              if (_busy && _total > 0) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: _done / _total,
                ),
              ],
              if (_status != null) ...[
                const SizedBox(height: 8),
                Text(_status!, style: const TextStyle(color: Colors.grey)),
              ],
            ],
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(_message!, style: const TextStyle(color: Colors.red)),
            ],
            if (translatedReady) ...[
              const SizedBox(height: 16),
              CaptionStylePicker(
                selected: _style,
                lang: _targetLang,
                onStyleSelected: (s) => setState(() => _style = s),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_translated.length} translated lines',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _copyTranslated,
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
              for (var i = 0; i < _translated.length; i++)
                Card(
                  child: ListTile(
                    leading: Chip(
                      label: Text(
                        _translated[i].timeLabel,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    title: Text(_translated[i].text),
                    subtitle: Text(
                      _segments[i].text,
                      style: const TextStyle(color: Colors.grey),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit, size: 20),
                      tooltip: 'Edit',
                      onPressed: () => _editTranslated(i),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              HelpWhatsAppRow(lang: _targetLang),
            ],
          ],
        ),
      ),
    );
  }
}
