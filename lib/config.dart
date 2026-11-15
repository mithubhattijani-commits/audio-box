/// Runtime configuration, supplied with --dart-define at build time.
///
/// Nothing secret is baked in here. The Supabase URL is public; the anon
/// key is a *public* Supabase key (RLS still enforces all access rules)
/// and is passed at build time, exactly like TJ Earn does:
///
///   flutter build apk --debug \
///     --dart-define=SUPABASE_URL=https://znyaxxkhhopdqrvxhxmb.supabase.co \
///     --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_KEY
class AppConfig {
  /// Public Supabase project URL (the shared "tj-earn" project).
  /// Default is the real project URL so local debug builds work without
  /// flags; override with --dart-define=SUPABASE_URL=... if ever needed.
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://znyaxxkhhopdqrvxhxmb.supabase.co',
  );

  /// Public Supabase anon (publishable) key. MUST be supplied at build
  /// time — use the same value TJ Earn uses (GitHub secret
  /// SUPABASE_ANON_KEY). If it is empty, the app runs in local-only mode:
  /// coins stay on-device and the server ledger sync is skipped.
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// Google Sign-In — Web OAuth client ID (the `serverClientId`).
  ///
  /// Set 15 Nov 2026 from the Google Cloud OAuth setup (project
  /// "Audio Box" audio-box-514810, Web client "Audio Box Web").
  /// Override at build time instead if ever needed:
  /// `--dart-define=GOOGLE_SERVER_CLIENT_ID=<web client id>`.
  /// NEVER guess this value — without the real one, Google returns no
  /// ID token and sign-in cannot complete.
  ///
  /// NO google-services.json is needed: google_sign_in 7 reads this
  /// value from `GoogleSignIn.instance.initialize(serverClientId: ...)`.
  /// (google-services.json is only a fallback source for the same ID,
  /// and is required only by Firebase, which this app does not use.)
  /// The Android OAuth client (package com.nigraantv.audiobox + the
  /// release SHA-1) must exist in the same Google Cloud project, or
  /// Android sign-in fails with a developer-configuration error.
  static const googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue: '1070324533167-6kcjv44or3l8lkij2ou1qkl398p800ka.apps.googleusercontent.com',
  );

  /// Nigraan TV TTS proxy (public Cloudflare Worker, no key in the app).
  /// DEFAULT only — the remote config (tts.proxy_url) overrides this at
  /// runtime, so the proxy can change without a rebuild.
  static const ttsProxyBase =
      'https://nigraan-tv-tts-proxy.mithubhattijani.workers.dev';

  /// Remote config (admin panel): ONE fixed URL, fetched on launch and
  /// every ~60s. Fail-soft: cached config + bundled defaults when offline.
  /// See lib/services/remote_config_service.dart for the full schema.
  static const remoteConfigUrl =
      'https://nigraantv.xyz/apps/config/audio-box.json';

  /// In-app update manifest (TJ Earn pattern): ONE fixed URL, checked on
  /// every launch, never rotated. Same JSON fields as TJ Earn's
  /// tj-earn-version.json (versionCode, versionName, url, notes) plus an
  /// optional minVersionCode for force-update. See
  /// lib/services/updater_service.dart.
  static const versionManifestUrl =
      'https://nigraantv.xyz/apps/audio-box-version.json';

  /// Nigraan TV site feeds used by the ticker, article list, Article
  /// Listen + News Briefing. DEFAULTS only — the remote config
  /// (feeds.rss_url / briefing_json_url / briefing_mp3_url) overrides
  /// them at runtime, so the feeds can change without a rebuild.
  static const siteRssUrl = 'https://nigraantv.xyz/rss.xml';
  static const briefingJsonUrl = 'https://nigraantv.xyz/briefing.json';
  static const briefingMp3Url = 'https://nigraantv.xyz/briefing.mp3';
}
