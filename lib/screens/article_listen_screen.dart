import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/tts_voice.dart';
import '../services/audio_library_service.dart';
import '../services/coins_service.dart';
import '../services/rss_service.dart';
import '../services/tts_service.dart';
import '../widgets/audio_player_bar.dart';
import 'article_webview_screen.dart';

/// Article Listen: latest Nigraan TV articles from the RSS feed.
/// - READ (opens the full article on nigraantv.xyz): FREE, no coins.
/// - LISTEN (read aloud via TTS): normal coin cost, like TTS Studio
///   (coinsPerMinute per chunk; repeat listens are free from cache).
class ArticleListenScreen extends StatefulWidget {
  final CoinsService coins;
  final AudioLibraryService library;
  final ValueNotifier<Locale> appLocale;
  final RssArticle? initialArticle;

  const ArticleListenScreen({
    super.key,
    required this.coins,
    required this.library,
    required this.appLocale,
    this.initialArticle,
  });

  @override
  State<ArticleListenScreen> createState() => _ArticleListenScreenState();
}

class _ArticleListenScreenState extends State<ArticleListenScreen> {
  final TtsService _tts = TtsService();
  List<RssArticle> _articles = [];
  bool _loading = true;
  String? _error;
  TtsVoice _voice = TtsVoice.byId('aoede');
  String? _playingTitle;
  File? _playingFile;
  bool _busy = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final articles = await RssService.fetchLatest(limit: 30);
      if (!mounted) return;
      // A tapped article from Home jumps to the top of the list.
      final initial = widget.initialArticle;
      if (initial != null) {
        articles.removeWhere((a) => a.link == initial.link);
        articles.insert(0, initial);
      }
      setState(() {
        _articles = articles;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _listen(RssArticle article) async {
    if (_busy) return;
    final locale = widget.appLocale.value;
    await widget.library.load();
    final text = article.listenText;
    final chunks = TtsService.chunkText(text, _voice);
    if (chunks.isEmpty) return;

    var uncached = 0;
    for (final chunk in chunks) {
      final cached = await TtsService.cacheFile(
        chunk,
        _voice,
        'ur',
        _voice.engine == TtsEngine.gemini ? 'wav' : 'mp3',
      );
      final inLibrary = widget.library.items.any(
        (i) => i.text == chunk && i.voiceId == _voice.id,
      );
      if (!await cached.exists() && !inLibrary) uncached++;
    }
    final cost = uncached * widget.coins.coinsPerMinute;
    if (cost > 0 && !widget.coins.canAfford(cost)) {
      setState(() => _note = AppStrings.tr('not_enough_coins', locale));
      return;
    }
    if (!widget.coins.canGenerate) {
      setState(() => _note = AppStrings.tr('daily_cap_reached', locale));
      return;
    }

    setState(() {
      _busy = true;
      _note = null;
    });
    var spent = false;
    try {
      if (cost > 0) {
        spent = await widget.coins.spend(cost, reason: 'article_listen');
        if (!spent) {
          setState(() => _note = AppStrings.tr('not_enough_coins', locale));
          return;
        }
      }
      File? firstFile;
      for (var i = 0; i < chunks.length; i++) {
        final chunk = chunks[i];
        final ext = _voice.engine == TtsEngine.gemini ? 'wav' : 'mp3';
        final cacheFile =
            await TtsService.cacheFile(chunk, _voice, 'ur', ext);
        File file;
        final existing = widget.library.items
            .where((e) => e.text == chunk && e.voiceId == _voice.id)
            .toList();
        if (existing.isNotEmpty) {
          file = File(existing.first.filePath);
        } else if (await cacheFile.exists()) {
          final saved = await widget.library.save(
            title: article.title,
            text: chunk,
            voice: _voice,
            bytes: await cacheFile.readAsBytes(),
            ext: ext,
            chunkIndex: i + 1,
            chunkCount: chunks.length,
          );
          file = File(saved.filePath);
        } else {
          final gen = await _tts.generateChunkWithFallback(
            chunk,
            _voice,
            lang: 'ur',
          );
          await cacheFile.writeAsBytes(gen.bytes);
          final saved = await widget.library.save(
            title: article.title,
            text: chunk,
            voice: _voice,
            bytes: gen.bytes,
            ext: gen.ext,
            chunkIndex: i + 1,
            chunkCount: chunks.length,
          );
          file = File(saved.filePath);
        }
        firstFile ??= file;
        await widget.coins.recordGeneration();
      }
      if (mounted) {
        setState(() {
          _playingTitle = article.title;
          _playingFile = firstFile;
        });
      }
    } catch (e) {
      if (spent) {
        await widget.coins.add(cost, reason: 'article_listen_refund');
      }
      if (mounted) setState(() => _note = 'Listen failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openArticle(RssArticle article) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArticleWebViewScreen(article: article),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locale = widget.appLocale.value;
    return Scaffold(
      appBar: AppBar(title: Text(AppStrings.tr('article_listen', locale))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Could not load articles: $_error'))
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<TtsVoice>(
                                  value: _voice,
                                  decoration: InputDecoration(
                                    labelText:
                                        AppStrings.tr('voice', locale),
                                  ),
                                  items: TtsService.availableVoices()
                                      .map((v) {
                                    return DropdownMenuItem(
                                      value: v,
                                      child: Text(
                                        '${v.label} (${v.gender})',
                                      ),
                                    );
                                  }).toList(),
                                  onChanged: (v) {
                                    if (v != null) {
                                      setState(() => _voice = v);
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            AppStrings.tr('listen_free_note', locale),
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 12,
                            ),
                          ),
                          if (_note != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                _note!,
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          if (_playingFile != null && _playingTitle != null)
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: AudioPlayerBar(
                                  file: _playingFile,
                                  title: _playingTitle!,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _articles.length,
                        itemBuilder: (context, i) {
                          final a = _articles[i];
                          return ListTile(
                            title: Text(
                              a.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${a.dek}${a.relativeTime.isNotEmpty ? ' • ${a.relativeTime}' : ''}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.headphones),
                                  tooltip: 'Listen',
                                  onPressed:
                                      _busy ? null : () => _listen(a),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.open_in_new),
                                  tooltip: 'Read',
                                  onPressed: () => _openArticle(a),
                                ),
                              ],
                            ),
                            onTap: () => _openArticle(a),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
