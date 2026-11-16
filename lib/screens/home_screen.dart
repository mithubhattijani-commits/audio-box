import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/strings.dart';
import '../services/audio_library_service.dart';
import '../services/coins_service.dart';
import '../services/remote_config_service.dart';
import '../services/rss_service.dart';
import '../services/updater_service.dart';
import '../widgets/advertising_banner.dart';
import '../widgets/help_whatsapp_button.dart';
import '../widgets/news_ticker.dart';
import 'article_listen_screen.dart';
import 'article_webview_screen.dart';
import 'audio_trimmer_screen.dart';
import 'audio_video_tools_screen.dart';
import 'briefing_screen.dart';
import 'caption_generator_screen.dart';
import 'caption_translator_screen.dart';
import 'converter_screen.dart';
import 'speech_writer_screen.dart';
import 'tts_screen.dart';
import 'video_caption_maker_screen.dart';

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
        icon: Icons.video_library,
        label: AppStrings.tr('audio_video_tools', locale),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AudioVideoToolsScreen(
              coins: coins,
              library: library,
              appLocale: appLocale,
            ),
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
            // The ticker strip IS the blue ribbon (red LIVE chip +
            // news scrolling on the blue ribbon) — no separate ribbon
            // below it.
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
                  const SizedBox(height: 16),
                  // Audio & Video tools directly on Home (v1.0.8):
                  // the same 4 dark cards as AudioVideoToolsScreen,
                  // plus slots for the new v1.0.8 tools. Same dark
                  // card style (dark-red icon square, RTL like the
                  // tools page). The "Audio & Video Tools" grid tile
                  // above still opens the full tools page.
                  Text(
                    AppStrings.tr('audio_video_tools', locale),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Directionality(
                    textDirection: TextDirection.rtl,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _AvToolCard(
                          icon: Icons.campaign,
                          title: 'Text to Speech',
                          subtitle: 'متن کو آواز میں بدلیں',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => TtsScreen(
                                coins: coins,
                                library: library,
                                appLocale: appLocale,
                              ),
                            ),
                          ),
                        ),
                        _AvToolCard(
                          icon: Icons.music_note,
                          title: 'Audio Converter',
                          subtitle: 'آڈیو کو WAV میں بدلیں',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  ConverterScreen(library: library),
                            ),
                          ),
                        ),
                        _AvToolCard(
                          icon: Icons.chat_bubble_outline,
                          title: 'AI Caption Generator',
                          subtitle:
                              'ویڈیو کے خودکار کیپشنز + 11 اسٹائل + فونٹس',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  CaptionGeneratorScreen(coins: coins),
                            ),
                          ),
                        ),
                        _AvToolCard(
                          icon: Icons.movie,
                          title: 'Video Caption Maker (AI)',
                          subtitle:
                              'خودکار کیپشن + 11 اسٹائل + فونٹس + SRT/ASS — ویڈیو پر پیش نظارہ',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  VideoCaptionMakerScreen(coins: coins),
                            ),
                          ),
                        ),
                        _AvToolCard(
                          icon: Icons.translate,
                          title: 'Caption Translation',
                          subtitle: 'کیپشنز کا اردو ↔ انگریزی ترجمہ',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  CaptionTranslatorScreen(coins: coins),
                            ),
                          ),
                        ),
                        _AvToolCard(
                          icon: Icons.content_cut,
                          title: 'Audio Trimmer + Joiner',
                          subtitle: 'آڈیو کاٹیں اور جوڑیں',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => AudioTrimmerScreen(
                                coins: coins,
                                library: library,
                              ),
                            ),
                          ),
                        ),
                        _AvToolCard(
                          icon: Icons.tune,
                          title: 'TTS Controls',
                          subtitle: 'آواز کی رفتار اور وقفے',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => TtsScreen(
                                coins: coins,
                                library: library,
                                appLocale: appLocale,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          locale.languageCode == 'ur'
                              ? 'کیپشنز پر فی منٹ 50 کوائنز لگتے ہیں۔'
                              : 'Captions cost 50 coins per minute of media.',
                          style: const TextStyle(
                              color: Colors.grey, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Advertising banner (v1.0.6): chairman's photo +
                  // contact line for advertising in the app. Remote
                  // on/off from the website (v1.0.7):
                  // advertising_banner.enabled, default on.
                  ValueListenableBuilder<RemoteConfig>(
                    valueListenable:
                        RemoteConfigService.instance.notifier,
                    builder: (context, cfg, _) {
                      if (!cfg.advertisingBannerEnabled) {
                        return const SizedBox.shrink();
                      }
                      return AdvertisingBanner(
                        lang: locale.languageCode,
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
                  const SizedBox(height: 16),
                  // For Help — very end of the home screen.
                  HelpWhatsAppRow(lang: locale.languageCode),
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

/// Dark audio/video tool card — mirrors
/// AudioVideoToolsScreen._ToolCard (dark #1E1E1E card, dark-red icon
/// square, white bold title + grey Urdu subtitle, chevron).
class _AvToolCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _AvToolCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: const Color(0xFF7F1D1D),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_left,
                  color: Colors.grey,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
