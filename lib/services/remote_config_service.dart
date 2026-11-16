// Remote Config — server-driven in-app behaviour (v1).
//
// Fail-soft, copied from TJ Earn's RemoteConfigService: network -> cache
// -> bundled defaults. Never blocks startup, never an infinite spinner,
// never a crash — on any failure the app just uses what it has.
//
// Config URL (fixed): https://nigraantv.xyz/apps/config/audio-box.json
// The file itself is created on the website as a follow-up step; until
// it exists the app runs on the bundled defaults below.
//
// Polling (TJ Earn pattern): re-fetched fresh on launch, on resume, and
// every ~60s. A change on the website takes effect immediately while the
// app is online — no rebuild, no update.
//
// NOTE: the app VERSION does NOT live in this config. Version checks use
// the separate fixed URL https://nigraantv.xyz/apps/audio-box-version.json
// (see UpdaterService) — one source of truth, same as TJ Earn.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

/// One rewarded-video option on the Coins screen.
/// New options are added later by editing the config only — no rebuild.
class RewardOption {
  final String id;
  final String label;
  final int adsRequired;
  final int coins;

  const RewardOption({
    required this.id,
    required this.label,
    required this.adsRequired,
    required this.coins,
  });

  factory RewardOption.fromJson(Map<String, dynamic> j) => RewardOption(
        id: (j['id'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
        adsRequired: (j['ads_required'] as num?)?.toInt() ?? 2,
        coins: (j['coins'] as num?)?.toInt() ?? 50,
      );
}

/// Sponsored-ad card (Home + tools list). EXACT rule copied from TJ Earn
/// (verified): the card shows ONLY when enabled=true AND title AND
/// action_url are both non-empty. image_url is optional.
class SponsoredAdConfig {
  const SponsoredAdConfig({
    this.enabled = false,
    this.title = '',
    this.body = '',
    this.actionUrl = '',
    this.imageUrl = '',
  });

  final bool enabled;
  final String title;
  final String body;
  final String actionUrl;
  final String imageUrl;

  /// The verified TJ Earn rule — do not weaken it.
  bool get show =>
      enabled && title.trim().isNotEmpty && actionUrl.trim().isNotEmpty;

  factory SponsoredAdConfig.fromJson(Map<String, dynamic> j) {
    return SponsoredAdConfig(
      enabled: j['enabled'] == true,
      title: (j['title'] ?? '').toString(),
      body: (j['body'] ?? '').toString(),
      actionUrl: (j['action_url'] ?? '').toString(),
      imageUrl: (j['image_url'] ?? '').toString(),
    );
  }
}

/// Slim announcement bar under the header. Shows only when enabled AND
/// the text is non-empty.
class AnnouncementConfig {
  const AnnouncementConfig({this.enabled = false, this.text = ''});

  final bool enabled;
  final String text;

  bool get show => enabled && text.trim().isNotEmpty;

  factory AnnouncementConfig.fromJson(Map<String, dynamic> j) {
    return AnnouncementConfig(
      enabled: j['enabled'] == true,
      text: (j['text'] ?? '').toString(),
    );
  }
}

/// Ribbon bar under the Home news ticker, fully remote-controlled.
/// Defaults (bundled fail-soft): enabled=true, color #3D5AFE, empty
/// text (solid bar only), height 36. Only the fallback color is
/// compiled in — every visible value comes from audio-box.json.
class RibbonConfig {
  const RibbonConfig({
    this.enabled = true,
    this.color = '#3D5AFE',
    this.text = '',
    this.height = 36,
  });

  final bool enabled;

  /// Hex color string, e.g. "#3D5AFE". Invalid values fall back to
  /// #3D5AFE in the widget (see NewsRibbon.parseColor).
  final String color;

  /// Centered white text; empty = solid colored bar with no text.
  final String text;

  /// Bar height in logical pixels.
  final double height;

  factory RibbonConfig.fromJson(Map<String, dynamic> j) {
    final color = (j['color'] ?? '').toString().trim();
    final height = (j['height'] as num?)?.toDouble() ?? 36;
    return RibbonConfig(
      enabled: j['enabled'] != false,
      color: color.isEmpty ? '#3D5AFE' : color,
      text: (j['text'] ?? '').toString(),
      height: height <= 0 ? 36 : height,
    );
  }
}

/// TTS behaviour controlled from the website — no rebuild needed.
/// Gemini API keys are NEVER in the app or this config: they live
/// server-side in the TTS proxy Worker only.
class TtsConfig {
  const TtsConfig({
    this.geminiEnabled = true,
    this.edgeEnabled = true,
    this.voices = const ['aoede', 'charon', 'asad', 'uzma'],
    this.coinsPerMinute = 50,
    this.dailyCap = 10,
    this.proxyUrl =
        'https://nigraan-tv-tts-proxy.mithubhattijani.workers.dev',
  });

  final bool geminiEnabled;
  final bool edgeEnabled;

  /// Voice ids offered in TTS Studio (subset of aoede/charon/asad/uzma).
  final List<String> voices;

  /// Coins charged per ~1-minute generation chunk.
  final int coinsPerMinute;

  /// Max audio generations per user per day (0 = unlimited).
  final int dailyCap;

  /// TTS proxy base URL (no key in the app — keys stay server-side in
  /// the Worker). Change it here to point the app at a new proxy
  /// without a rebuild.
  final String proxyUrl;

  factory TtsConfig.fromJson(Map<String, dynamic> j) {
    final rawVoices = j['voices'];
    List<String> voices = const ['aoede', 'charon', 'asad', 'uzma'];
    if (rawVoices is List) {
      final parsed =
          rawVoices.map((v) => v.toString()).where((v) => v.isNotEmpty).toList();
      if (parsed.isNotEmpty) voices = parsed;
    }
    final proxyUrl = (j['proxy_url'] ?? '').toString().trim();
    return TtsConfig(
      geminiEnabled: j['gemini_enabled'] != false,
      edgeEnabled: j['edge_enabled'] != false,
      voices: voices,
      coinsPerMinute: (j['coins_per_minute'] as num?)?.toInt() ?? 50,
      dailyCap: (j['daily_cap'] as num?)?.toInt() ?? 10,
      proxyUrl: proxyUrl.isEmpty
          ? 'https://nigraan-tv-tts-proxy.mithubhattijani.workers.dev'
          : proxyUrl,
    );
  }
}

/// Unity IDs controlled from the website — no rebuild needed.
/// A changed Game ID takes effect on the NEXT app launch (the Unity SDK
/// initialises once at startup); placement IDs take effect on the next
/// ad load. Defaults are the live values, so an unreachable config
/// keeps the current ads working.
class UnityConfig {
  const UnityConfig({
    this.gameId = '800438808',
    this.rewardedPlacementId = 'BP_Rewarded_Android',
    this.bannerPlacementId = 'BP_Banner_Android',
    this.appOpenPlacementId = 'BP_Interstitial_Android',
  });

  final String gameId;
  final String rewardedPlacementId;
  final String bannerPlacementId;
  final String appOpenPlacementId;

  factory UnityConfig.fromJson(Map<String, dynamic> j) {
    String s(Object? v, String dflt) {
      final t = (v ?? '').toString().trim();
      return t.isEmpty ? dflt : t;
    }

    return UnityConfig(
      gameId: s(j['game_id'], '800438808'),
      rewardedPlacementId: s(j['rewarded_placement_id'], 'BP_Rewarded_Android'),
      bannerPlacementId: s(j['banner_placement_id'], 'BP_Banner_Android'),
      appOpenPlacementId:
          s(j['app_open_placement_id'], 'BP_Interstitial_Android'),
    );
  }
}

/// Site feeds the app reads (ticker, article list, briefing).
class FeedsConfig {
  const FeedsConfig({
    this.rssUrl = 'https://nigraantv.xyz/rss.xml',
    this.briefingJsonUrl = 'https://nigraantv.xyz/briefing.json',
    this.briefingMp3Url = 'https://nigraantv.xyz/briefing.mp3',
  });

  final String rssUrl;
  final String briefingJsonUrl;
  final String briefingMp3Url;

  factory FeedsConfig.fromJson(Map<String, dynamic> j) {
    String s(Object? v, String dflt) {
      final t = (v ?? '').toString().trim();
      return t.isEmpty ? dflt : t;
    }

    return FeedsConfig(
      rssUrl: s(j['rss_url'], 'https://nigraantv.xyz/rss.xml'),
      briefingJsonUrl:
          s(j['briefing_json_url'], 'https://nigraantv.xyz/briefing.json'),
      briefingMp3Url:
          s(j['briefing_mp3_url'], 'https://nigraantv.xyz/briefing.mp3'),
    );
  }
}

/// Splash poster. Empty imageUrl = the bundled poster. Set it to a
/// picture URL to change the splash without a rebuild (applies from the
/// next app launch after the config is fetched; the bundled poster
/// stays as the offline/broken-link fallback).
class SplashConfig {
  const SplashConfig({this.imageUrl = ''});

  final String imageUrl;

  factory SplashConfig.fromJson(Map<String, dynamic> j) {
    return SplashConfig(imageUrl: (j['image_url'] ?? '').toString().trim());
  }
}

class RemoteConfig {
  const RemoteConfig({
    this.adsEnabled = true,
    this.banners = const {
      'home': true,
      'tts_studio': true,
      'tools': true,
      'briefing': true,
      'speech_writer': true,
      'converter': true,
      'my_audio': true,
      'coins': true,
    },
    this.appOpenAdEnabled = true,
    this.rewardedEnabled = true,
    this.rewardedOptions = const [
      RewardOption(
        id: 'ads2',
        label: 'Watch 2 ads — get 50 coins',
        adsRequired: 2,
        coins: 50,
      ),
    ],
    this.sponsoredAd = const SponsoredAdConfig(),
    this.announcement = const AnnouncementConfig(),
    this.tts = const TtsConfig(),
    this.unity = const UnityConfig(),
    this.feeds = const FeedsConfig(),
    this.splash = const SplashConfig(),
    this.tickerDirection = 'from_left',
    this.ribbon = const RibbonConfig(),
    this.downloadAdsRequired = 2,
    this.advertisingBannerEnabled = true,
  });

  /// Master switch for ALL Unity ads.
  final bool adsEnabled;

  /// Per-screen banner zones. A banner shows only when the master switch
  /// is on AND its zone key is true.
  final Map<String, bool> banners;

  /// App Open ad on cold start.
  final bool appOpenAdEnabled;

  /// Rewarded video master switch.
  final bool rewardedEnabled;

  final List<RewardOption> rewardedOptions;
  final SponsoredAdConfig sponsoredAd;
  final AnnouncementConfig announcement;
  final TtsConfig tts;

  /// Unity Game ID + placement IDs (no rebuild to change them).
  final UnityConfig unity;

  /// Site feeds (ticker, articles, briefing).
  final FeedsConfig feeds;

  /// Splash poster picture.
  final SplashConfig splash;

  /// Ticker scroll direction — 'from_left' (text enters from the left,
  /// moves right; the Nigraan Urdu-ticker house style) or 'from_right'
  /// (old direction). Changeable from the website, no rebuild.
  final String tickerDirection;

  /// Ribbon bar under the Home news ticker (remote-controlled).
  final RibbonConfig ribbon;

  /// How many rewarded ads the SRT/ASS caption download must play,
  /// back-to-back, before the file is delivered (v1.0.7, user order
  /// 16 Nov 2026). NO upper limit — any number from the website
  /// config works; 0 = no ad, direct download. Default 2 (the v1.0.6
  /// two-ad rule). Skip ANY ad = no delivery.
  final int downloadAdsRequired;

  /// Home-screen advertising banner (chairman's photo + WhatsApp).
  /// Off hides the banner; the Help row at the bottom stays.
  final bool advertisingBannerEnabled;

  bool bannerEnabled(String zone) => adsEnabled && (banners[zone] == true);

  factory RemoteConfig.fromJson(Map<String, dynamic> j) {
    final rawBanners = j['banners'];
    final banners = <String, bool>{
      'home': true,
      'tts_studio': true,
      'tools': true,
      'briefing': true,
      'speech_writer': true,
      'converter': true,
      'my_audio': true,
      'coins': true,
    };
    if (rawBanners is Map<String, dynamic>) {
      for (final e in rawBanners.entries) {
        banners[e.key] = e.value == true;
      }
    }

    final rawRewarded = j['rewarded'];
    List<RewardOption> options = const [
      RewardOption(
        id: 'ads2',
        label: 'Watch 2 ads — get 50 coins',
        adsRequired: 2,
        coins: 50,
      ),
    ];
    bool rewardedEnabled = true;
    if (rawRewarded is Map<String, dynamic>) {
      rewardedEnabled = rawRewarded['enabled'] != false;
      final rawOptions = rawRewarded['options'];
      if (rawOptions is List && rawOptions.isNotEmpty) {
        options = rawOptions
            .whereType<Map<String, dynamic>>()
            .map(RewardOption.fromJson)
            .where((o) => o.adsRequired > 0 && o.coins > 0)
            .toList();
        if (options.isEmpty) {
          options = const [
            RewardOption(
              id: 'ads2',
              label: 'Watch 2 ads — get 50 coins',
              adsRequired: 2,
              coins: 50,
            ),
          ];
        }
      }
    }

    // Caption-download ad count (v1.0.7): any whole number, NO cap.
    // 0 = no ad, direct download. Anything else invalid falls back
    // to the v1.0.6 default of 2.
    var downloadAdsRequired = 2;
    if (j['download'] is Map<String, dynamic>) {
      final n = (j['download'] as Map<String, dynamic>)['ads_required'];
      if (n is num) {
        final v = n.toInt();
        if (v >= 0) downloadAdsRequired = v;
      }
    }
    final advertisingBannerEnabled =
        (j['advertising_banner'] is Map<String, dynamic>)
            ? (j['advertising_banner'] as Map<String, dynamic>)['enabled'] !=
                false
            : true;

    return RemoteConfig(
      adsEnabled: j['ads_enabled'] != false,
      banners: banners,
      appOpenAdEnabled:
          (j['app_open_ad'] is Map<String, dynamic>)
              ? (j['app_open_ad'] as Map<String, dynamic>)['enabled'] != false
              : true,
      rewardedEnabled: rewardedEnabled,
      rewardedOptions: options,
      sponsoredAd: j['sponsored_ad'] is Map<String, dynamic>
          ? SponsoredAdConfig.fromJson(
              j['sponsored_ad'] as Map<String, dynamic>,
            )
          : const SponsoredAdConfig(),
      announcement: j['announcement'] is Map<String, dynamic>
          ? AnnouncementConfig.fromJson(
              j['announcement'] as Map<String, dynamic>,
            )
          : const AnnouncementConfig(),
      tts: j['tts'] is Map<String, dynamic>
          ? TtsConfig.fromJson(j['tts'] as Map<String, dynamic>)
          : const TtsConfig(),
      unity: j['unity'] is Map<String, dynamic>
          ? UnityConfig.fromJson(j['unity'] as Map<String, dynamic>)
          : const UnityConfig(),
      feeds: j['feeds'] is Map<String, dynamic>
          ? FeedsConfig.fromJson(j['feeds'] as Map<String, dynamic>)
          : const FeedsConfig(),
      splash: j['splash'] is Map<String, dynamic>
          ? SplashConfig.fromJson(j['splash'] as Map<String, dynamic>)
          : const SplashConfig(),
      tickerDirection: (j['ticker'] is Map<String, dynamic> &&
              ((j['ticker'] as Map<String, dynamic>)['direction'] ==
                      'from_right' ||
                  (j['ticker'] as Map<String, dynamic>)['direction'] ==
                      'from_left'))
          ? (j['ticker'] as Map<String, dynamic>)['direction'] as String
          : 'from_left',
      ribbon: j['ribbon'] is Map<String, dynamic>
          ? RibbonConfig.fromJson(j['ribbon'] as Map<String, dynamic>)
          : const RibbonConfig(),
      downloadAdsRequired: downloadAdsRequired,
      advertisingBannerEnabled: advertisingBannerEnabled,
    );
  }
}

/// Singleton service. UI listens to [notifier] so a fresh fetch updates
/// the screens without a restart.
class RemoteConfigService {
  RemoteConfigService._();

  static final RemoteConfigService instance = RemoteConfigService._();

  static const _cacheKey = 'ab_remote_config_json_v1';
  static const _url = AppConfig.remoteConfigUrl;
  static const Duration _fetchTimeout = Duration(seconds: 8);
  static const Duration refreshInterval = Duration(seconds: 60);

  final ValueNotifier<RemoteConfig> notifier =
      ValueNotifier(const RemoteConfig());

  RemoteConfig get config => notifier.value;

  Timer? _pollTimer;
  bool _refreshing = false;

  /// Loads the cached config (from a previous session) without starting
  /// the network fetch or the poll timer. main() calls this before the
  /// first frame so the splash screen can already use a remotely-set
  /// poster image on this launch.
  Future<void> loadCache() => _loadFromCache();

  /// Loads the cache first (fast), then ALWAYS fetches fresh from the
  /// network — no TTL gate — and starts the ~60s poll. Never blocks the
  /// first frame; failures stay silent and keep the cache/defaults.
  Future<void> init() async {
    await _loadFromCache();
    unawaited(_refresh());
    startPolling();
  }

  Future<void> refresh() => _refresh();

  void startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      refreshInterval,
      (_) => unawaited(_refresh()),
    );
  }

  void dispose() {
    _pollTimer?.cancel();
  }

  Future<void> _loadFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        notifier.value = RemoteConfig.fromJson(decoded);
      }
    } catch (_) {
      // Corrupt cache: keep bundled defaults.
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final res = await http
          .get(Uri.parse(_url))
          .timeout(_fetchTimeout);
      if (res.statusCode != 200) return;
      // ENCODING FIX (15 Nov 2026): same as RssService — the site sends
      // no charset, so res.body would decode UTF-8 (e.g. an Urdu
      // announcement) as Latin-1 mojibake. Decode the raw bytes as
      // UTF-8 ourselves, and cache the correctly-decoded text.
      final body = utf8.decode(res.bodyBytes);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return;
      notifier.value = RemoteConfig.fromJson(decoded);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_cacheKey, body);
      } catch (_) {
        // Cache write is best-effort.
      }
    } catch (_) {
      // Offline or unreachable: keep cache/defaults (fail-soft).
    } finally {
      _refreshing = false;
    }
  }
}
