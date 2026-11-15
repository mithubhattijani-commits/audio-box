import 'package:flutter/material.dart';

import '../config.dart';
import '../l10n/strings.dart';
import '../services/ads_service.dart';
import '../services/coins_service.dart';
import '../services/remote_config_service.dart';
import '../services/supabase_service.dart';

/// Coins: balance, daily free claim, and the rewarded-video options.
///
/// Rewarded options come from the remote config (each option: label,
/// ads_required, coins). One tap plays its ads back-to-back; coins are
/// granted ONLY when every ad completes fully.
class CoinsScreen extends StatefulWidget {
  final CoinsService coins;

  const CoinsScreen({super.key, required this.coins});

  @override
  State<CoinsScreen> createState() => _CoinsScreenState();
}

class _CoinsScreenState extends State<CoinsScreen> {
  bool _busy = false;
  String? _message;

  Future<void> _claimDaily() async {
    final ok = await widget.coins.claimDaily();
    if (!mounted) return;
    setState(() {
      _message = ok
          ? 'You got ${widget.coins.dailyFreeCoins} free coins!'
          : AppStrings.tr('daily_claimed', Localizations.localeOf(context));
    });
  }

  Future<void> _watchAds(RewardOption option) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final completed =
          await UnityAdsService.showNRewardedAds(option.adsRequired);
      if (!mounted) return;
      if (!completed) {
        setState(() {
          _message = AppStrings.tr('watch_both_ads', Localizations.localeOf(context));
        });
        return;
      }
      await widget.coins.add(option.coins, reason: 'ad_reward:${option.id}');
      // Server ledger (best-effort until functions are deployed).
      unawaited(SupabaseService.claimAdReward());
      setState(() {
        _message = 'You earned ${option.coins} coins!';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context);
    return Scaffold(
      appBar: AppBar(title: Text(AppStrings.tr('coins', locale))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: Theme.of(context).colorScheme.primary,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text(
                      AppStrings.tr('balance', locale),
                      style: const TextStyle(color: Colors.white70),
                    ),
                    ValueListenableBuilder<int>(
                      valueListenable: widget.coins.balance,
                      builder: (context, balance, _) {
                        return Text(
                          '$balance',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 44,
                            fontWeight: FontWeight.bold,
                          ),
                        );
                      },
                    ),
                    const Text(
                      'coins',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed:
                  widget.coins.canClaimDaily && !_busy ? _claimDaily : null,
              icon: const Icon(Icons.card_giftcard),
              label: Text(AppStrings.tr('daily_coins', locale)),
            ),
            if (!widget.coins.canClaimDaily)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  AppStrings.tr('daily_claimed', locale),
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
            const SizedBox(height: 16),
            ValueListenableBuilder<RemoteConfig>(
              valueListenable: RemoteConfigService.instance.notifier,
              builder: (context, cfg, _) {
                if (!cfg.rewardedEnabled) {
                  return const Text(
                    'Rewarded ads are off right now.',
                    style: TextStyle(color: Colors.grey),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final option in cfg.rewardedOptions)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: OutlinedButton.icon(
                          onPressed: _busy
                              ? null
                              : () => _watchAds(option),
                          icon: const Icon(Icons.play_circle_filled),
                          label: Text(option.label),
                        ),
                      ),
                  ],
                );
              },
            ),
            if (!UnityAdsService.adsConfigured)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Ads are being set up — Unity IDs are not filled in yet.',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            if (!AppConfig.isConfigured)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  AppStrings.tr('local_only', locale),
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _message!,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            const SizedBox(height: 16),
            const Text(
              'Coins buy audio generation in this app (50 coins ≈ 1 minute). Coins are never cash and can never be withdrawn.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const UnityBannerAdWidget(zone: 'coins'),
    );
  }
}
