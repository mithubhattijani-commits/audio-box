import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/ads_service.dart';
import '../services/audio_library_service.dart';
import '../services/coins_service.dart';
import '../services/remote_config_service.dart';
import '../services/supabase_service.dart';
import '../services/updater_service.dart';
import 'coins_screen.dart';
import 'home_screen.dart';
import 'my_audio_screen.dart';
import 'tts_screen.dart';

/// Bottom-nav shell (Home / TTS Studio / Coins / My Audio).
///
/// Startup order (TJ Earn pattern — nothing network-related blocks the
/// first frame):
/// - Remote config init (cache first, then network, 60s poll).
/// - Supabase init (anonymous sign-in, best-effort).
/// - Unity init + App Open ad on cold start (when app_open_ad.enabled).
/// - In-app update check (fixed version URL, every launch).
/// - Resume refreshes the remote config.
class MainShell extends StatefulWidget {
  final CoinsService coins;
  final AudioLibraryService library;
  final ValueNotifier<Locale> appLocale;
  final Future<void> Function(Locale) onLocaleChanged;

  const MainShell({
    super.key,
    required this.coins,
    required this.library,
    required this.appLocale,
    required this.onLocaleChanged,
  });

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _index = 0;
  bool _appOpenAttempted = false;

  static const List<String> _zones = ['home', 'tts_studio', 'coins', 'my_audio'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Fire-and-forget startup work — never blocks the first frame.
      unawaited(RemoteConfigService.instance.init());
      unawaited(SupabaseService.init());
      // Update check (fixed version URL, every launch).
      unawaited(UpdaterService.checkForUpdate(context));
      // Unity init + App Open ad on cold start.
      Future.delayed(const Duration(seconds: 3), () {
        if (!_appOpenAttempted) {
          _appOpenAttempted = true;
          unawaited(
            UnityAdsService.init().then((_) {
              if (RemoteConfigService.instance.config.appOpenAdEnabled) {
                unawaited(UnityAdsService.showAppOpenAd());
              }
            }),
          );
        }
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Resume: refresh the remote config (TJ Earn pattern).
      unawaited(RemoteConfigService.instance.refresh());
    }
  }

  void _goToTab(int index) {
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale>(
      valueListenable: widget.appLocale,
      builder: (context, locale, _) {
        final screens = <Widget>[
          HomeScreen(
            coins: widget.coins,
            library: widget.library,
            appLocale: widget.appLocale,
            onLocaleChanged: widget.onLocaleChanged,
            onOpenTab: _goToTab,
          ),
          TtsScreen(
            coins: widget.coins,
            library: widget.library,
            appLocale: widget.appLocale,
          ),
          CoinsScreen(coins: widget.coins),
          MyAudioScreen(library: widget.library),
        ];
        return Scaffold(
          body: IndexedStack(index: _index, children: screens),
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Passive banner, zone follows the current tab.
              UnityBannerAdWidget(zone: _zones[_index]),
              BottomNavigationBar(
                currentIndex: _index,
                onTap: _goToTab,
                items: [
                  BottomNavigationBarItem(
                    icon: const Icon(Icons.home),
                    label: AppStrings.tr('home', locale),
                  ),
                  BottomNavigationBarItem(
                    icon: const Icon(Icons.mic),
                    label: AppStrings.tr('tts_studio', locale),
                  ),
                  BottomNavigationBarItem(
                    icon: const Icon(Icons.monetization_on),
                    label: AppStrings.tr('coins', locale),
                  ),
                  BottomNavigationBarItem(
                    icon: const Icon(Icons.library_music),
                    label: AppStrings.tr('my_audio', locale),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
