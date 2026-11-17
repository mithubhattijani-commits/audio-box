import 'dart:async';

import 'package:flutter/material.dart';
import 'package:unity_ads_plugin/unity_ads_plugin.dart';

import 'remote_config_service.dart';

/// Unity Ads for Audio Box From Jaani.
///
/// Pattern copied from TJ Earn's UnityAdsService (same plugin version,
/// same call shapes). Coins are the ONLY reward — virtual currency spent
/// on in-app audio generation, never cash (Unity policy-safe, unlike
/// TJ Earn's cash-out).
///
/// Banner zones: every screen has a zone key in the remote config
/// (home, tts_studio, tools, briefing, speech_writer, converter,
/// my_audio, coins). A banner shows only when the master switch
/// (ads_enabled) is on AND its zone key is true — same pattern as
/// TJ Earn/Doner.
///
/// LIVE (15 Nov 2026): Unity project "Audio Box From Jaani", Game ID
/// 800438808 (org TJ Earn). App Open is an Interstitial-format placement
/// (dashboard offers no separate App Open format) — display name
/// BP_AppOpen_Android, placement ID BP_Interstitial_Android (same as
/// TJ Earn's App Open setup).
///
/// REMOTE IDS (15 Nov 2026): the Game ID and all placement IDs now come
/// from the remote config (website) — changing them needs NO rebuild.
/// A changed Game ID takes effect on the next app launch (the Unity SDK
/// initialises once at startup); placement IDs on the next ad load.
class UnityAdsService {
  /// Unity IDs from the remote config. Defaults in the config equal the
  /// live values, so an unreachable config keeps the current ads working.
  static String get gameId =>
      RemoteConfigService.instance.config.unity.gameId;
  static String get rewardedPlacementId =>
      RemoteConfigService.instance.config.unity.rewardedPlacementId;
  static String get bannerPlacementId =>
      RemoteConfigService.instance.config.unity.bannerPlacementId;
  static String get appOpenPlacementId =>
      RemoteConfigService.instance.config.unity.appOpenPlacementId;

  /// Keep true while testing. Production builds set this to false.
  static const bool testMode = false;

  /// True once the real Unity IDs are filled in.
  static bool get adsConfigured => gameId != 'REPLACE_ME';

  /// Master switch from the remote config (admin panel). Ads run only
  /// when the IDs are configured AND the remote master switch is on.
  static bool get adsEnabledNow =>
      adsConfigured && RemoteConfigService.instance.config.adsEnabled;

  static bool _initialized = false;
  static bool _initFailed = false;
  static bool _initStarted = false;

  static bool get isInitialized => _initialized;
  static bool get initFailed => _initFailed;

