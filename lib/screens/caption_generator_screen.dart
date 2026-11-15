import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../services/ads_service.dart';
import '../services/audio_download_service.dart';
import '../services/caption_service.dart';
import '../services/coins_service.dart';

/// AI Caption Generator (v1.0.3 batch 2): pick an audio or video file,
/// transcribe it via the proxy's POST /transcribe, show the captions
/// with timestamps, copy them, and save them as an SRT file.
///
/// COINS: 50 per minute of media (same rate as TTS generation), rounded
/// up to whole minutes, minimum 50 — charged through the existing
/// audiobox-spend-coins function BEFORE transcribing (see
/// CaptionService.transcribeCharged; refunded in full if transcription
/// fails). Too few coins → a message pointing at the Coins tab.
///
/// SRT DELIVERY: the file save goes through the existing
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

  int get _cost =>
      CaptionService.costForDuration(_duration, widget.coins.coinsPerMinute);

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
        _message = 'File is too large — max 25 MB.';
      });
      return;
    }
    setState(() {
      _file = file;
      _fileName = picked.name;
      _duration = null;
      _result = null;
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
                  onSelectionChanged: (s) => setState(() => _lang = s.first),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Pick an audio or video file. Its speech is transcribed into '
              'time-stamped captions — 50 coins per minute of media.',
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
