import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

/// The hourly Nigraan TV news briefing (same briefing.mp3 + briefing.json
/// the website plays). The JSON shape is parsed defensively — if a field
/// is missing the player still works from the MP3 URL alone.
class BriefingInfo {
  final String title;
  final String generatedAt;
  final String audioUrl;
  final List<String> headlines;

  const BriefingInfo({
    required this.title,
    required this.generatedAt,
    required this.audioUrl,
    required this.headlines,
  });

  factory BriefingInfo.empty() => const BriefingInfo(
        title: 'Nigraan TV News Briefing',
        generatedAt: '',
        audioUrl: AppConfig.briefingMp3Url,
        headlines: [],
      );
}

class BriefingService {
  static Future<BriefingInfo> fetch() async {
    try {
      final res = await http
          .get(Uri.parse(AppConfig.briefingJsonUrl))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return BriefingInfo.empty();
      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) return BriefingInfo.empty();

      String strVal(String key) {
        final v = decoded[key];
        return v is String ? v : '';
      }

      final headlines = <String>[];
      final rawHeadlines = decoded['headlines'];
      if (rawHeadlines is List) {
        for (final h in rawHeadlines) {
          if (h is String && h.isNotEmpty) {
            headlines.add(h);
          } else if (h is Map && h['title'] is String) {
            headlines.add(h['title'] as String);
          }
        }
      }

      final audio = strVal('audio_url').isNotEmpty
          ? strVal('audio_url')
          : (strVal('audio').isNotEmpty
              ? strVal('audio')
              : AppConfig.briefingMp3Url);

      return BriefingInfo(
        title: strVal('title').isNotEmpty
            ? strVal('title')
            : 'Nigraan TV News Briefing',
        generatedAt: strVal('generated_at').isNotEmpty
            ? strVal('generated_at')
            : strVal('date'),
        audioUrl: audio.startsWith('http')
            ? audio
            : 'https://nigraantv.xyz/${audio.replaceFirst(RegExp(r'^/+'), '')}',
        headlines: headlines,
      );
    } catch (_) {
      return BriefingInfo.empty();
    }
  }
}
