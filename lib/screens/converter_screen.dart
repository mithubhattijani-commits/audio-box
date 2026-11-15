import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/ads_service.dart';
import '../services/audio_download_service.dart';
import '../services/audio_library_service.dart';

/// MP3 Converter (zone: converter).
///
/// v1 approach (see README): there is no light on-device WAV→MP3
/// encoder, so converting re-generates the SAME words via the proxy's
/// Edge endpoint, which returns genuine MP3 bytes. The result is a real
/// MP3 of the same text (same-gender Edge voice). Conversion itself is
/// free (Edge voices are free); long texts convert into one MP3 per
/// 550-char part.
///
/// DELIVERY (v1.0.3 batch 2): downloading a converted MP3 to the
/// phone's Download folder goes through the SAME one-ad gate as every
/// other download — AudioDownloadService.downloadWithAd (1 rewarded
/// video ad, then the file saves; fail-soft when ads are off or no ad
/// loads; skip = no delivery). Conversion itself stays free and
/// ungated; only the file delivery is gated.
class ConverterScreen extends StatefulWidget {
  final AudioLibraryService library;

  const ConverterScreen({super.key, required this.library});

  @override
  State<ConverterScreen> createState() => _ConverterScreenState();
}

class _ConverterScreenState extends State<ConverterScreen> {
  bool _converting = false;
  String? _message;

  Future<void> _convertAll() async {
    if (_converting) return;
    final wavItems =
        widget.library.items.where((i) => i.ext == 'wav').toList();
    if (wavItems.isEmpty) {
      setState(() => _message = 'No WAV audio to convert.');
      return;
    }
    setState(() {
      _converting = true;
      _message = null;
    });
    var done = 0;
    try {
      for (final item in wavItems) {
        await widget.library.convertToMp3(item);
        done++;
      }
      if (mounted) {
        setState(() => _message = 'Converted $done audio(s) to MP3. '
            'Use Download on an MP3 below to save it (1 ad).');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = 'Conversion stopped after $done: $e');
      }
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context);
    final wavItems =
        widget.library.items.where((i) => i.ext == 'wav').toList();
    final mp3Items =
        widget.library.items.where((i) => i.ext == 'mp3').toList();
    return Scaffold(
      appBar: AppBar(title: Text(AppStrings.tr('mp3_converter', locale))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Converts your saved WAV audio into MP3 files by re-generating the same words with Asad / Uzma. Conversion is free — no coins. Downloading a converted MP3 plays 1 rewarded ad first, then saves it to Downloads.',
            ),
            const SizedBox(height: 16),
            Text(
              'WAV files: ${wavItems.length}  •  MP3 files: ${mp3Items.length}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _converting ? null : _convertAll,
              icon: _converting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.transform),
              label: Text(
                _converting ? 'Converting…' : 'Convert all WAV to MP3',
              ),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_message!),
              ),
            const SizedBox(height: 16),
            for (final item in wavItems)
              ListTile(
                leading: const Icon(Icons.audio_file),
                title: Text(item.displayTitle),
                subtitle: Text(item.voiceId),
                trailing: TextButton(
                  onPressed: _converting
                      ? null
                      : () async {
                          setState(() => _converting = true);
                          try {
                            await widget.library.convertToMp3(item);
                            if (mounted) {
                              setState(() {
                                _message = 'Converted to MP3. '
                                    'Use Download on the MP3 below to save it (1 ad).';
                                _converting = false;
                              });
                            }
                          } catch (e) {
                            if (mounted) {
                              setState(() {
                                _message = 'Conversion failed: $e';
                                _converting = false;
                              });
                            }
                          }
                        },
                  child: const Text('Convert'),
                ),
              ),
            // Converted MP3s: delivery (Download to the phone's
            // Downloads folder) goes through the one-ad gate —
            // downloadWithAd: 1 rewarded ad, then the file saves;
            // fail-soft when ads are off / no ad; skip = no delivery.
            if (mp3Items.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text(
                'MP3 files — Download plays 1 ad, then saves:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              for (final item in mp3Items)
                ListTile(
                  leading: const Icon(Icons.audio_file),
                  title: Text(item.displayTitle),
                  subtitle: Text(item.voiceId),
                  trailing: TextButton.icon(
                    onPressed: () =>
                        AudioDownloadService.downloadWithAd(context, item),
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Download'),
                  ),
                ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: const UnityBannerAdWidget(zone: 'converter'),
    );
  }
}
