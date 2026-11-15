import 'dart:async';

import 'package:flutter/material.dart';

import '../services/remote_config_service.dart';

/// Remote-controlled ribbon bar. NOTE (15 Nov 2026): the widget is NOT
/// currently placed on Home — the news ticker strip IS the blue ribbon
/// now (red LIVE chip + news scrolling on the blue ribbon, see
/// NewsTicker). This file stays because NewsTicker reuses its
/// parseColor for the strip background, and the scrolling ribbon widget
/// below is kept for a future promo strip.
/// Values come from audio-box.json `ribbon`: enabled / color / text /
/// height. No new colors are compiled in beyond the #3D5AFE fallback
/// for an invalid hex string.
///
/// The text SCROLLS (marquee) like the news ticker: same direction
/// (remote ticker.direction, 'from_left' default — Nigraan house
/// style) and the same ~60 px/second speed. Empty text = solid
/// colored bar; non-empty text = scrolling white text.
///
/// Listens to the remote-config notifier, so a website change applies
/// within seconds while the app is online — no rebuild. A text change
/// restarts the scroll loop (the scroller is keyed by the text).
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
        if (text.isEmpty) {
          return Container(
            width: double.infinity,
            height: ribbon.height,
            color: parseColor(ribbon.color),
          );
        }
        return _ScrollingRibbon(
          key: ValueKey(text),
          text: text,
          color: parseColor(ribbon.color),
          height: ribbon.height,
        );
      },
    );
  }
}

class _ScrollingRibbon extends StatefulWidget {
  final String text;
  final Color color;
  final double height;

  const _ScrollingRibbon({
    super.key,
    required this.text,
    required this.color,
    required this.height,
  });

  @override
  State<_ScrollingRibbon> createState() => _ScrollingRibbonState();
}

class _ScrollingRibbonState extends State<_ScrollingRibbon> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollStep());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _scrollStep() async {
    if (!mounted) return;
    if (!_controller.hasClients) {
      // Layout not ready yet — retry shortly.
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) _scrollStep();
      return;
    }
    final max = _controller.position.maxScrollExtent;
    if (max <= 0) {
      // Content not wider than the screen yet — retry shortly.
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) _scrollStep();
      return;
    }
    // ~60 px/second: readable scrolling. Content is duplicated, so the
    // jump back lands on an identical frame (seamless loop).
    // DIRECTION (same remote switch as the news ticker):
    // 'from_left' (default) — text enters from the LEFT edge and moves
    // right: start at max offset, animate to 0, jump back to max.
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
    return Container(
      width: double.infinity,
      height: widget.height,
      color: widget.color,
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Row(
          children: [
            _textHalf(),
            _textHalf(),
          ],
        ),
      ),
    );
  }

  /// One half of the loop: the text repeated 4 times with bullet
  /// separators. The two halves are identical, so the jump back to the
  /// start of the loop lands on an identical frame.
  Widget _textHalf() {
    return Row(
      children: List.generate(
        4,
        (_) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              const Text(
                '•',
                style: TextStyle(color: Colors.white70, fontSize: 10),
              ),
              const SizedBox(width: 6),
              Text(
                widget.text,
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
