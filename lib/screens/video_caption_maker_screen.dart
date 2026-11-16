import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

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

/// Video Caption Maker (AI) (v1.0.3 batch 2, styles in v1.0.6): pick a
/// video file, transcribe its audio via the proxy's POST /transcribe,
/// then style the captions — 11 CapCut-style looks (Nigraan Karaoke,
/// Bold Pop, Pop Up, Karaoke Fill, Highlight Box, Typewriter, One Word,
/// Classic, News Ticker, Spotlight, Minimal), English + Urdu, with
/// position / size / highlight-colour / font controls. The player preview
/// plays the video with the styled caption overlaid, synced to
/// playback. Caption lines can be edited (fix misheard words) or
/// deleted. Exports: plain SRT + a styled ASS file (opens in CapCut
/// and any ASS-capable editor, with the chosen look).
///
/// COINS + SRT/ASS AD GATE: exactly the same as the AI Caption
/// Generator — 50 coins per minute (rounded up, min 50) charged
/// BEFORE transcribing (refunded in full if transcription fails), and
/// the SRT/ASS save goes through AudioDownloadService
/// .downloadBytesWithAd (1 rewarded ad, then the file saves;
/// fail-soft; skip = no delivery).
///
/// HONEST LIMIT — NO BURN-IN: burning captions INTO the video file
/// needs server-side ffmpeg, which Cloudflare Workers cannot run. This
/// screen delivers styled captions + SRT + styled ASS + the in-player
/// preview only. A burned-in captioned video file is a follow-up
/// needing server infrastructure (see README "Known v1 limits /
/// follow-ups").
class VideoCaptionMakerScreen extends StatefulWidget {
  final CoinsService coins;

  const VideoCaptionMakerScreen({super.key, required this.coins});

  @override
  State<VideoCaptionMakerScreen> createState() =>
      _VideoCaptionMakerScreenState();
}

class _VideoCaptionMakerScreenState extends State<VideoCaptionMakerScreen> {
  File? _file;
  String? _fileName;
  VideoPlayerController? _controller;
  bool _playerReady = false;
  String _lang = 'ur';
  bool _busy = false;
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

  Duration? get _duration =>
      _playerReady ? _controller?.value.duration : null;

  int get _cost =>
      CaptionService.costForDuration(_duration, widget.coins.coinsPerMinute);

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
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
      setState(() => _playerReady = true);
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
      });
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
              '50 coins per minute. Then pick a caption style (11 styles, '
              'English + Urdu, Jameel Noori + display fonts) and watch '
              'the styled preview. Save as SRT or styled ASS. Captions '
              'are NOT burned into the video file '
              '(that needs server-side ffmpeg — see the note below).',
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
                            child: StyledCaptionText(
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
                '  •  Cost: $_cost coins',
                style: const TextStyle(fontWeight: FontWeight.bold),
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
