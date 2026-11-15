import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';

/// All Supabase access for Audio Box. Pattern copied from TJ Earn's
/// SupabaseService: every network call is bounded by a hard timeout so a
/// stalled network surfaces an error instead of hanging the UI.
///
/// SECURITY (same rule as TJ Earn): the app only ever *reads* the wallet
/// and *asks* Edge Functions to change it. There is deliberately no code
/// here that writes coins to the ledger table directly. Coin grants and
/// spends happen only inside Edge Functions (service role) — see
/// supabase/functions/.
///
/// v1.0.3 auth: Google sign-in (see google_auth_service.dart).
/// Anonymous sign-in is NOT automatic any more: coins must belong to a
/// real Google account. Anonymous sessions exist ONLY as the pre-link
/// step — [ensureAnonymousSession] creates one just before the Google
/// identity is linked onto it, so the same user.id (and coins) survives.
/// Enable BOTH "Anonymous sign-ins" AND "Enable Manual Linking" in the
/// Supabase dashboard (Auth -> Providers) or linking cannot work.
class SupabaseService {
  static SupabaseClient get client => Supabase.instance.client;

  static bool _initialized = false;

  /// Current user, or null when Supabase never initialized / no
  /// session. Guarded: `Supabase.instance.client` throws before
  /// `Supabase.initialize()` has run, and the login gate must never
  /// crash on that (offline / unconfigured build).
  static User? get currentUser {
    try {
      return client.auth.currentUser;
    } catch (_) {
      return null;
    }
  }

  /// True when the current session belongs to a Google-linked
  /// (non-anonymous) user — the only session allowed past the login
  /// gate. Anonymous sessions return false.
  static bool get hasGoogleSession {
    final user = currentUser;
    return user != null && !user.isAnonymous;
  }

  /// True when the current session is an anonymous user (v1.0.2
  /// upgrade, or the pre-link step before Google sign-in).
  static bool get hasAnonymousSession {
    final user = currentUser;
    return user != null && user.isAnonymous;
  }

  /// Bounded network guard (TJ Earn pattern): 25s default.
  static Future<T> _guard<T>(Future<T> Function() call,
      {int seconds = 25}) {
    return call().timeout(
      Duration(seconds: seconds),
      onTimeout: () => throw TimeoutException('Supabase request timed out'),
    );
  }

  static Future<FunctionResponse> _invoke(
    String functionName, {
    Map<String, dynamic>? body,
    HttpMethod method = HttpMethod.post,
  }) {
    return _guard(
      () => client.functions.invoke(
        functionName,
        body: body,
        method: method,
      ),
    );
  }

  /// Initialize Supabase ONLY — no session is created here any more.
  /// A persisted Google session is restored automatically by the SDK;
  /// a persisted anonymous session is restored too (v1.0.2 upgrade)
  /// and is then linked to Google from the login screen. Returns true
  /// when Supabase initialized. Never throws: false means local-only
  /// mode (coins stay on-device) and the login gate stays up.
  static Future<bool> init() async {
    if (!AppConfig.isConfigured) return false;
    try {
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        publishableKey: AppConfig.supabaseAnonKey,
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('Supabase init timed out'),
      );
      _initialized = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Create an anonymous session ONLY as the pre-link step before a
  /// Google sign-in (see GoogleAuthService). Returns true when an
  /// anonymous user now exists. Never throws.
  static Future<bool> ensureAnonymousSession() async {
    if (!_initialized) return false;
    try {
      final current = client.auth.currentUser;
      if (current != null) return current.isAnonymous;
      await client.auth.signInAnonymously().timeout(
            const Duration(seconds: 15),
          );
      return client.auth.currentUser?.isAnonymous == true;
    } catch (_) {
      return false;
    }
  }

  /// Link the Google identity (native ID token) onto the CURRENT user.
  /// The user keeps the same user.id — this is how an anonymous user's
  /// coins survive the move to Google. Requires "Enable Manual
  /// Linking" in the Supabase dashboard. Throws [AuthException] when
  /// the identity is already linked to another user.
  static Future<AuthResponse> linkGoogleIdentity({
    required String idToken,
    String? accessToken,
  }) {
    return _guard(
      () => client.auth.linkIdentityWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      ),
    );
  }

  /// Sign in with a Google ID token (fresh Google-owned user, or the
  /// user that already owns this Google identity). Used when there is
  /// no anonymous user to link, or when linking reports the identity
  /// already belongs to another user.
  static Future<AuthResponse> signInWithGoogleIdToken({
    required String idToken,
    String? accessToken,
  }) {
    return _guard(
      () => client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      ),
    );
  }

  static bool get isReady => _initialized && currentUser != null;

  /// True once [init] has run successfully this launch (Supabase SDK
  /// usable). The Google flow retries [init] if a first launch started
  /// offline, so a later sign-in tap is not stuck on a failed start.
  static bool get isInitialized => _initialized;

  /// Server balance (SUM of the ledger). Returns null when the function
  /// is not deployed / unreachable — the caller keeps the local balance.
  static Future<int?> getBalance() async {
    if (!isReady) return null;
    final res = await _invoke('audiobox-get-balance');
    if (res.status != 200) return null;
    final data = res.data;
    if (data is Map && data['balance_coins'] is int) {
      return data['balance_coins'] as int;
    }
    return null;
  }

  /// Claim the daily 100 free coins (server-side, once per day).
  /// Returns the granted amount, or null when not available.
  static Future<int?> claimDailyCoins() async {
    if (!isReady) return null;
    final res = await _invoke('audiobox-daily-coins');
    if (res.status != 200) return null;
    final data = res.data;
    if (data is Map && data['ok'] == true) {
      return data['coins'] as int? ?? 0;
    }
    return null;
  }

  /// Claim 50 coins for watching 2 rewarded ads (server-side).
  /// Call ONLY after both ads completed. Returns granted coins or null.
  static Future<int?> claimAdReward() async {
    if (!isReady) return null;
    final res = await _invoke('audiobox-claim-ad-reward');
    if (res.status != 200) return null;
    final data = res.data;
    if (data is Map && data['ok'] == true) {
      return data['coins'] as int? ?? 0;
    }
    return null;
  }

  /// Spend coins for an audio generation (server-side validation).
  /// Returns true when the server accepted the spend.
  static Future<bool> spendCoins(int amount, {String reason = 'tts_generation'}) async {
    if (!isReady) return false;
    final res = await _invoke('audiobox-spend-coins', body: {
      'amount_coins': amount,
      'reason': reason,
    });
    if (res.status != 200) return false;
    final data = res.data;
    return data is Map && data['ok'] == true;
  }
}
