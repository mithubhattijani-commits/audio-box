import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/audio_item.dart';
import 'ads_service.dart';
import 'remote_config_service.dart';

/// Download / share for a saved audio file.
///
/// Download is gated by ONE rewarded video ad (15 Nov 2026): the user
/// watches the ad fully, then the file is copied to the phone's Download
/// folder. If ads are off in the remote config, or no ad is available
/// right now, the file downloads directly — the user is never blocked
/// from their own audio. If the user skips the ad, nothing downloads.
///
/// Caption downloads (SRT/ASS, v1.0.6) use a multi-ad gate instead
/// ([downloadBytesWithAds]): the number of rewarded ads comes from
/// the remote config (`download.ads_required`, default 2, NO upper
/// limit) and ALL must complete — skip any one = no delivery.
///
/// ONE ad flow only: [_playRewardedAdGate] is the single gate every
/// download path goes through — saved audio ([downloadWithAd]), raw
/// bytes such as a generated SRT file ([downloadBytesWithAd]), and the
/// MP3 Converter's converted-file download. No second ad flow exists.
class AudioDownloadService {
  /// The single rewarded-ad gate. Returns true when the download may
  /// proceed (ad completed, or ads off / no ad loaded — fail-soft),
  /// false when the user skipped the ad (nothing is delivered).
  static Future<bool> _playRewardedAdGate(BuildContext context) async {
    final adsOn = UnityAdsService.adsEnabledNow &&
        RemoteConfigService.instance.config.rewardedEnabled &&
        UnityAdsService.adsConfigured;
    if (!adsOn) return true;
    await UnityAdsService.init();
    final loaded = await UnityAdsService.loadRewardedAd();
    if (!loaded) return true; // No ad available — deliver anyway.
    final result = await UnityAdsService.showRewardedAd();
    if (result != UnityAdResult.completed) {
      if (!context.mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Watch the full ad to download the file.'),
        ),
      );
      return false;
    }
    return true;
  }

  static Future<void> downloadWithAd(
    BuildContext context,
    AudioItem item,
  ) async {
    if (!await _playRewardedAdGate(context)) return;
    if (!context.mounted) return;
    await downloadDirect(context, item);
  }

  /// Download arbitrary bytes (e.g. a generated .srt caption file) to
  /// the phone's Download folder, through the SAME one-ad gate as
  /// [downloadWithAd]: 1 rewarded ad, then the file saves; fail-soft
  /// when ads are off or no ad loads; skip = no delivery.
  static Future<void> downloadBytesWithAd(
    BuildContext context, {
    required String fileName,
    required List<int> bytes,
  }) async {
    if (!await _playRewardedAdGate(context)) return;
    if (!context.mounted) return;
    await _saveBytes(context, fileName: fileName, bytes: bytes);
  }

  /// Download bytes through the N-ad gate (caption downloads,
  /// v1.0.7, user order 16 Nov): [adsRequired] rewarded ads
  /// back-to-back and ALL must be watched fully. NO upper limit on
  /// [adsRequired] — any number from the remote config works (ads ki
  /// koi limit ni). 0 = no ad, the file saves directly. If the user
  /// skips ANY ad, nothing is delivered — they must tap download
  /// again and watch all ads again from the start. Fail-soft only
  /// when ads are off or no ad loads (the gate itself returns true
  /// then).
  static Future<void> downloadBytesWithAds(
    BuildContext context, {
    required int adsRequired,
    required String fileName,
    required List<int> bytes,
  }) async {
    for (var i = 0; i < adsRequired; i++) {
      if (!await _playRewardedAdGate(context)) return; // Ad skipped.
      if (!context.mounted) return;
    }
    await _saveBytes(context, fileName: fileName, bytes: bytes);
  }

  /// Download bytes through the TWO-ad gate (caption downloads,
  /// v1.0.6, user order 16 Nov): two rewarded ads back-to-back and
  /// BOTH must be watched fully. If the user skips EITHER ad, nothing
  /// is delivered — they must tap download again and watch both ads
  /// again from the start. Fail-soft only when ads are off or no ad
  /// loads (the gate itself returns true then).
  ///
  /// Kept for compatibility; new code should use
  /// [downloadBytesWithAds] with the remote-config count.
  static Future<void> downloadBytesWithTwoAds(
    BuildContext context, {
    required String fileName,
    required List<int> bytes,
  }) async {
    await downloadBytesWithAds(
      context,
      adsRequired: 2,
      fileName: fileName,
      bytes: bytes,
    );
  }

  static Future<void> _saveBytes(
    BuildContext context, {
    required String fileName,
    required List<int> bytes,
  }) async {
    try {
      final extDir = await getExternalStorageDirectory();
      final downloads = Directory('${extDir?.path}/Download');
      if (!await downloads.exists()) await downloads.create(recursive: true);
      final target = File('${downloads.path}/$fileName');
      await target.writeAsBytes(bytes);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to ${target.path}')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    }
  }

  static Future<void> downloadDirect(
    BuildContext context,
    AudioItem item,
  ) async {
    try {
      final extDir = await getExternalStorageDirectory();
      final downloads = Directory('${extDir?.path}/Download');
      if (!await downloads.exists()) await downloads.create(recursive: true);
      final target = File('${downloads.path}/${item.id}.${item.ext}');
      await File(item.filePath).copy(target.path);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to ${target.path}')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    }
  }

  static Future<void> share(BuildContext context, AudioItem item) async {
    try {
      // share_plus 13.x API (the old static Share.shareXFiles is
      // deprecated in 13.x). ShareParams throws on empty text, so
      // only pass it when non-empty.
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(item.filePath)],
          text: item.displayTitle.isNotEmpty ? item.displayTitle : null,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share failed: $e')),
      );
    }
  }
}
