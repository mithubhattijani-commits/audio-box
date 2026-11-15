import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/main_shell.dart';
import 'services/audio_library_service.dart';
import 'services/coins_service.dart';
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
          title: 'Audio Box From Jaani',
          locale: locale,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en'), Locale('ur')],
          theme: AudioBoxTheme.light,
          home: MainShell(
            coins: widget.coins,
            library: widget.library,
            appLocale: appLocale,
            onLocaleChanged: _changeLocale,
          ),
        );
      },
    );
  }
}
