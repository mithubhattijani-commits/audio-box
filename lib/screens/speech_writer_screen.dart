import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/ads_service.dart';
import '../services/audio_library_service.dart';
import '../services/coins_service.dart';
import 'tts_screen.dart';

/// Speech Writer: topic in -> easy Urdu speech text (v1 uses local
/// templates; AI-written speeches are a follow-up). The text can be sent
/// to TTS Studio, where generation costs the normal coins.
class SpeechWriterScreen extends StatefulWidget {
  final CoinsService coins;
  final AudioLibraryService library;
  final ValueNotifier<Locale> appLocale;

  const SpeechWriterScreen({
    super.key,
    required this.coins,
    required this.library,
    required this.appLocale,
  });

  @override
  State<SpeechWriterScreen> createState() => _SpeechWriterScreenState();
}

class _SpeechWriterScreenState extends State<SpeechWriterScreen> {
  final TextEditingController _topicController = TextEditingController();
  final TextEditingController _speechController = TextEditingController();
  String _occasion = 'general';
  String _length = 'medium';

  static const Map<String, String> _occasions = {
    'general': 'General',
    'school': 'School',
    'community': 'Community',
    'eid': 'Eid',
    'independence': 'Independence Day',
  };

  void _write() {
    final topic = _topicController.text.trim();
    if (topic.isEmpty) return;
    final occasion = _occasions[_occasion] ?? 'General';
    final long = _length == 'long';
    final points = long
        ? [
            'پہلی بات یہ ہے کہ $topic ہماری زندگی میں بہت اہمیت رکھتا ہے۔',
            'دوسری بات یہ ہے کہ $topic پر عمل کرنے سے ہمارا معاشرہ بہتر ہوتا ہے۔',
            'تیسری بات یہ ہے کہ $topic کے بارے میں ہمیں نوجوانوں کو آگاہ کرنا چاہیے۔',
          ]
        : [
            'پہلی بات یہ ہے کہ $topic ہماری زندگی میں بہت اہمیت رکھتا ہے۔',
            'دوسری بات یہ ہے کہ $topic پر عمل کرنے سے ہمارا معاشرہ بہتر ہوتا ہے۔',
          ];
    final speech = [
      'السلام علیکم! محترم سامعین، آج میں آپ کے سامنے "$topic" ($occasion) کے موضوع پر چند باتیں پیش کروں گا۔',
      ...points,
      'آخر میں میں یہی کہوں گا کہ $topic پر غور کرنا اور اس پر عمل کرنا ہم سب کی ذمہ داری ہے۔ شکریہ!',
    ].join('\n\n');
    setState(() => _speechController.text = speech);
  }

  void _sendToTts() {
    final text = _speechController.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TtsScreen(
          coins: widget.coins,
          library: widget.library,
          appLocale: widget.appLocale,
          initialText: text,
          initialLang: 'ur',
        ),
      ),
    );
  }

  @override
  void dispose() {
    _topicController.dispose();
    _speechController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locale = widget.appLocale.value;
    return Scaffold(
      appBar: AppBar(title: Text(AppStrings.tr('speech_writer', locale))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _topicController,
              decoration: InputDecoration(
                labelText: AppStrings.tr('speech_topic', locale),
                hintText: 'مثال: تعلیم کی اہمیت',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _occasion,
                    decoration: const InputDecoration(labelText: 'Occasion'),
                    items: _occasions.entries.map((e) {
                      return DropdownMenuItem(
                        value: e.key,
                        child: Text(e.value),
                      );
                    }).toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _occasion = v);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _length,
                    decoration: const InputDecoration(labelText: 'Length'),
                    items: const [
                      DropdownMenuItem(value: 'medium', child: Text('Medium')),
                      DropdownMenuItem(value: 'long', child: Text('Long')),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _length = v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _write,
              icon: const Icon(Icons.edit_note),
              label: Text(AppStrings.tr('write_speech', locale)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _speechController,
              maxLines: 12,
              minLines: 6,
              decoration: const InputDecoration(
                hintText: 'Your speech will appear here…',
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _sendToTts,
              icon: const Icon(Icons.mic),
              label: Text(AppStrings.tr('send_to_tts', locale)),
            ),
            const SizedBox(height: 8),
            const Text(
              'v1 writes speeches from local templates. AI-written speeches are a follow-up.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const UnityBannerAdWidget(zone: 'speech_writer'),
    );
  }
}