  /// Initialize the Unity Ads SDK. Safe to call at startup and again
  /// later; a call while an attempt is in flight is a no-op. Never throws.
  /// No-op when the Unity IDs are still REPLACE_ME.
  static Future<void> init() async {
    if (!adsConfigured) return;
    if (_initialized) return;
    if (_initStarted && !_initFailed) return;
    _initStarted = true;
    _initFailed = false;
    try {
      final completer = Completer<void>();
      UnityAds.init(
        gameId: gameId,
        testMode: testMode,
        onComplete: () {
          _initialized = true;
          if (!completer.isCompleted) completer.complete();
        },
        onFailed: (error, message) {
          _initFailed = true;
          if (!completer.isCompleted) completer.complete();
        },
      );
      await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          _initFailed = true;
        },
      );
      if (!_initialized && !_initFailed) {
        _initFailed = true;
      }
    } catch (_) {
      _initFailed = true;
    }
  }

  /// Load the rewarded video ad. Call before showing.
  static Future<bool> loadRewardedAd() async {
    if (!_initialized) return false;
    try {
      final completer = Completer<bool>();
      UnityAds.load(
        placementId: rewardedPlacementId,
        onComplete: (placementId) {
          if (!completer.isCompleted) completer.complete(true);
        },
        onFailed: (placementId, error, message) {
          if (!completer.isCompleted) completer.complete(false);
        },
      );
      return await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    }
  }

  /// Show ONE rewarded video ad.
  /// Returns [UnityAdResult.completed] only when the user watched it fully.
  static Future<UnityAdResult> showRewardedAd() async {
    if (!_initialized) return UnityAdResult.failed;
    try {
      final completer = Completer<UnityAdResult>();
      UnityAds.showVideoAd(
        placementId: rewardedPlacementId,
        onStart: (placementId) {},
        onClick: (placementId) {},
        onSkipped: (placementId) {
          if (!completer.isCompleted) {
            completer.complete(UnityAdResult.skipped);
          }
        },
        onComplete: (placementId) {
          if (!completer.isCompleted) {
            completer.complete(UnityAdResult.completed);
          }
        },
        onFailed: (placementId, error, message) {
          if (!completer.isCompleted) {
            completer.complete(UnityAdResult.failed);
          }
        },
      );
      final result = await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => UnityAdResult.failed,
      );
      // Preload the next ad in the background (never blocks the UI).
      unawaited(loadRewardedAd());
      return result;
    } catch (_) {
      return UnityAdResult.failed;
    }
  }

  /// Show [count] rewarded ads back-to-back from ONE tap.
  /// Returns true only when ALL ads completed fully. If the user skips
  /// or an ad fails at any point, no coins are granted and the flow stops.
  /// The rewarded options on the Coins screen come from the remote config
  /// (each option sets its own ads_required + coins) — new options are
  /// addable later without a rebuild.
  static Future<bool> showNRewardedAds(int count) async {
    if (!adsEnabledNow) return false;
    if (!RemoteConfigService.instance.config.rewardedEnabled) return false;
    await init();
    if (!isInitialized) return false;
    for (var i = 0; i < count; i++) {
      final loaded = await loadRewardedAd();
      if (!loaded) return false;
      final result = await showRewardedAd();
      if (result != UnityAdResult.completed) return false;
    }
    return true;
  }

  /// The default coin-earning flow: 2 ads, one tap, 50 coins.
  static Future<bool> showTwoRewardedAds() => showNRewardedAds(2);

  /// Show the App Open ad on cold start.
  /// Call once after [init] completes. Never throws, never blocks
  /// startup — 4s max wait for the ad to be ready, then gives up.
  /// Gated by the remote app_open_ad.enabled flag (checked by the caller).
  ///
  /// ONCE PER LAUNCH: the first call (from the splash flow or from
  /// MainShell's existing call) wins; later calls return immediately,
  /// so the ad can never show twice in one cold start.
  ///
  /// LOAD SEMANTICS (unity_ads_plugin ^0.5.0): the native `load` call
  /// returns as soon as the load is STARTED — awaiting it does NOT mean
  /// the ad is ready. Readiness arrives later via the onComplete /
  /// onFailed callbacks, so this waits on [loadAppOpenAd]'s callback
  /// Completer (the splash preloads it) instead of on the load Future.
  static bool _appOpenAttempted = false;

  /// True once the App Open ad has been attempted this launch (shown
  /// or given up on). Guards the once-per-cold-start rule no matter
  /// which caller triggers the show.
  static bool get appOpenAttempted => _appOpenAttempted;

  /// Completer for the in-flight (or finished) App Open load, shared
  /// by the splash preload and the show. Completes true when the
  /// placement is filled, false on failure. One load per launch.
  static Completer<bool>? _appOpenLoadCompleter;
  static bool _appOpenLoaded = false;

  /// Load the App Open placement so it is ready to show. Safe to call
  /// repeatedly: concurrent callers share the one in-flight load, and
  /// a finished load answers immediately. Never throws. The returned
  /// Future completes only when the load callback fires (or the call
  /// itself fails) — callers add their own timeout.
  static Future<bool> loadAppOpenAd() async {
    if (!_initialized) return false;
    if (_appOpenLoaded) return true;
    final existing = _appOpenLoadCompleter;
    if (existing != null) return existing.future;
    final completer = Completer<bool>();
    _appOpenLoadCompleter = completer;
    try {
      await UnityAds.load(
        placementId: appOpenPlacementId,
        onComplete: (placementId) {
          _appOpenLoaded = true;
          if (!completer.isCompleted) completer.complete(true);
        },
        onFailed: (placementId, error, message) {
          if (!completer.isCompleted) completer.complete(false);
        },
      );
    } catch (_) {
      if (!completer.isCompleted) completer.complete(false);
    }
    return completer.future;
  }

  static Future<void> showAppOpenAd() async {
    if (_appOpenAttempted) return;
    _appOpenAttempted = true;
    if (!_initialized) return;
    try {
      // Wait for the splash preload; if nothing was preloaded, load
      // now. 4s max — the ad must never delay app start: not ready in
      // time means no ad this launch, home proceeds immediately.
      final loaded = await loadAppOpenAd().timeout(
        const Duration(seconds: 4),
        onTimeout: () => false,
      );
      if (!loaded) return;
      final completer = Completer<void>();
      UnityAds.showVideoAd(
        placementId: appOpenPlacementId,
        onStart: (placementId) {},
        onClick: (placementId) {},
        onSkipped: (placementId) {
          if (!completer.isCompleted) completer.complete();
        },
        onComplete: (placementId) {
          if (!completer.isCompleted) completer.complete();
        },
        onFailed: (placementId, error, message) {
          if (!completer.isCompleted) completer.complete();
        },
      );
      await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {},
      );
    } catch (_) {
      // Silently ignore — app continues to home.
    }
  }
}

/// Outcome of showing a rewarded ad.
enum UnityAdResult {
  /// User watched the full ad — credit the reward.
  completed,

  /// User skipped before the end — no reward.
  skipped,

  /// Ad failed to load or show — no reward, show retry.
  failed,
}

/// Zone-gated Unity banner (same mount as TJ Earn/Doner): passive bottom
/// banner above the bottom navigation bar. Renders nothing while loading,
/// when the master switch is off, or when its zone key is off — so the
/// layout never leaves a permanent empty band, and it never covers
/// content or buttons.
///
/// Every screen mounts one with its own zone key:
/// home, tts_studio, tools, briefing, speech_writer, converter,
/// my_audio, coins.
class UnityBannerAdWidget extends StatefulWidget {
  final String zone;

  const UnityBannerAdWidget({super.key, required this.zone});

  @override
  State<UnityBannerAdWidget> createState() => _UnityBannerAdWidgetState();
}

class _UnityBannerAdWidgetState extends State<UnityBannerAdWidget> {
  bool _loaded = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RemoteConfig>(
      valueListenable: RemoteConfigService.instance.notifier,
      builder: (context, config, _) {
        if (!UnityAdsService.adsConfigured) {
          return const SizedBox.shrink();
        }
        if (!config.bannerEnabled(widget.zone)) {
          return const SizedBox.shrink();
        }
        return Visibility(
          visible: _loaded,
          maintainState: true,
          child: SizedBox(
            height: 50,
            child: Center(
              child: UnityBannerAd(
                placementId: UnityAdsService.bannerPlacementId,
                onLoad: (placementId) {
                  if (mounted) setState(() => _loaded = true);
                },
                onClick: (placementId) {},
                onShown: (placementId) {},
                onFailed: (placementId, error, message) {
                  if (mounted) setState(() => _loaded = false);
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
