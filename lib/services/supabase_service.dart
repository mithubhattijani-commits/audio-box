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
/// v1 auth: anonymous sign-in (no email/password). Enable "Anonymous
/// sign-ins" in the Supabase dashboard (Auth → Providers) before the
/// server ledger is used; until then the app runs local-only.
class SupabaseService {
  static SupabaseClient get client => Supabase.instance.client;

  static bool _initialized = false;

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

  /// Initialize Supabase + anonymous sign-in. Returns true when the
  /// server is reachable and a session exists. Never throws: false means
  /// local-only mode (coins stay on-device).
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
      try {
        if (client.auth.currentUser == null) {
          await client.auth.signInAnonymously().timeout(
                const Duration(seconds: 15),
              );
        }
      } catch (_) {
        // Anonymous sign-ins not enabled (or offline) — local-only mode.
        return false;
      }
      return client.auth.currentUser != null;
    } catch (_) {
      return false;
    }
  }

  static bool get isReady => _initialized && client.auth.currentUser != null;

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
