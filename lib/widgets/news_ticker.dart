import 'dart:async';

import 'package:flutter/material.dart';

import '../services/remote_config_service.dart';
import '../services/rss_service.dart';

/// Live news ticker: a scrolling headline strip at the top of Home.
///
/// Source: the Nigraan TV RSS feed (https://nigraantv.xyz/rss.xml),
/// re-fetched every 5 minutes. Tapping a headline opens the FULL article
/// page on the website (with its banner ads) — reading earns no coins;
/// the ticker exists to send traffic to nigraantv.xyz.
class NewsTicker extends StatefulWidget {
  final void Function(RssArticle article) onTapArticle;

  const NewsTicker({super.key, required this.onTapArticle});

  @override
  State<NewsTicker> createState() => _NewsTickerState();
}

class _NewsTickerState extends State<NewsTicker> {
  final ScrollController _controller = ScrollController();
  List<RssArticle> _articles = [];
  Timer? _refreshTimer;
  bool _scrolling = false;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _load(),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final articles = await RssService.fetchLatest(limit: 10);
      if (!mounted) return;
      setState(() => _articles = articles);
      _startScrollLoop();
    } catch (_) {
      // Offline: keep the previous headlines (or the placeholder).
    }
  }

  void _startScrollLoop() {
    if (_scrolling || _articles.isEmpty) return;
    _scrolling = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollStep());
  }

  Future<void> _scrollStep() async {
    if (!mounted) return;
    if (!_controller.hasClients || _articles.isEmpty) {
      _scrolling = false;
      return;
    }
    final max = _controller.position.maxScrollExtent;
    if (max <= 0) {
      // Layout not ready yet — retry shortly.
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) _scrollStep();
      return;
    }
    // ~60 px/second: readable scrolling. Content is duplicated, so the
    // jump back lands on an identical frame (seamless loop).
    // DIRECTION (remote-controlled via audio-box.json ticker.direction):
    // 'from_left' (default, Nigraan Urdu-ticker house style) — text
    // enters from the LEFT edge and moves right: start at max offset,
    // animate to 0, jump back to max. 'from_right' is the old direction.
    final fromLeft =
        RemoteConfigService.instance.config.tickerDirection != 'from_right';
    if (fromLeft) {
      if (_controller.offset <= 0) _controller.jumpTo(max);
      final duration = Duration(
        milliseconds: (_controller.offset / 60 * 1000).round(),
      );
      await _controller.animateTo(
        0,
        duration: duration,
        curve: Curves.linear,
      );
      if (!mounted) return;
      _controller.jumpTo(max);
    } else {
      final duration = Duration(
        milliseconds: ((max - _controller.offset) / 60 * 1000).round(),
      );
      await _controller.animateTo(
        max,
        duration: duration,
        curve: Curves.linear,
      );
      if (!mounted) return;
      _controller.jumpTo(0);
    }
    _scrollStep();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.primary,
      height: 38,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            color: theme.colorScheme.secondary,
            height: 38,
            alignment: Alignment.center,
            child: const Text(
              'LIVE',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: _articles.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'Latest news from nigraantv.xyz',
                      style: TextStyle(color: Colors.white),
                    ),
                  )
                : SingleChildScrollView(
                    controller: _controller,
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    child: Row(
                      children: [
                        _headlineRow(_articles),
                        _headlineRow(_articles),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _headlineRow(List<RssArticle> articles) {
    return Row(
      children: articles.map((a) {
        return InkWell(
          onTap: () => widget.onTapArticle(a),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                const Text('●', style: TextStyle(color: Colors.white70, fontSize: 10)),
                const SizedBox(width: 6),
                Text(
                  a.title,
                  style: const TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}
