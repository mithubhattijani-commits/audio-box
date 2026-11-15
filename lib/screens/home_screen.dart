import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/strings.dart';
import '../services/audio_library_service.dart';
import '../services/coins_service.dart';
import '../services/remote_config_service.dart';
import '../services/rss_service.dart';
import '../services/updater_service.dart';
import '../widgets/news_ticker.dart';
import 'article_listen_screen.dart';
import 'article_webview_screen.dart';
import 'briefing_screen.dart';
import 'converter_screen.dart';
import 'speech_writer_screen.dart';

/// Home: live ticker, announcement, sponsored ad, coin balance, tools
/// grid, latest articles.
///
/// READING IS FREE: tapping an article opens the FULL page on
/// nigraantv.xyz (with the site's banner ads) and earns the user NO
/// coins. The app funnels audience to the website — that traffic and
/// those ad impressions are the point.
class HomeScreen extends StatelessWidget {
  final CoinsService coins;
  final AudioLibraryService library;
  final ValueNotifier<Locale> appLocale;
  final Future<void> Function(Locale) onLocaleChanged;
  final void Function(int index) onOpenTab;

  const HomeScreen({
    super.key,
    required this.coins,
    required this.library,
    required this.appLocale,
    required this.onLocaleChanged,
    required this.onOpenTab,
  });

  void _openArticle(BuildContext context, RssArticle article) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArticleWebViewScreen(article: article),
      ),
    );
  }

  Future<void> _openSponsored(String url) async {
    try {
      await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final locale = appLocale.value;
    final tools = <_Tool>[
      _Tool(
        icon: Icons.mic,
        label: AppStrings.tr('tts_studio', locale),
        onTap: () => onOpenTab(1),
      ),
      _Tool(
        icon: Icons.article,
        label: AppStrings.tr('article_listen', locale),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ArticleListenScreen(
              coins: coins,
              library: library,
              appLocale: appLocale,
            ),
          ),
        ),
      ),
      _Tool(
        icon: Icons.newspaper,
        label: AppStrings.tr('news_briefing', locale),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const BriefingScreen()),
        ),
      ),
      _Tool(
        icon: Icons.edit_note,
        label: AppStrings.tr('speech_writer', locale),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SpeechWriterScreen(
              coins: coins,
              library: library,
              appLocale: appLocale,
            ),
          ),
        ),
      ),
      _Tool(
        icon: Icons.audiotrack,
        label: AppStrings.tr('mp3_converter', locale),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ConverterScreen(library: library),
          ),
        ),
      ),
      _Tool(
        icon: Icons.library_music,
        label: AppStrings.tr('my_audio', locale),
        onTap: () => onOpenTab(3),
      ),
      _Tool(
        icon: Icons.monetization_on,
        label: AppStrings.tr('coins', locale),
        onTap: () => onOpenTab(2),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(AppStrings.tr('app_name', locale)),
        actions: [
          IconButton(
            icon: const Icon(Icons.language),
            tooltip: 'English / اردو',
            onPressed: () {
              final next = locale.languageCode == 'en'
                  ? const Locale('ur')
                  : const Locale('en');
              onLocaleChanged(next);
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Announcement bar (remote config; only when enabled + text).
            ValueListenableBuilder<RemoteConfig>(
              valueListenable: RemoteConfigService.instance.notifier,
              builder: (context, cfg, _) {
                if (!cfg.announcement.show) {
                  return const SizedBox.shrink();
                }
                return Container(
                  color: Theme.of(context).colorScheme.secondary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Text(
                    cfg.announcement.text,
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                );
              },
            ),
            // Live news ticker (RSS feed, refreshes every 5 min).
            NewsTicker(onTapArticle: (a) => _openArticle(context, a)),
            // Sponsored ad card — TJ Earn rule: only when enabled AND
            // title AND action_url are both non-empty.
            ValueListenableBuilder<RemoteConfig>(
              valueListenable: RemoteConfigService.instance.notifier,
              builder: (context, cfg, _) {
                final ad = cfg.sponsoredAd;
                if (!ad.show) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Card(
                    color: Colors.amber.shade50,
                    child: InkWell(
                      onTap: () => _openSponsored(ad.actionUrl),
                      borderRadius: BorderRadius.circular(14),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'SPONSORED',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (ad.imageUrl.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Image.network(
                                  ad.imageUrl,
                                  height: 120,
                                  width: double.infinity,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      const SizedBox.shrink(),
                                ),
                              ),
                            const SizedBox(height: 6),
                            Text(
                              ad.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            if (ad.body.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(ad.body),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Coin balance card.
                  Card(
                    color: Theme.of(context).colorScheme.primary,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: ValueListenableBuilder<int>(
                        valueListenable: coins.balance,
                        builder: (context, balance, _) {
                          return Row(
                            children: [
                              const Icon(
                                Icons.monetization_on,
                                color: Colors.amber,
                                size: 36,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      AppStrings.tr('balance', locale),
                                      style: const TextStyle(
                                        color: Colors.white70,
                                      ),
                                    ),
                                    Text(
                                      '$balance coins',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 26,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  foregroundColor: Theme.of(context)
                                      .colorScheme
                                      .primary,
                                ),
                                onPressed: () => onOpenTab(2),
                                child: Text(AppStrings.tr('coins', locale)),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    AppStrings.tr('tools', locale),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.6,
                    ),
                    itemCount: tools.length,
                    itemBuilder: (context, i) {
                      final tool = tools[i];
                      return Card(
                        child: InkWell(
                          onTap: tool.onTap,
                          borderRadius: BorderRadius.circular(14),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                tool.icon,
                                size: 34,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                tool.label,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  // Latest articles (RSS feed) — tap opens the full page
                  // on nigraantv.xyz with its banner ads. Free, no coins.
                  Text(
                    AppStrings.tr('latest_articles', locale),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    AppStrings.tr('read_on_website', locale),
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  FutureBuilder<List<RssArticle>>(
                    future: RssService.fetchLatestCached(limit: 10),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState ==
                          ConnectionState.waiting) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      if (snapshot.hasError || !snapshot.hasData) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'Could not load news right now.',
                            style: TextStyle(color: Colors.grey),
                          ),
                        );
                      }
                      final articles = snapshot.data!;
                      return Column(
                        children: articles.map((a) {
                          return Card(
                            child: ListTile(
                              title: Text(
                                a.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${a.dek}${a.relativeTime.isNotEmpty ? ' • ${a.relativeTime}' : ''}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.headphones),
                                tooltip: 'Listen',
                                onPressed: () =>
                                    Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => ArticleListenScreen(
                                      coins: coins,
                                      library: library,
                                      appLocale: appLocale,
                                      initialArticle: a,
                                    ),
                                  ),
                                ),
                              ),
                              onTap: () => _openArticle(context, a),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () => UpdaterService.checkManually(context),
                    child: Text(AppStrings.tr('check_updates', locale)),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Nigraan TV  •  Text to audio, free with coins',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tool {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _Tool({required this.icon, required this.label, required this.onTap});
}
