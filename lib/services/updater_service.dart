import 'dart:convert';
import 'dart:ffi';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';

/// In-app updater — TJ Earn's version-check pattern, copied precisely.
///
/// - ONE fixed manifest URL, checked on EVERY launch, never rotated:
///   https://nigraantv.xyz/apps/audio-box-version.json
/// - Same JSON fields as TJ Earn's tj-earn-version.json:
///   { versionCode (int), versionName (string), url (APK link),
///     notes (string) }
///   plus ONE additive field for force-update:
///   { minVersionCode (int, optional, default 0 = no force) }
///   plus TWO additive fields for split APKs (v1.0.11, optional):
///   { urls: {arm64-v8a, armeabi-v7a, x86_64} (per-ABI APK links),
///     versionCodes: {arm64-v8a, armeabi-v7a, x86_64} (per-ABI codes:
///     2000/1000/4000 + base) } — the device's ABI wins; anything
///   missing falls back to the single url / versionCode.
/// - Same check-on-launch behaviour: silent when up to date, silent when
///   the file is unreachable, "Later" dismisses that versionCode once.
/// - Below minVersionCode -> FORCE update: blocking dialog, no Later,
///   app cannot be used until updated. Below latest (above min) ->
///   optional prompt with Later / Update Now.
///
/// ONE deliberate deviation from TJ Earn: the download. TJ Earn downloads
/// the APK in-app via Android DownloadManager (native MethodChannel +
/// receiver). v1 opens the APK URL in the external browser instead — the
/// browser downloads it and the user taps the finished download to
/// install (same package + higher versionCode = update, data kept).
/// Porting the DownloadManager flow is a follow-up; the check, the
/// dialogs and the JSON contract are identical.
class UpdaterService {
  /// THE fixed version URL. Same URL every time — never rotated/changed.
  static const String manifestUrl = AppConfig.versionManifestUrl;

  static const String _dismissedKey = 'ab_update_dismissed_code';

  /// True when the server reports a strictly newer build.
  static bool isNewerVersion(int latestCode, int currentCode) =>
      latestCode > currentCode;

  /// This device's ABI as the manifest's "urls" map names it
  /// (arm64-v8a / armeabi-v7a / x86_64), or null when it is none of
  /// those. `dart:ffi` reports the ABI the app itself runs under —
  /// exactly the split APK the device needs — with no new dependency.
  static String? _currentAbiName() {
    final abi = Abi.current();
    if (abi == Abi.androidArm64) return 'arm64-v8a';
    if (abi == Abi.androidArm) return 'armeabi-v7a';
    if (abi == Abi.androidX64) return 'x86_64';
    return null;
  }

  /// The versionCode that counts as "latest" for THIS device (v1.0.11).
  /// Split APKs carry ABI-suffixed codes (Flutter's --split-per-abi
  /// scheme: armeabi-v7a = 1000 + base, arm64-v8a = 2000 + base,
  /// x86_64 = 4000 + base — so base 12 ships as 1012 / 2012 / 4012),
  /// so the manifest may carry a per-ABI "versionCodes" map alongside
  /// the single "versionCode". The device's own ABI wins; anything
  /// unknown falls back to the single "versionCode", so old manifests
  /// keep working. Without this, a phone on a split build (e.g. 2012)
  /// would never be offered the next update (manifest "versionCode"
  /// 13 is not > 2012).
  static int? _latestVersionCode(Map<String, dynamic> manifest) {
    final codes = manifest['versionCodes'];
    if (codes is Map<String, dynamic>) {
      final abiName = _currentAbiName();
      if (abiName != null) {
        final code = codes[abiName];
        if (code is int) return code;
        if (code is num) return code.toInt();
      }
    }
    final fallback = manifest['versionCode'];
    if (fallback is int) return fallback;
    if (fallback is num) return fallback.toInt();
    return null;
  }

  /// Pick the APK download URL for this device from the manifest.
  /// v1.0.11: the manifest may carry a per-ABI "urls" map alongside
  /// the legacy universal "url":
  ///   { "url": "UNIVERSAL-APK-URL", "urls": {"arm64-v8a": "...",
  ///     "armeabi-v7a": "...", "x86_64": "..."} }
  /// The device's own ABI wins (split APK, ~120 MB instead of the
  /// ~295 MB universal). Anything unknown — an old manifest without
  /// "urls", an ABI not in the map — falls back to the universal
  /// "url", so old manifests keep working unchanged.
  static String? _pickDownloadUrl(Map<String, dynamic> manifest) {
    final urls = manifest['urls'];
    if (urls is Map<String, dynamic>) {
      final abiName = _currentAbiName();
      if (abiName != null) {
        final abiUrl = urls[abiName];
        if (abiUrl is String && abiUrl.isNotEmpty) return abiUrl;
      }
    }
    final fallback = manifest['url'];
    if (fallback is String && fallback.isNotEmpty) return fallback;
    return null;
  }

