import 'package:flutter/material.dart';

import '../services/caption_service.dart';
import '../services/caption_styles.dart';

/// Renders one caption line in a [CaptionStyle], with the spoken word
/// highlighted at [positionSeconds] (real Whisper word timings when
/// [words] is given, even-split timing otherwise — see
/// CaptionService.activeWordIndexOf).
///
/// Used by the Video Caption Maker live preview (real playback
/// position), the AI Caption Generator preview card and the style
/// picker cards (fake advancing position). Urdu text renders RTL;
/// [fontFamily] picks the typeface (Jameel Noori Nastaleeq Kasheeda
/// is bundled for Urdu, display fonts for English) — null falls back
/// to the phone's system font. Emoji in the text render as-is.
/// [outline]/[shadow]/[background] override the style's FX toggles
/// when given (the FX row in the editor).
class StyledCaptionText extends StatelessWidget {
  final String text;

  /// Line start/end in seconds.
  final double start;
  final double end;

  /// Playback position in seconds (drives the active word).
  final double positionSeconds;

  final CaptionStyle style;
  final CaptionSize size;
  final int highlightColor;
  final String lang;

  /// Flutter font family from [CaptionFont.family]; null = system font.
  final String? fontFamily;

  /// Real Whisper word timings for this line (empty/absent =
  /// even-split fallback). The word list must match [text].
  final List<CaptionWord>? words;

  /// FX overrides (null = use the style's own value).
  final bool? outline;
  final bool? shadow;
  final bool? background;

  const StyledCaptionText({
    super.key,
    required this.text,
    required this.start,
    required this.end,
    required this.positionSeconds,
    required this.style,
    required this.size,
    required this.highlightColor,
    required this.lang,
    this.fontFamily,
    this.words,
    this.outline,
    this.shadow,
    this.background,
  });

  double get _fontSize =>
      style.fontSizePx * CaptionStyles.sizeScale(size);

  bool get _useOutline => outline ?? style.outline;
  bool get _useShadow => shadow ?? style.shadow;
  bool get _useBackground =>
      background ?? (style.backgroundColor != 0);

  int _activeIndex() {
    final w = words;
    if (w != null && w.isNotEmpty) {
      return CaptionService.activeWordIndexOf(
        CaptionSegment(
          start: start,
          end: end,
          text: text,
          words: w,
        ),
        positionSeconds,
      );
    }
    return CaptionStyles.activeWordIndex(
      start: start,
      end: end,
      text: text,
      positionSeconds: positionSeconds,
    );
  }

  TextStyle _wordStyle({required bool active}) {
    final base = TextStyle(
      fontFamily: fontFamily,
      fontSize: _fontSize * (active ? style.highlightScale : 1.0),
      fontWeight: style.bold ? FontWeight.w800 : FontWeight.w400,
      color: Color(active ? highlightColor : style.textColor),
    );
    final shadows = <Shadow>[];
    if (_useOutline) {
      // Fake outline: dark stroke painted behind the fill via shadows.
      shadows.addAll([
        for (final dx in [-1.0, 0.0, 1.0])
          for (final dy in [-1.0, 0.0, 1.0])
            if (dx != 0 || dy != 0)
              Shadow(
                color: Colors.black,
                offset: Offset(dx * 1.5, dy * 1.5),
                blurRadius: 0,
              ),
      ]);
    }
    if (_useShadow) {
      shadows.add(
        const Shadow(
          color: Colors.black54,
          offset: Offset(2, 2),
          blurRadius: 4,
        ),
      );
    }
    if (shadows.isEmpty) return base;
    return base.copyWith(shadows: shadows);
  }

  Widget _wordSpan(String word, bool active) {
    final display = style.uppercase ? word.toUpperCase() : word;
    if (active && style.highlightBg != 0) {
      // Highlight Box style: coloured box behind the spoken word,
      // black text on it. The box colour follows the highlight pick.
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: Color(highlightColor),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          display,
          style: _wordStyle(active: false).copyWith(color: Colors.black),
        ),
      );
    }
    return Text(display, style: _wordStyle(active: active));
  }

  @override
  Widget build(BuildContext context) {
    final words = CaptionStyles.wordsOf(text);
    if (words.isEmpty) return const SizedBox.shrink();
    final active = _activeIndex();

    late final Widget content;
    switch (style.animation) {
      case CaptionAnimation.karaoke:
        content = Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 2,
          children: [
            for (var i = 0; i < words.length; i++)
              _wordSpan(words[i], i == active),
          ],
        );
      case CaptionAnimation.pop:
        // One word at a time, with a pop scale on change.
        final shown = active >= 0 ? words[active] : words.first;
        content = AnimatedSwitcher(
          duration: const Duration(milliseconds: 140),
          transitionBuilder: (child, anim) => ScaleTransition(
            scale: Tween<double>(begin: 0.7, end: 1.0).animate(anim),
            child: child,
          ),
          child: Text(
            style.uppercase ? shown.toUpperCase() : shown,
            key: ValueKey('${active}_$shown'),
            style: _wordStyle(active: true),
            textAlign: TextAlign.center,
          ),
        );
      case CaptionAnimation.typewriter:
        final shownCount = active < 0 ? 0 : active + 1;
        content = Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 2,
          children: [
            for (var i = 0; i < shownCount; i++)
              _wordSpan(words[i], i == active),
          ],
        );
      case CaptionAnimation.flash:
        content = Text(
          style.uppercase ? text.toUpperCase() : text,
          textAlign: TextAlign.center,
          style: _wordStyle(active: false),
        );
    }

    final inner = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: content,
    );
    // Background ON (FX toggle) forces a dark box behind the line
    // even when the style itself has no background colour.
    final bgColor = style.backgroundColor != 0
        ? Color(style.backgroundColor)
        : Colors.black54;
    final boxed = _useBackground
        ? Container(
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: inner,
          )
        : inner;

    return Directionality(
      textDirection: lang == 'ur' ? TextDirection.rtl : TextDirection.ltr,
      child: boxed,
    );
  }
}
