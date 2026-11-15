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
import '../services/coins_service.dart';

/// Video Caption Maker (AI) (v1.0.3 batch 2): pick a video file,
/// transcribe its audio via the proxy's POST /transcribe, show the
/// captions list + SRT download + an IN-PLAYER caption preview — the
/// video plays with the current caption line overlaid at the bottom,
/// synced to the playback position.
///
/// COINS + SRT AD GATE: exactly the same as the AI Caption Generator —
/// 50 coins per minute (rounded up, min 50) charged BEFORE transcribing
/// (refunded in full if transcription fails), and the SRT save goes
/// through AudioDownloadService.downloadBytesWithAd (1 rewarded ad,
/// then the file saves; fail-soft; skip = no delivery).
///
/// HONEST LIMIT — NO BURN-IN: burning captions INTO the video file
/// needs server-side ffmpeg, which Cloudflare Workers cannot run. This
/// screen delivers captions + SRT + the in-player preview only. A
/// burned-in captioned video file is a follow-up needing server
/// infrastructure (see README "Known v1 limits / follow-ups").
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
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.video,
    );
    if (picked == null || picked.files.isEmpty) return;
    final path = picked.files.single.path;
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
      });
      return;
    }
    await _controller?.dispose();
    final controller = VideoPlayerController.file(file);
    setState(() {
      _file = file;
      _fileName = picked.files.single.name;
      _controller = controller;
      _playerReady = false;
      _result = null;
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
      setState(() => _result = result);
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
    final result = _result;
    if (result == null) return;
    await Clipboard.setData(ClipboardData(text: result.srt));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Captions copied.')),
    );
  }

  Future<void> _saveSrt() async {
    final result = _result;
    final name = _fileName;
    if (result == null || name == null) return;
    final base = name.contains('.')
        ? name.substring(0, name.lastIndexOf('.'))
        : name;
    await AudioDownloadService.downloadBytesWithAd(
      context,
      fileName: '$base.srt',
      bytes: utf8.encode(result.srt),
    );
  }

  /// The caption line whose time range contains [position], if any.
  CaptionSegment? _currentCaption(Duration position) {
    final result = _result;
    if (result == null) return null;
    final pos = position.inMilliseconds / 1000;
    for (final seg in result.segments) {
      if (pos >= seg.start && pos < seg.end) return seg;
    }
    return null;
  }

  String _clockLabel(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

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
                  onSelectionChanged: (s) => setState(() => _lang = s.first),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Pick a video. Its audio is transcribed into captions — '
              '50 coins per minute. The preview below plays the video '
              'with the current caption overlaid. Captions are NOT burned '
              'into the video file (that needs server-side ffmpeg — see '
              'the note below); you get the captions + an SRT file.',
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
                  alignment: Alignment.bottomCenter,
                  children: [
                    VideoPlayer(controller),
                    // In-player caption preview, synced to playback.
                    ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: controller,
                      builder: (context, value, _) {
                        final caption = _currentCaption(value.position);
                        if (caption == null) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              caption.text,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
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
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${result.segments.length} caption lines',
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
                ],
              ),
              const SizedBox(height: 8),
              for (final seg in result.segments)
                Card(
                  child: ListTile(
                    leading: Chip(
                      label: Text(
                        seg.timeLabel,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    title: Text(seg.text),
                  ),
                ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: const UnityBannerAdWidget(zone: 'tools'),
    );
  }
}
