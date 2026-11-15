import 'package:flutter/material.dart';

import '../services/remote_config_service.dart';

/// Remote-controlled ribbon bar directly UNDER the Home news ticker
/// (above the sponsored card). Values come from audio-box.json
/// `ribbon`: enabled / color / text / height. No new colors are
/// compiled in beyond the #3D5AFE fallback for an invalid hex string.
/// Empty text = solid colored bar; non-empty text = centered white.
///
/// Listens to the remote-config notifier, so a website change applies
/// within seconds while the app is online — no rebuild.
class NewsRibbon extends StatelessWidget {
  const NewsRibbon({super.key});

  /// Parses "#RRGGBB" or "#AARRGGBB" (with or without '#'). Any
  /// invalid value falls back to #3D5AFE.
  static Color parseColor(String raw) {
    var hex = raw.trim();
    if (hex.startsWith('#')) hex = hex.substring(1);
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length == 8) {
      final value = int.tryParse(hex, radix: 16);
      if (value != null) return Color(value);
    }
    return const Color(0xFF3D5AFE);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RemoteConfig>(
      valueListenable: RemoteConfigService.instance.notifier,
      builder: (context, cfg, _) {
        final ribbon = cfg.ribbon;
        if (!ribbon.enabled) return const SizedBox.shrink();
        final text = ribbon.text.trim();
        return Container(
          width: double.infinity,
          height: ribbon.height,
          color: parseColor(ribbon.color),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: text.isEmpty
              ? null
              : Text(
                  text,
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
        );
      },
    );
  }
}
