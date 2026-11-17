import 'dart:async';

import 'ads_service.dart';
import 'app_open_ad_service.dart';
import 'google_auth_service.dart';
import 'remote_config_service.dart';
import 'supabase_service.dart';

/// Cold-start sequence, run exactly once per launch by the splash
/// screen, with progress 0.0-1.0 for the 1-100% loading count.
///
/// Same order as the old MainShell startup (TJ Earn pattern):
/// remote config cache, Supabase init (NO auto anonymous sign-in
/// since v1.0.3 — the login gate requires a Google-linked session),
/// Google sign-in pre-warm, Unity init.
/// Every step is best-effort and never throws, so a slow or offline
/// start still reaches the app. The in-app update check is NOT here:
/// it shows a dialog, so it still runs from MainShell, whose context
/// stays mounted.
class AppStartup {
  static bool _done = false;

  /// True once the cold-start sequence has run this launch.
  static bool get done => _done;

  static Future<void> run({
    required void Function(double progress, String label) onProgress,
  }) async {
    if (_done) {
      onProgress(1, 'Ready');
      return;
    }
    final started = DateTime.now();
    void report(double p, String label) => onProgress(p.clamp(0, 1), label);

    report(0.05, 'Loading settings...');
    try {
      await RemoteConfigService.instance.init().timeout(
            const Duration(seconds: 10),
            onTimeout: () {},
          );
    } catch (_) {
      // Offline or slow: bundled defaults stay in effect.
    }
    report(0.30, 'Connecting...');
    try {
      await SupabaseService.init();
    } catch (_) {
      // Local-only mode: coins stay on-device.
    }
    // Google sign-in pre-warm (silent restore only; the login gate
    // decides from the Supabase session). No-op until the Web OAuth
    // client ID is supplied in AppConfig.
    try {
      await GoogleAuthService.ensureInitialized().timeout(
            const Duration(seconds: 15),
            onTimeout: () => false,
          );
    } catch (_) {
      // Google unavailable — the login screen explains and retries.
    }
    report(0.55, 'Loading ads...');
    try {
      await UnityAdsService.init();
    } catch (_) {
      // Ads stay inert until Unity is ready.
    }
    // Preload the App Open ad while the splash is still showing, so it
    // is usually already loaded when the splash finishes and can show
    // immediately after it. Fire-and-forget: never blocks the splash,
    // and a failed load just means no ad this launch (fail-soft).
    AppOpenAdService.preload();
    report(0.80, 'Almost ready...');

    // Minimum splash time so the picture and the 1-100 count are
    // actually seen: a fast launch would otherwise flash past.
    final elapsed = DateTime.now().difference(started);
    const minSplash = Duration(milliseconds: 2200);
    if (elapsed < minSplash) {
      await Future.delayed(minSplash - elapsed);
    }
    _done = true;
    report(1, 'Ready');
  }
}
