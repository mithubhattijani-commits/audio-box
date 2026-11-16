import 'dart:async';

import 'package:flutter/material.dart';

import '../services/caption_styles.dart';
import 'styled_caption_text.dart';

/// Style picker for the caption tools (v1.0.6): a horizontal row of
/// style cards, each with a LIVE animated preview (the sample line
/// plays through its words so the user sees the karaoke / pop /
/// typewriter motion before picking), plus the controls underneath:
/// position (Top / Middle / Bottom), size (S / M / L) and highlight
/// colour dots.
class CaptionStylePicker extends StatelessWidget {
  final CaptionStyle selected;
  final ValueChanged<CaptionStyle> onStyleSelected;
  final String lang;

  const CaptionStylePicker({
    super.key,
    required this.selected,
    required this.onStyleSelected,
    required this.lang,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          lang == 'ur' ? 'کیپشن اسٹائل' : 'Caption style',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 118,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: CaptionStyles.all.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final style = CaptionStyles.all[i];
              final isSelected = style.id == selected.id;
              return _StyleCard(
                style: style,
                lang: lang,
                isSelected: isSelected,
                onTap: () => onStyleSelected(style),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Position / size / highlight-colour / font controls, shown under
/// the picker.
class CaptionStyleControls extends StatelessWidget {
  final CaptionPosition position;
  final ValueChanged<CaptionPosition> onPositionChanged;
  final CaptionSize size;
  final ValueChanged<CaptionSize> onSizeChanged;
  final int highlightColor;
  final ValueChanged<int> onHighlightChanged;
  final String lang;
  final CaptionFont font;
  final ValueChanged<CaptionFont> onFontChanged;

  const CaptionStyleControls({
    super.key,
    required this.position,
    required this.onPositionChanged,
    required this.size,
    required this.onSizeChanged,
    required this.highlightColor,
    required this.onHighlightChanged,
    required this.lang,
    required this.font,
    required this.onFontChanged,
  });

  @override
  Widget build(BuildContext context) {
    final fonts = CaptionFonts.forLang(lang);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Font row: each chip's label is rendered IN that font.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(lang == 'ur' ? 'فونٹ' : 'Font'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final f in fonts)
                    GestureDetector(
                      onTap: () => onFontChanged(f),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: font.id == f.id
                              ? Colors.white24
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: font.id == f.id
                                ? Colors.white
                                : Colors.white30,
                            width: font.id == f.id ? 2 : 1,
                          ),
                        ),
                        child: Text(
                          lang == 'ur' ? f.nameUr : f.nameEn,
                          style: TextStyle(
                            fontFamily: f.family,
                            fontSize: 14,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(lang == 'ur' ? 'جگہ' : 'Position'),
            const SizedBox(width: 8),
            Expanded(
              child: SegmentedButton<CaptionPosition>(
                segments: [
                  ButtonSegment(
                    value: CaptionPosition.top,
                    label: Text(lang == 'ur' ? 'اوپر' : 'Top'),
                  ),
                  ButtonSegment(
                    value: CaptionPosition.middle,
                    label: Text(lang == 'ur' ? 'درمیان' : 'Middle'),
                  ),
                  ButtonSegment(
                    value: CaptionPosition.bottom,
                    label: Text(lang == 'ur' ? 'نیچے' : 'Bottom'),
                  ),
                ],
                selected: {position},
                onSelectionChanged: (s) => onPositionChanged(s.first),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(lang == 'ur' ? 'سائز' : 'Size'),
            const SizedBox(width: 8),
            Expanded(
              child: SegmentedButton<CaptionSize>(
                segments: const [
                  ButtonSegment(value: CaptionSize.small, label: Text('S')),
                  ButtonSegment(value: CaptionSize.medium, label: Text('M')),
                  ButtonSegment(value: CaptionSize.large, label: Text('L')),
                ],
                selected: {size},
                onSelectionChanged: (s) => onSizeChanged(s.first),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(lang == 'ur' ? 'رنگ' : 'Highlight'),
            const SizedBox(width: 12),
            for (final c in CaptionStyles.highlightChoices)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: GestureDetector(
                  onTap: () => onHighlightChanged(c),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: highlightColor == c
                            ? Colors.white
                            : Colors.white30,
                        width: highlightColor == c ? 3 : 1,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _StyleCard extends StatefulWidget {
  final CaptionStyle style;
  final String lang;
  final bool isSelected;
  final VoidCallback onTap;

  const _StyleCard({
    required this.style,
    required this.lang,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_StyleCard> createState() => _StyleCardState();
}

class _StyleCardState extends State<_StyleCard> {
  Timer? _timer;
  double _pos = 0;

  // Sample line + fake 3-second loop so the motion is visible.
  static const _sampleEn = 'This is how your captions will look';
  static const _sampleUr = 'یہ آپ کے کیپشنز ہیں';

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!mounted) return;
      setState(() {
        _pos += 0.15;
        if (_pos >= 3.0) _pos = 0;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final sample = widget.lang == 'ur' ? _sampleUr : _sampleEn;
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        width: 168,
        decoration: BoxDecoration(
          border: Border.all(
            color: widget.isSelected
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.shade300,
            width: widget.isSelected ? 2.5 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(11),
                  ),
                ),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: StyledCaptionText(
                  text: sample,
                  start: 0,
                  end: 3,
                  positionSeconds: _pos,
                  style: style,
                  size: CaptionSize.small,
                  highlightColor: style.highlightColor,
                  lang: widget.lang,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                widget.lang == 'ur' ? style.nameUr : style.nameEn,
                style: TextStyle(
                  fontWeight: widget.isSelected
                      ? FontWeight.bold
                      : FontWeight.normal,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