  static Future<Map<String, dynamic>?> _fetchManifest() async {
    try {
      final res = await http
          .get(Uri.parse(manifestUrl))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) return null;
      return decoded;
    } catch (_) {
      return null;
    }
  }

  static Future<int?> _dismissedCode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_dismissedKey);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _recordDismissed(int versionCode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_dismissedKey, versionCode);
    } catch (_) {
      // Best-effort.
    }
  }

  /// Silent launch check (TJ Earn's checkForUpdate). Call once after the
  /// first frame. Never throws, never blocks startup, never shows
  /// anything when up to date or when the manifest is unreachable.
  static Future<void> checkForUpdate(BuildContext context) async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!context.mounted) return;
      final currentCode = int.tryParse(info.buildNumber) ?? 0;
      final latest = await _fetchManifest();
      if (latest == null) return;
      final latestCode = _latestVersionCode(latest);
      final apkUrl = _pickDownloadUrl(latest);
      if (latestCode == null || apkUrl == null) return;
      if (!isNewerVersion(latestCode, currentCode)) return;

      // Force update: installed build is below the minimum supported.
      final minCode = (latest['minVersionCode'] as num?)?.toInt() ?? 0;
      final forced = minCode > 0 && currentCode < minCode;
      if (!forced && await _dismissedCode() == latestCode) return;
      if (!context.mounted) return;

      final versionName = latest['versionName'] as String? ?? '';
      final notes = latest['notes'] as String? ?? '';
      final wantUpdate = await showDialog<bool>(
        context: context,
        // Force-update cannot be dismissed: the app stays unusable.
        barrierDismissible: !forced,
        builder: (ctx) => PopScope(
          // Back button must not escape a force-update either.
          canPop: !forced,
          child: AlertDialog(
            title: Text(
              forced ? 'Update required' : 'Update available',
            ),
            content: Text(
              [
                if (versionName.isNotEmpty) versionName,
                if (notes.isNotEmpty) notes,
                if (forced)
                  'This version is no longer supported. Please update to continue using Magic Box.',
              ].join('\n\n').trim(),
            ),
            actions: [
              if (!forced)
                TextButton(
                  onPressed: () {
                    _recordDismissed(latestCode);
                    Navigator.of(ctx).pop(false);
                  },
                  child: const Text('Later'),
                ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Update now'),
              ),
            ],
          ),
        ),
      );
      if (wantUpdate != true) return;
      await _openUpdateUrl(apkUrl);
    } catch (_) {
      // Update checks must never break the app: fail silently.
    }
  }

  /// Manual check with messages (TJ Earn's checkManually). Wired to the
  /// "Check for updates" button on Home.
  static Future<void> checkManually(BuildContext context) async {
    try {
      final latest = await _fetchManifest();
      if (!context.mounted) return;
      if (latest == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Update info not found.')),
        );
        return;
      }
      final latestCode = _latestVersionCode(latest);
      final apkUrl = _pickDownloadUrl(latest);
      if (latestCode == null || apkUrl == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Update info not found.')),
        );
        return;
      }
      final info = await PackageInfo.fromPlatform();
      if (!context.mounted) return;
      final currentCode = int.tryParse(info.buildNumber) ?? 0;
      if (!isNewerVersion(latestCode, currentCode)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You are on the latest version.')),
        );
        return;
      }
      final minCode = (latest['minVersionCode'] as num?)?.toInt() ?? 0;
      final forced = minCode > 0 && currentCode < minCode;
      final versionName = latest['versionName'] as String? ?? '';
      final notes = latest['notes'] as String? ?? '';
      final wantUpdate = await showDialog<bool>(
        context: context,
        barrierDismissible: !forced,
        builder: (ctx) => PopScope(
          canPop: !forced,
          child: AlertDialog(
            title: Text(forced ? 'Update required' : 'Update available'),
            content: Text(
              [if (versionName.isNotEmpty) versionName, if (notes.isNotEmpty) notes]
                  .join('\n\n')
                  .trim(),
            ),
            actions: [
              if (!forced)
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Later'),
                ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Update now'),
              ),
            ],
          ),
        ),
      );
      if (wantUpdate == true) await _openUpdateUrl(apkUrl);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not check for updates.')),
      );
    }
  }

  /// v1 download path: open the APK URL in the external browser (see the
  /// class doc for why this differs from TJ Earn's DownloadManager flow).
  static Future<void> _openUpdateUrl(String apkUrl) async {
    try {
      final uri = Uri.parse(apkUrl);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // The dialog already closed; the user can retry from Home.
    }
  }
}
