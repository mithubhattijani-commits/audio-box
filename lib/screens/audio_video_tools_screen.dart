import 'package:flutter/material.dart';

import '../services/ads_service.dart';
import '../services/audio_library_service.dart';
import '../services/coins_service.dart';
import 'audio_trimmer_screen.dart';
import 'caption_generator_screen.dart';
import 'caption_translator_screen.dart';
import 'converter_screen.dart';
import 'tts_screen.dart';
import 'video_caption_maker_screen.dart';

/// Audio & Video Tools (v1.0.3 batch 2) — the 4-card screen from the
/// screenshot: dark theme, RTL layout, header "آواز و ویڈیو ٹولز",
/// section label "AUDIO & VIDEO", one dark card per tool (dark-red
/// icon square on the right, English title + Urdu subtitle).
///
/// Cards 1–2 link to the EXISTING TTS Studio and MP3 Converter
/// screens (no new code for those screens). Cards 3–4 open the new
/// caption tools. Exactly ONE Unity banner, zone 'tools' (same pattern
/// as the other tool screens).
class AudioVideoToolsScreen extends StatelessWidget {
  final CoinsService coins;
  final AudioLibraryService library;
  final ValueNotifier<Locale> appLocale;

  const AudioVideoToolsScreen({
    super.key,
    required this.coins,
    required this.library,
    required this.appLocale,
  });

  @override
  Widget build(BuildContext context) {
    final locale = appLocale.value;
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        foregroundColor: Colors.white,
        title: const Text('آواز و ویڈیو ٹولز'),
      ),
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'AUDIO & VIDEO',
                style: TextStyle(
                  color: Colors.grey,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              _ToolCard(
                icon: Icons.campaign,
                title: 'Text to Speech',
                subtitle: 'متن کو آواز میں بدلیں',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TtsScreen(
                      coins: coins,
                      library: library,
                      appLocale: appLocale,
                    ),
                  ),
                ),
              ),
              _ToolCard(
                icon: Icons.music_note,
                title: 'Audio Converter',
                subtitle: 'آڈیو کو WAV میں بدلیں',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ConverterScreen(library: library),
                  ),
                ),
              ),
              _ToolCard(
                icon: Icons.chat_bubble_outline,
                title: 'AI Caption Generator',
                subtitle: 'ویڈیو کے خودکار کیپشنز + 11 اسٹائل + فونٹس',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CaptionGeneratorScreen(coins: coins),
                  ),
                ),
              ),
              _ToolCard(
                icon: Icons.movie,
                title: 'Video Caption Maker (AI)',
                subtitle:
                    'خودکار کیپشن + 11 اسٹائل + فونٹس + SRT/ASS — ویڈیو پر پیش نظارہ',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => VideoCaptionMakerScreen(coins: coins),
                  ),
                ),
              ),
              // v1.0.8 — free tools: on-device caption translation and
              // audio trim/join (no server, no paid API, no coins).
              _ToolCard(
                icon: Icons.translate,
                title: 'Caption Translator',
                subtitle: 'اردو ↔ English کیپشنز کا ترجمہ — 25 کوائنز فی منٹ',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CaptionTranslatorScreen(coins: coins),
                  ),
                ),
              ),
              _ToolCard(
                icon: Icons.content_cut,
                title: 'Audio Trimmer & Joiner',
                subtitle: 'آڈیو کاٹیں اور جوڑیں — مفت، WAV + MP3',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AudioTrimmerScreen(
                      coins: coins,
                      library: library,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                locale.languageCode == 'ur'
                    ? 'کیپشنز پر فی منٹ 50 کوائنز لگتے ہیں۔'
                    : 'Captions cost 50 coins per minute of media.',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: const UnityBannerAdWidget(zone: 'tools'),
    );
  }
}

/// One dark tool card: dark-red rounded icon square on the right
/// (first in RTL), English title + Urdu subtitle on the left.
class _ToolCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ToolCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: const Color(0xFF7F1D1D),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_left,
                  color: Colors.grey,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
