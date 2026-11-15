import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/audio_item.dart';
import '../models/tts_voice.dart';
import '../services/audio_library_service.dart';
import '../services/coins_service.dart';
import '../services/remote_config_service.dart';
import '../services/tts_service.dart';
import '../widgets/audio_player_bar.dart';

/// TTS Studio: type text, pick a voice, generate audio.
///
/// Cost: coinsPerMinute (remote config, default 50) per ~1-minute chunk.
/// Repeat generations of the same text + voice are free (on-device cache).
/// Daily cap (remote config tts.daily_cap, default 10/day) is enforced.
/// If Gemini fails (quota/429), the generation automatically falls back
/// to the same-gender free Edge voice.
class TtsScreen extends StatefulWidget {
  final CoinsService coins;
  final AudioLibraryService library;
  final ValueNotifier<Locale> appLocale;
  final String initialText;
  final String initialLang;

  const TtsScreen({
    super.key,
    required this.coins,
    required this.library,
    required this.appLocale,
    this.initialText = '',
    this.initialLang = 'ur',
  });

  @override
  State<TtsScreen> createState() => _TtsScreenState();
}

class _TtsScreenState extends State<TtsScreen> {
  final TextEditingController _textController = TextEditingController();
  final TtsService _tts = TtsService();
  TtsVoice _voice = TtsVoice.byId('aoede');
  String _lang = 'ur';
  bool _busy = false;
  String? _note;
  List<AudioItem> _results = [];

  @override
  void initState() {
    super.initState();
    _textController.text = widget.initialText;
    _lang = widget.initialLang;
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  List<TtsVoice> get _voices {
    final available = TtsService.availableVoices();
    return available.isEmpty ? TtsVoice.all : available;
  }

  /// Effective voice: the selected one when still offered, else the
  /// first offered voice (config can change while the app runs).
  TtsVoice get _effectiveVoice {
    final voices = _voices;
    return voices.contains(_voice) ? _voice : voices.first;
  }

  Future<void> _generate() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _busy) return;
    final locale = widget.appLocale.value;
    final voice = _effectiveVoice;

    if (!widget.coins.canGenerate) {
      setState(() => _note = AppStrings.tr('daily_cap_reached', locale));
      return;
    }
    await widget.library.load();
    final chunks = TtsService.chunkText(text, voice);
    if (chunks.isEmpty) return;

    // Cached chunks are free: only uncached chunks cost coins.
    var uncached = 0;
    for (final chunk in chunks) {
      final cached = await TtsService.cacheFile(
        chunk,
        voice,
        _lang,
        voice.engine == TtsEngine.gemini ? 'wav' : 'mp3',
      );
      final inLibrary = widget.library.items.any(
        (i) => i.text == chunk && i.voiceId == voice.id,
      );
      if (!await cached.exists() && !inLibrary) uncached++;
    }
    final cost = uncached * widget.coins.coinsPerMinute;
    if (cost > 0 && !widget.coins.canAfford(cost)) {
      setState(() => _note = AppStrings.tr('not_enough_coins', locale));
      return;
    }

    setState(() {
      _busy = true;
      _note = null;
      _results = [];
    });
    var fellBack = false;
    final generated = <AudioItem>[];
    var spent = false;
    try {
      if (cost > 0) {
        final ok = await widget.coins.spend(cost);
        if (!ok) {
          setState(() => _note = AppStrings.tr('not_enough_coins', locale));
          return;
        }
        spent = true;
      }
      for (var i = 0; i < chunks.length; i++) {
        final chunk = chunks[i];
        final ext = voice.engine == TtsEngine.gemini ? 'wav' : 'mp3';
        final cacheFile =
            await TtsService.cacheFile(chunk, voice, _lang, ext);
        AudioItem item;
        final existing = widget.library.items
            .where((e) => e.text == chunk && e.voiceId == voice.id)
            .toList();
        if (existing.isNotEmpty) {
          item = existing.first;
        } else if (await cacheFile.exists()) {
          item = await widget.library.save(
            title: _titleFor(text),
            text: chunk,
            voice: voice,
            bytes: await cacheFile.readAsBytes(),
            ext: ext,
            chunkIndex: i + 1,
            chunkCount: chunks.length,
          );
        } else {
          final gen = await _tts.generateChunkWithFallback(
            chunk,
            voice,
            lang: _lang,
          );
          if (gen.fellBackToEdge) fellBack = true;
          await cacheFile.writeAsBytes(gen.bytes);
          item = await widget.library.save(
            title: _titleFor(text),
            text: chunk,
            voice: voice,
            bytes: gen.bytes,
            ext: gen.ext,
            chunkIndex: i + 1,
            chunkCount: chunks.length,
          );
        }
        generated.add(item);
        await widget.coins.recordGeneration();
      }
      if (mounted) {
        setState(() {
          _results = generated;
          _note = fellBack
              ? AppStrings.tr('fallback_used', locale)
              : null;
        });
      }
    } catch (e) {
      // Refund the spend when nothing was generated.
      if (spent && generated.isEmpty && cost > 0) {
        await widget.coins.add(cost, reason: 'generation_failed_refund');
      }
      if (mounted) {
        setState(() => _note = 'Generation failed: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _titleFor(String text) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= 40 ? t : '${t.substring(0, 40)}…';
  }

  @override
  Widget build(BuildContext context) {
    final locale = widget.appLocale.value;
    final voices = _voices;
    return Scaffold(
      appBar: AppBar(title: Text(AppStrings.tr('tts_studio', locale))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder<int>(
                    valueListenable: widget.coins.balance,
                    builder: (context, balance, _) {
                      return Text(
                        '${AppStrings.tr('balance', locale)}: $balance coins',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      );
                    },
                  ),
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'ur', label: Text('اردو')),
                    ButtonSegment(value: 'en', label: Text('EN')),
                  ],
                  selected: {_lang},
                  onSelectionChanged: (s) => setState(() => _lang = s.first),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _textController,
              maxLines: 8,
              minLines: 5,
              decoration: InputDecoration(
                hintText: AppStrings.tr('type_text', locale),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<TtsVoice>(
              initialValue: voices.contains(_voice) ? _voice : voices.first,
              decoration: InputDecoration(
                labelText: AppStrings.tr('voice', locale),
              ),
              items: voices.map((v) {
                return DropdownMenuItem(
                  value: v,
                  child: Text(
                    '${v.label} (${v.gender})'
                    '${v.isPremium ? ' • Gemini' : ' • Edge (free)'}',
                  ),
                );
              }).toList(),
              onChanged: (v) {
                if (v != null) setState(() => _voice = v);
              },
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<RemoteConfig>(
              valueListenable: RemoteConfigService.instance.notifier,
              builder: (context, cfg, _) {
                return Text(
                  '${widget.coins.coinsPerMinute} coins per ~1 min • '
                  'Daily: ${widget.coins.generationsUsedToday}'
                  '/${cfg.tts.dailyCap == 0 ? '∞' : cfg.tts.dailyCap}',
                  style: const TextStyle(color: Colors.grey),
                );
              },
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _busy ? null : _generate,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.graphic_eq),
              label: Text(
                _busy
                    ? AppStrings.tr('generating', locale)
                    : AppStrings.tr('generate_audio', locale),
              ),
            ),
            if (_note != null) ...[
              const SizedBox(height: 12),
              Text(_note!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 16),
            for (final item in _results)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: AudioPlayerBar(
                    file: File(item.filePath),
                    title: item.displayTitle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
