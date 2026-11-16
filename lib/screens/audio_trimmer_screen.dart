import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/audio_item.dart';
import '../services/audio_download_service.dart';
import '../services/audio_edit_service.dart';
import '../services/audio_library_service.dart';
import '../services/coins_service.dart';
import '../widgets/audio_player_bar.dart';

/// Audio Trimmer & Joiner (v1.0.8, free) — fully on-device.
///
/// Entry point (route/entry name: `AudioTrimmerScreen`): the Tools
/// list card "Audio Trimmer & Joiner".
///
/// Trim: pick a WAV or MP3 file, drag the start/end handles, save a
/// trimmed copy. Join: pick several files of the SAME format (all WAV
/// or all MP3), reorder them, save one joined file. WAV trim is
/// sample-accurate; MP3 trim is frame-accurate. WAV joins need the
/// same sample rate / channels / bit depth. No server, no paid API,
/// no ffmpeg — and no coins: editing is free. Downloading a saved
/// file goes through the usual one-ad gate.
class AudioTrimmerScreen extends StatefulWidget {
  final CoinsService coins;
  final AudioLibraryService library;

  const AudioTrimmerScreen({
    super.key,
    required this.coins,
    required this.library,
  });

  @override
  State<AudioTrimmerScreen> createState() => _AudioTrimmerScreenState();
}

class _PickedAudio {
  final File file;
  final String name;
  final Duration? duration;

  const _PickedAudio({
    required this.file,
    required this.name,
    this.duration,
  });
}

class _AudioTrimmerScreenState extends State<AudioTrimmerScreen> {
  String _mode = 'trim';
  bool _busy = false;
  String? _message;
  AudioItem? _result;

  // Trim state.
  _PickedAudio? _trimFile;
  double _trimStart = 0;
  double _trimEnd = 0;

  // Join state.
  List<_PickedAudio> _joinFiles = [];

  String _clock(double seconds) {
    final totalMs = (seconds * 1000).round();
    final m = totalMs ~/ 60000;
    final s = (totalMs % 60000) ~/ 1000;
    final d = (totalMs % 1000) ~/ 100;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.$d';
  }

