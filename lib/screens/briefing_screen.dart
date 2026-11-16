import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../l10n/strings.dart';
import '../services/ads_service.dart';
import '../services/audio_download_service.dart';
import '../services/briefing_service.dart';
import '../widgets/audio_player_bar.dart';

/// News Briefing: the hourly Nigraan TV briefing audio from the website.
/// Free to listen — no coins.
class BriefingScreen extends StatefulWidget {
  const BriefingScreen({super.key});

  @override
  State<BriefingScreen> createState() => _BriefingScreenState();
}

class _BriefingScreenState extends State<BriefingScreen> {
  BriefingInfo? _info;
  bool _loading = true;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final info = await BriefingService.fetch();
    if (mounted) {
      setState(() {
        _info = info;
        _loading = false;
      });
    }
  }

  /// Download the briefing MP3 (v1.0.9): ONE rewarded ad first, then
  /// the file saves to Downloads — same fail-soft gate as TTS Studio.
  Future<void> _download() async {
    final url = _info?.audioUrl ?? '';
    if (url.isEmpty || _downloading) return;
    setState(() => _downloading = true);
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 60));
      if (!mounted) return;
      if (res.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Download failed: audio not found.')),
        );
        return;
      }
      await AudioDownloadService.downloadBytesWithAd(
        context,
        fileName: 'nigraan-briefing.mp3',
        bytes: res.bodyBytes,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context);
    return Scaffold(
      appBar: AppBar(title: Text(AppStrings.tr('news_briefing', locale))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _info?.title ?? 'Nigraan TV News Briefing',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if ((_info?.generatedAt ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _info!.generatedAt,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    AppStrings.tr('briefing_note', locale),
                    style: const TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AudioPlayerBar(
                            url: _info?.audioUrl,
                            title: 'Briefing audio',
                          ),
                          if ((_info?.audioUrl ?? '').isNotEmpty)
                            TextButton.icon(
                              onPressed:
                                  _downloading ? null : _download,
                              icon: _downloading
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.download, size: 18),
                              label: Text(
                                _downloading
                                    ? 'Downloading…'
                                    : '${AppStrings.tr('download', locale)} (1 ad)',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if ((_info?.headlines ?? []).isNotEmpty) ...[
                    Text(
                      'Headlines',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final h in _info!.headlines)
                      ListTile(
                        leading: const Icon(Icons.circle, size: 8),
                        title: Text(h),
                      ),
                  ],
                ],
              ),
            ),
      bottomNavigationBar: const UnityBannerAdWidget(zone: 'briefing'),
    );
  }
}
