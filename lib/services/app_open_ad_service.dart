import 'dart:async';

import 'ads_service.dart';
import 'remote_config_service.dart';

/// Cold-start App Open ad flow for Audio Box From Jaani (v1.0.10).
///
/// Flow: splash preloads the ad while the poster is showing
/// ([preload], called from [AppStartup] after Unity init) → after the
/// splash, the auth gate shows it once ([showIfColdStart]) → home.
///
/// Rules (user order 17 Nov 2026):
/// 1. ONCE per cold start only — never on resume / return from
///    background. Enforced by [UnityAdsService.appOpenAttempted]:
///    the first show attempt this launch (from here or from MainShell's
///    existing call) wins; every later attempt is a no-op. Static state
///    lives only for this process, so a fresh launch starts clean.
/// 2. FAIL-SOFT, never blocks app start: the show waits at most 4s for
///    the preloaded ad to be ready (see [UnityAdsService.showAppOpenAd]);
///    not ready in time, load failed, Unity not initialised, or the
///    remote switch off → no ad, home proceeds immediately, no error.
/// 3. Remote config: the ad shows only when the master switch is on
///    ([UnityAdsService.adsEnabledNow]) AND `app_open_ad.enabled` is on
///    in audio-box.json (live: enabled=true). The placement id comes
///    from `unity.app_open_placement_id` (live: BP_Interstitial_Android).
/// 4. No dedicated App Open API exists in unity_ads_plugin ^0.5.0 — the
///    App Open ad IS the interstitial-format placement
///    BP_Interstitial_Android (same setup as TJ Earn; the Unity
///    dashboard offers no separate App Open format for this project).
/// 5. Login flow untouched: the caller ([_AuthGate] in main.dart) only
///    calls [showIfColdStart] when the start flow is going to home.
///    When it goes to login instead, nothing shows before login; the ad
///    runs after a successful login-to-home transition (same cold
///    start, same once-per-launch flag).
class AppOpenAdService {
  static bool _preloadStarted = false;

  /// True when the App Open ad may show this launch: Unity IDs are
  /// configured, the remote master switch is on, the remote
  /// app_open_ad.enabled flag is on, and no attempt has been made yet.
  static bool get enabled =>
      UnityAdsService.adsEnabledNow &&
      RemoteConfigService.instance.config.appOpenAdEnabled &&
      !UnityAdsService.appOpenAttempted;

  /// Start loading the App Open ad in the background. Called once from
  /// the splash (after Unity init) so the ad is usually already loaded
  /// when the splash finishes. Fire-and-forget: never throws, never
  /// blocks, no-op when disabled or already started.
  static void preload() {
    if (!enabled || _preloadStarted) return;
    _preloadStarted = true;
    unawaited(UnityAdsService.loadAppOpenAd());
  }

  /// Show the App Open ad once, if it is loaded in time (4s max wait
  /// for readiness, then home proceeds). Returns after the ad finishes,
  /// is skipped, or fails — or immediately when there is no ad to show.
  /// Never throws. Safe to call from several places: the first call
  /// wins, the rest are no-ops.
  static Future<void> showIfColdStart() async {
    if (!enabled) return;
    try {
      await UnityAdsService.showAppOpenAd();
    } catch (_) {
      // Fail-soft — the caller proceeds to home regardless.
    }
  }
}