  Future<void> _pickTrimFile() async {
    if (_busy) return;
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: AudioEditService.supportedExtensions,
    );
    if (picked == null || picked.path == null) return;
    final file = File(picked.path!);
    setState(() {
      _trimFile = null;
      _result = null;
      _message = null;
      _busy = true;
    });
    try {
      final duration = await AudioEditService.probeDuration(file);
      if (!mounted) return;
      setState(() {
        _trimFile = _PickedAudio(
          file: file,
          name: picked.name,
          duration: duration,
        );
        _trimStart = 0;
        _trimEnd = (duration?.inMilliseconds ?? 0) / 1000;
      });
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not read file: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _trimAndSave() async {
    final picked = _trimFile;
    if (picked == null || _busy) return;
    final duration = picked.duration;
    if (duration == null) {
      setState(() => _message = 'Duration unknown — cannot trim.');
      return;
    }
    if (_trimEnd - _trimStart < 0.1) {
      setState(() => _message = 'Pick a range of at least 0.1 seconds.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _result = null;
    });
    try {
      final bytes = await AudioEditService.trim(
        picked.file,
        Duration(milliseconds: (_trimStart * 1000).round()),
        Duration(milliseconds: (_trimEnd * 1000).round()),
      );
      final ext = AudioEditService.extensionOf(picked.file.path);
      final base = picked.name.contains('.')
          ? picked.name.substring(0, picked.name.lastIndexOf('.'))
          : picked.name;
      final item = await widget.library.saveFile(
        title: '$base (trimmed)',
        bytes: bytes,
        ext: ext,
      );
      if (!mounted) return;
      setState(() => _result = item);
    } catch (e) {
      if (mounted) setState(() => _message = 'Trim failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickJoinFiles() async {
    if (_busy) return;
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: AudioEditService.supportedExtensions,
    );
    if (picked.isEmpty) return;
    setState(() {
      _busy = true;
      _message = null;
      _result = null;
    });
    try {
      final pickedList = <_PickedAudio>[];
      for (final f in picked) {
        if (f.path == null) continue;
        final file = File(f.path!);
        final duration = await AudioEditService.probeDuration(file);
        pickedList.add(
          _PickedAudio(file: file, name: f.name, duration: duration),
        );
      }
      if (!mounted) return;
      setState(() => _joinFiles = pickedList);
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not read files: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _joinAndSave() async {
    if (_joinFiles.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _result = null;
    });
    try {
      final bytes = await AudioEditService.join(
        _joinFiles.map((p) => p.file).toList(),
      );
      final ext = AudioEditService.extensionOf(_joinFiles.first.file.path);
      final item = await widget.library.saveFile(
        title: 'Joined audio (${_joinFiles.length} files)',
        bytes: bytes,
        ext: ext,
      );
      if (!mounted) return;
      setState(() => _result = item);
    } catch (e) {
      if (mounted) setState(() => _message = 'Join failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _resultCard() {
    final item = _result;
    if (item == null) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AudioPlayerBar(
              file: File(item.filePath),
              title: item.displayTitle,
            ),
            TextButton.icon(
              onPressed: () =>
                  AudioDownloadService.downloadWithAd(context, item),
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Download (1 ad)'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trimFile = _trimFile;
    final trimDuration = trimFile?.duration;
    final trimSeconds =
        trimDuration == null ? 0.0 : trimDuration.inMilliseconds / 1000;
    return Scaffold(
      appBar: AppBar(title: const Text('Audio Trimmer & Joiner')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Trim audio or join several clips into one — on your phone, '
              'free, no coins. WAV and MP3 only.',
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'trim',
                  icon: Icon(Icons.content_cut),
                  label: Text('Trim'),
                ),
                ButtonSegment(
                  value: 'join',
                  icon: Icon(Icons.merge_type),
                  label: Text('Join'),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() {
                _mode = s.first;
                _message = null;
                _result = null;
              }),
            ),
            const SizedBox(height: 16),
            if (_mode == 'trim') ...[
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickTrimFile,
                icon: const Icon(Icons.attach_file),
                label: const Text('Pick WAV or MP3 file'),
              ),
              if (trimFile != null) ...[
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.audio_file),
                    title: Text(trimFile.name),
                    subtitle: Text(
                      trimDuration == null
                          ? 'Duration unknown'
                          : 'Duration: ${_clock(trimSeconds)}',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                AudioPlayerBar(
                  file: trimFile.file,
                  title: trimFile.name,
                ),
                if (trimDuration != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Start: ${_clock(_trimStart)}'),
                      Text('End: ${_clock(_trimEnd)}'),
                    ],
                  ),
                  RangeSlider(
                    values: RangeValues(_trimStart, _trimEnd),
                    min: 0,
                    max: trimSeconds,
                    divisions: (trimSeconds * 10).round().clamp(1, 600),
                    labels: RangeLabels(
                      _clock(_trimStart),
                      _clock(_trimEnd),
                    ),
                    onChanged: _busy
                        ? null
                        : (v) => setState(() {
                              _trimStart = v.start;
                              _trimEnd = v.end;
                            }),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: _busy ? null : _trimAndSave,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.content_cut),
                    label: Text(_busy ? 'Trimming…' : 'Trim & save'),
                  ),
                ],
              ],
            ] else ...[
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickJoinFiles,
                icon: const Icon(Icons.library_add),
                label: const Text('Pick files to join'),
              ),
              const SizedBox(height: 12),
              const Text(
                'All files must be the same format (all WAV or all MP3). '
                'WAV files must also share the sample rate, channels and '
                'bit depth.',
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < _joinFiles.length; i++)
                Card(
                  child: ListTile(
                    leading: Text(
                      '${i + 1}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    title: Text(_joinFiles[i].name),
                    subtitle: Text(
                      _joinFiles[i].duration == null
                          ? 'Duration unknown'
                          : 'Duration: ${_clock(_joinFiles[i].duration!.inMilliseconds / 1000)}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_upward, size: 20),
                          tooltip: 'Move up',
                          onPressed: i == 0
                              ? null
                              : () => setState(() {
                                    final item = _joinFiles.removeAt(i);
                                    _joinFiles.insert(i - 1, item);
                                  }),
                        ),
                        IconButton(
                          icon: const Icon(Icons.arrow_downward, size: 20),
                          tooltip: 'Move down',
                          onPressed: i == _joinFiles.length - 1
                              ? null
                              : () => setState(() {
                                    final item = _joinFiles.removeAt(i);
                                    _joinFiles.insert(i + 1, item);
                                  }),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, size: 20),
                          tooltip: 'Remove',
                          onPressed: () => setState(
                            () => _joinFiles.removeAt(i),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_joinFiles.length > 1) ...[
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _joinAndSave,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.merge_type),
                  label: Text(
                    _busy ? 'Joining…' : 'Join ${_joinFiles.length} files',
                  ),
                ),
              ],
            ],
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(_message!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 16),
            _resultCard(),
          ],
        ),
      ),
    );
  }
}
