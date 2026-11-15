import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/ads_service.dart';
import '../services/audio_library_service.dart';

/// MP3 Converter (zone: converter).
///
/// v1 approach (see README): there is no light on-device WAV→MP3
/// encoder, so converting re-generates the SAME words via the proxy's
/// Edge endpoint, which returns genuine MP3 bytes. The result is a real
/// MP3 of the same text (same-gender Edge voice). Conversion itself is
/// free (Edge voices are free); long texts convert into one MP3 per
/// 550-char part.
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
        setState(() => _message = 'Converted $done audio(s) to MP3.');
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
              'Converts your saved WAV audio (Gemini voices) into MP3 files by re-generating the same words with the free Edge voices (Asad / Uzma). Conversion is free — no coins.',
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
                                _message = 'Converted to MP3.';
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
          ],
        ),
      ),
      bottomNavigationBar: const UnityBannerAdWidget(zone: 'converter'),
    );
  }
}
