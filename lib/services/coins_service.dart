import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_config_service.dart';
import 'supabase_service.dart';

/// Coin economy (user's numbers, 15 Nov 2026):
/// - Daily free: 100 coins (claim once per calendar day).
/// - One audio generation (~1 minute chunk): coinsPerMinute from the
///   remote config (default 50).
/// - Rewarded options from the remote config (default: 2 ads = 50 coins,
///   one tap, both ads back-to-back).
/// - Daily generation cap from the remote config (tts.daily_cap,
///   default 10/day, 0 = unlimited).
///
/// v1 stores the balance LOCALLY (SharedPreferences) so the UI always
/// works. When Supabase is configured and the Edge Functions are deployed,
/// every local change is also sent to the server ledger and the server
/// balance wins on sync — the server is the source of truth once live.
/// Until then the app is honest about it (see Coins screen note).
class CoinsService {
  /// Bundled defaults (used when the remote config is unreachable).
  static const int defaultDailyFreeCoins = 100;
  static const int defaultCoinsPerMinute = 50;
  static const int defaultDailyCap = 10;

  static const String _balanceKey = 'ab_balance';
  static const String _dailyClaimKey = 'ab_daily_claimed_date';
  static const String _gensDateKey = 'ab_gens_date';
  static const String _gensCountKey = 'ab_gens_count';

  final ValueNotifier<int> balance = ValueNotifier<int>(0);

  bool _loaded = false;
  SharedPreferences? _prefs;

  /// Coins charged per ~1-minute generation chunk (remote config).
  int get coinsPerMinute =>
      RemoteConfigService.instance.config.tts.coinsPerMinute;

  /// Max generations per user per day, 0 = unlimited (remote config).
  int get dailyCap => RemoteConfigService.instance.config.tts.dailyCap;

  /// Daily free coins (bundled constant).
  int get dailyFreeCoins => defaultDailyFreeCoins;

  Future<void> load() async {
    if (_loaded) return;
    _prefs = await SharedPreferences.getInstance();
    balance.value = _prefs!.getInt(_balanceKey) ?? 0;
    _loaded = true;
    // Best-effort server sync; never blocks the UI.
    unawaited(syncFromServer());
  }

  Future<void> _save() async {
    await _prefs?.setInt(_balanceKey, balance.value);
  }

  bool canAfford(int cost) => balance.value >= cost;

  /// Generations used today (local counter; server enforces it too once
  /// the functions are deployed).
  int get generationsUsedToday {
    final today = _todayKey();
    if ((_prefs?.getString(_gensDateKey) ?? '') != today) return 0;
    return _prefs?.getInt(_gensCountKey) ?? 0;
  }

  /// True when the daily generation cap still allows another generation.
  bool get canGenerate =>
      dailyCap <= 0 || generationsUsedToday < dailyCap;

  Future<void> recordGeneration() async {
    final today = _todayKey();
    if ((_prefs?.getString(_gensDateKey) ?? '') != today) {
      await _prefs?.setString(_gensDateKey, today);
      await _prefs?.setInt(_gensCountKey, 1);
    } else {
      final n = (_prefs?.getInt(_gensCountKey) ?? 0) + 1;
      await _prefs?.setInt(_gensCountKey, n);
    }
  }

  /// Spend [cost] coins locally. Returns false if the balance is too low.
  /// The caller should already have checked [canAfford].
  Future<bool> spend(int cost, {String reason = 'tts_generation'}) async {
    if (!canAfford(cost)) return false;
    balance.value -= cost;
    await _save();
    // Server ledger (best-effort until functions are deployed).
    unawaited(SupabaseService.spendCoins(cost, reason: reason));
    return true;
  }

  /// Add [amount] coins locally (daily claim / ad reward).
  Future<void> add(int amount, {String reason = 'reward'}) async {
    balance.value += amount;
    await _save();
  }

  /// True when today's daily coins have NOT been claimed yet.
  bool get canClaimDaily {
    final claimed = _prefs?.getString(_dailyClaimKey) ?? '';
    final today = _todayKey();
    return claimed != today;
  }

  /// Claim the daily 100 free coins. Returns false if already claimed.
  Future<bool> claimDaily() async {
    if (!canClaimDaily) return false;
    await _prefs?.setString(_dailyClaimKey, _todayKey());
    await add(dailyFreeCoins, reason: 'daily_free');
    unawaited(SupabaseService.claimDailyCoins());
    return true;
  }

  /// Pull the server balance (when the functions are deployed) and use it
  /// as the source of truth. Silently does nothing when offline or when
  /// the functions are not deployed yet.
  Future<void> syncFromServer() async {
    try {
      final serverBalance = await SupabaseService.getBalance();
      if (serverBalance == null) return;
      if (serverBalance != balance.value) {
        balance.value = serverBalance;
        await _save();
      }
    } catch (_) {
      // Local-only mode: keep the local balance.
    }
  }

  static String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }
}
