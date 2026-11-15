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
class AudioDownloadService {
  static Future<void> downloadWithAd(
    BuildContext context,
    AudioItem item,
  ) async {
    final adsOn = UnityAdsService.adsEnabledNow &&
        RemoteConfigService.instance.config.rewardedEnabled &&
        UnityAdsService.adsConfigured;
    if (adsOn) {
      await UnityAdsService.init();
      final loaded = await UnityAdsService.loadRewardedAd();
      if (loaded) {
        final result = await UnityAdsService.showRewardedAd();
        if (result != UnityAdResult.completed) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Watch the full ad to download the audio.'),
            ),
          );
          return;
        }
      }
      // Not loaded: no ad available right now — download anyway
      // (fail-soft, never punish the user for a missing ad).
    }
    await downloadDirect(context, item);
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
      // share_plus 10.x API (same version TJ Earn uses).
      await Share.shareXFiles(
        [XFile(item.filePath)],
        text: item.displayTitle,
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share failed: $e')),
      );
    }
  }
}
