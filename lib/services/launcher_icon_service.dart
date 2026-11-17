import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Launcher icon switch (v1.0.13): switches the Android launcher icon
/// between the bundled icons with NO rebuild and NO app update — the
/// choice comes from remote config (`launcher_icon`) and is applied at
/// startup and whenever the config value changes. A brand-new image
/// still needs ONE build to be bundled into a slot first.
///
/// Slots bundled in v1.0.13: "default" (the new photo icon, v1.0.12)
/// and "classic" (the red speaker icon, pre-v1.0.12). Unknown values
/// fall back to "default". The switch is best-effort and never throws.
class LauncherIconService {
  LauncherIconService._();

  static final LauncherIconService instance = LauncherIconService._();

  static const _channel = MethodChannel('nigraan.launcher_icon');
  static const _appliedKey = 'ab_launcher_icon_applied_v1';

  /// The icon ids this build can switch to.
  static const validIcons = {'default', 'classic'};

  String normalize(String? raw) {
    final v = (raw ?? '').trim().toLowerCase();
    return validIcons.contains(v) ? v : 'default';
  }

  /// Applies [icon] if it differs from the last-applied one. The
  /// last-applied value is remembered on-device, so a repeated call
  /// with the same value is a no-op (no native call, no relaunch).
  Future<void> applyIfChanged(String? icon) async {
    final want = normalize(icon);
    try {
      final prefs = await SharedPreferences.getInstance();
      final applied = prefs.getString(_appliedKey) ?? 'default';
      if (applied == want) return;
      final ok = await _channel.invokeMethod<bool>(
        'setLauncherIcon',
        {'icon': want},
      );
      if (ok == true) {
        await prefs.setString(_appliedKey, want);
      }
    } catch (_) {
      // Native call unavailable (e.g. non-Android): stay silent.
    }
  }
}
