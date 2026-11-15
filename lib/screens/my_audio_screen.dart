import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/audio_item.dart';
import '../services/audio_download_service.dart';
import '../services/audio_library_service.dart';
import '../widgets/audio_player_bar.dart';
import 'converter_screen.dart';

/// My Audio: every generated audio saved on the device.
/// Play, download, share, convert WAV to MP3, delete.
class MyAudioScreen extends StatefulWidget {
  final AudioLibraryService library;

  const MyAudioScreen({super.key, required this.library});

  @override
  State<MyAudioScreen> createState() => _MyAudioScreenState();
}

class _MyAudioScreenState extends State<MyAudioScreen> {
  bool _loaded = false;
  bool _converting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await widget.library.load();
    if (mounted) setState(() => _loaded = true);
  }

  /// Download: one rewarded ad first, then the file saves to the
  /// phone's Download folder (same flow as TTS Studio results).
  Future<void> _download(AudioItem item) async {
    await AudioDownloadService.downloadWithAd(context, item);
  }

  Future<void> _share(AudioItem item) async {
    await AudioDownloadService.share(context, item);
  }

  Future<void> _convert(AudioItem item) async {
    if (_converting) return;
    setState(() => _converting = true);
    try {
      final parts = await widget.library.convertToMp3(item);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            parts.isEmpty
                ? 'Already an MP3.'
                : 'Converted to MP3 (${parts.length} part${parts.length > 1 ? 's' : ''}).',
          ),
        ),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Conversion failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }

  Future<void> _delete(AudioItem item) async {
    await widget.library.delete(item);
    if (mounted) setState(() {});
  }

  String _dateLabel(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.day}/${dt.month}/${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context);
    final items = widget.library.items;
    return Scaffold(
      appBar: AppBar(
        title: Text(AppStrings.tr('my_audio', locale)),
        actions: [
          IconButton(
            icon: const Icon(Icons.audiotrack),
            tooltip: AppStrings.tr('mp3_converter', locale),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ConverterScreen(library: widget.library),
              ),
            ),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      AppStrings.tr('no_audio_yet', locale),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final item = items[i];
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
                            Text(
                              '${item.voiceId} • ${item.ext.toUpperCase()} • ${_dateLabel(item.createdAtMs)}',
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 8,
                              children: [
                                TextButton.icon(
                                  onPressed: () => _download(item),
                                  icon: const Icon(Icons.download, size: 18),
                                  label: Text(
                                    AppStrings.tr('download', locale),
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: () => _share(item),
                                  icon: const Icon(Icons.share, size: 18),
                                  label: Text(
                                    AppStrings.tr('share', locale),
                                  ),
                                ),
                                if (item.ext == 'wav')
                                  TextButton.icon(
                                    onPressed: _converting
                                        ? null
                                        : () => _convert(item),
                                    icon: const Icon(
                                      Icons.transform,
                                      size: 18,
                                    ),
                                    label: Text(
                                      AppStrings.tr('convert_mp3', locale),
                                    ),
                                  ),
                                TextButton.icon(
                                  onPressed: () => _delete(item),
                                  icon: const Icon(Icons.delete, size: 18),
                                  label: Text(
                                    AppStrings.tr('delete', locale),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
