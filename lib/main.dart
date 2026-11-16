import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/login_screen.dart';
import 'screens/main_shell.dart';
import 'screens/splash_screen.dart';
import 'services/audio_library_service.dart';
import 'services/coins_service.dart';
import 'services/google_auth_service.dart';
import 'services/remote_config_service.dart';
import 'theme.dart';

/// Language choice, persisted locally. Defaults to English.
/// (Same rule as TJ Earn + nigraantv.xyz: English default, Urdu second.)
final ValueNotifier<Locale> appLocale =
    ValueNotifier(const Locale('en'));

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('language');
  appLocale.value =
      saved == 'ur' ? const Locale('ur') : const Locale('en');

  // Local coin balance loads from disk BEFORE the first frame, so the
  // balance card renders instantly (TJ Earn pattern). Network work
  // (remote config, Supabase, Unity, update check) starts after the
  // first frame inside MainShell — nothing here may block startup.
  final coins = CoinsService();
  await coins.load();
  // Cached remote config (disk only, no network) loads before the first
  // frame so the splash screen can already use a remotely-set poster
  // image on this launch.
  await RemoteConfigService.instance.loadCache();
  final library = AudioLibraryService();

  runApp(AudioBoxApp(coins: coins, library: library, prefs: prefs));
}

class AudioBoxApp extends StatefulWidget {
  final CoinsService coins;
  final AudioLibraryService library;
  final SharedPreferences prefs;

  const AudioBoxApp({
    super.key,
    required this.coins,
    required this.library,
    required this.prefs,
  });

  @override
  State<AudioBoxApp> createState() => _AudioBoxAppState();
}

class _AudioBoxAppState extends State<AudioBoxApp> {
  /// False while the splash screen is showing; true once startup
  /// finished and the app shell takes over.
  bool _started = false;

  Future<void> _changeLocale(Locale locale) async {
    appLocale.value = locale;
    await widget.prefs.setString('language', locale.languageCode);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale>(
      valueListenable: appLocale,
      builder: (context, locale, _) {
        return MaterialApp(
          title: 'Magic Box From Jaani',
          locale: locale,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en'), Locale('ur')],
          theme: AudioBoxTheme.light,
          home: _started
              ? _AuthGate(
                  coins: widget.coins,
                  library: widget.library,
                  appLocale: appLocale,
                  onLocaleChanged: _changeLocale,
                )
              : SplashScreen(
                  onFinished: () => setState(() => _started = true),
                ),
        );
      },
    );
  }
}

/// Login gate (v1.0.3): after the splash, MainShell opens only when a
/// Google-linked Supabase session exists (restored by the SDK, or just
/// signed in). Otherwise the login screen shows — before MainShell and
/// before any coin feature. The check is synchronous: Supabase init
/// already ran during the splash, so the restored session is in memory.
class _AuthGate extends StatefulWidget {
  final CoinsService coins;
  final AudioLibraryService library;
  final ValueNotifier<Locale> appLocale;
  final Future<void> Function(Locale) onLocaleChanged;

  const _AuthGate({
    required this.coins,
    required this.library,
    required this.appLocale,
    required this.onLocaleChanged,
  });

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  late bool _signedIn;

  @override
  void initState() {
    super.initState();
    _signedIn = GoogleAuthService.isSignedIn;
  }

  @override
  Widget build(BuildContext context) {
    if (_signedIn) {
      return MainShell(
        coins: widget.coins,
        library: widget.library,
        appLocale: widget.appLocale,
        onLocaleChanged: widget.onLocaleChanged,
      );
    }
    return LoginScreen(
      onSignedIn: () => setState(() => _signedIn = true),
    );
  }
}
