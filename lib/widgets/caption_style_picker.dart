import 'dart:async';

import 'package:flutter/material.dart';

import '../services/caption_styles.dart';
import 'styled_caption_text.dart';

/// Style picker for the caption tools (v1.0.6, presets + FX + dark
/// editor look in v1.0.10): a horizontal row of style cards, each
/// with a LIVE animated preview (the sample line plays through its
/// words so the user sees the karaoke / pop / typewriter motion
/// before picking), plus the controls underneath: position (Top /
/// Middle / Bottom), size (S / M / L) and highlight colour dots.
/// [dark] renders the panel in the Caption Studio dark editor look
/// (mockup v3): white labels, red selected border.
class CaptionStylePicker extends StatelessWidget {
  final CaptionStyle selected;
  final ValueChanged<CaptionStyle> onStyleSelected;
  final String lang;
  final bool dark;

  const CaptionStylePicker({
    super.key,
    required this.selected,
    required this.onStyleSelected,
    required this.lang,
    this.dark = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          lang == 'ur' ? 'کیپشن اسٹائل' : 'Caption style',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: dark ? Colors.white : null,
              ),
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
                dark: dark,
                onTap: () => onStyleSelected(style),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One-tap preset row (v1.0.10): Nigraan News / TikTok Bold / Clean.
/// Tapping a preset applies its whole look (style + position + size
/// + font + highlight + FX) via [onPresetSelected].
class CaptionPresetPicker extends StatelessWidget {
  final String selectedPresetId;
  final ValueChanged<CaptionPreset> onPresetSelected;
  final String lang;
  final bool dark;

  const CaptionPresetPicker({
    super.key,
    required this.selectedPresetId,
    required this.onPresetSelected,
    required this.lang,
    this.dark = false,
  });

  @override
  Widget build(BuildContext context) {
    final labelColor = dark ? Colors.white70 : Colors.black87;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          lang == 'ur' ? 'پری سیٹ' : 'Presets',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: dark ? Colors.white : null,
              ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in CaptionPresets.all)
              ChoiceChip(
                label: Text(
                  lang == 'ur' ? preset.nameUr : preset.nameEn,
                  style: TextStyle(
                    color: selectedPresetId == preset.id
                        ? Colors.white
                        : labelColor,
                    fontWeight: selectedPresetId == preset.id
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                selected: selectedPresetId == preset.id,
                selectedColor: Colors.red,
                backgroundColor:
                    dark ? Colors.white12 : Colors.grey.shade200,
                side: BorderSide(
                  color: selectedPresetId == preset.id
                      ? Colors.red
                      : (dark ? Colors.white24 : Colors.grey.shade300),
                ),
                onSelected: (_) => onPresetSelected(preset),
              ),
          ],
        ),
      ],
    );
  }
}

/// Position / size / highlight-colour / font controls, shown under
/// the picker. v1.0.10 adds the FX row (Outline / Shadow /
/// Background toggles) and the dual-language toggle; all three are
/// optional so older callers keep working. [dark] renders the panel
/// in the Caption Studio dark editor look (white labels).
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
  final bool dark;

  /// FX toggles (v1.0.10). Null callback = that toggle is hidden.
  final bool outline;
  final ValueChanged<bool>? onOutlineChanged;
  final bool shadow;
  final ValueChanged<bool>? onShadowChanged;
  final bool background;
  final ValueChanged<bool>? onBackgroundChanged;

  /// Dual-language captions (Urdu + English, two lines).
  final bool dualLanguage;
  final ValueChanged<bool>? onDualChanged;

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
    this.dark = false,
    this.outline = true,
    this.onOutlineChanged,
    this.shadow = false,
    this.onShadowChanged,
    this.background = false,
    this.onBackgroundChanged,
    this.dualLanguage = false,
    this.onDualChanged,
  });

  Color get _labelColor => dark ? Colors.white : Colors.black87;

  Widget _fxChip(
    String label,
    bool on,
    ValueChanged<bool>? onChanged,
  ) {
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged(!on),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: on
              ? Colors.red
              : (dark ? Colors.white12 : Colors.grey.shade200),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: on
                ? Colors.red
                : (dark ? Colors.white24 : Colors.grey.shade300),
          ),
        ),
        child: Text(
          '$label ${on ? 'ON' : 'OFF'}',
          style: TextStyle(
            color: on ? Colors.white : _labelColor,
            fontWeight: on ? FontWeight.bold : FontWeight.normal,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fonts = CaptionFonts.forLang(lang);
    final chipBorder = dark ? Colors.white30 : Colors.grey.shade400;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Font row: each chip's label is rendered IN that font.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                lang == 'ur' ? 'فونٹ' : 'Font',
                style: TextStyle(color: _labelColor),
              ),
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
                              ? (dark ? Colors.white24 : Colors.black12)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: font.id == f.id
                                ? (dark ? Colors.white : Colors.black87)
                                : chipBorder,
                            width: font.id == f.id ? 2 : 1,
                          ),
                        ),
                        child: Text(
                          lang == 'ur' ? f.nameUr : f.nameEn,
                          style: TextStyle(
                            fontFamily: f.family,
                            fontSize: 14,
                            color: _labelColor,
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
            Text(
              lang == 'ur' ? 'جگہ' : 'Position',
              style: TextStyle(color: _labelColor),
            ),
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
            Text(
              lang == 'ur' ? 'سائز' : 'Size',
              style: TextStyle(color: _labelColor),
            ),
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
            Text(
              lang == 'ur' ? 'رنگ' : 'Highlight',
              style: TextStyle(color: _labelColor),
            ),
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
                            ? (dark ? Colors.white : Colors.black87)
                            : Colors.white30,
                        width: highlightColor == c ? 3 : 1,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        // FX row (v1.0.10): outline / shadow / background toggles.
        if (onOutlineChanged != null ||
            onShadowChanged != null ||
            onBackgroundChanged != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Text('FX', style: TextStyle(color: _labelColor)),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (onOutlineChanged != null)
                      _fxChip(
                        lang == 'ur' ? 'آؤٹ لائن' : 'Outline',
                        outline,
                        onOutlineChanged,
                      ),
                    if (onShadowChanged != null)
                      _fxChip(
                        lang == 'ur' ? 'سایہ' : 'Shadow',
                        shadow,
                        onShadowChanged,
                      ),
                    if (onBackgroundChanged != null)
                      _fxChip(
                        lang == 'ur' ? 'بیک گراؤنڈ' : 'Background',
                        background,
                        onBackgroundChanged,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
        // Dual-language row (v1.0.10): Urdu + English as two lines.
        if (onDualChanged != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Text('Dual', style: TextStyle(color: _labelColor)),
              const SizedBox(width: 12),
              Expanded(
                child: _fxChip(
                  lang == 'ur'
                      ? 'دو زبانیں: اردو + انگریزی'
                      : 'Dual captions: UR + EN',
                  dualLanguage,
                  onDualChanged,
                ),
              ),
            ],
          ),
          if (dualLanguage)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 52),
              child: Text(
                lang == 'ur'
                    ? 'اردو لائن + انگریزی لائن، ایک ساتھ'
                    : 'Urdu line + English line, together',
                style: TextStyle(
                  color: dark ? Colors.white54 : Colors.black54,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _StyleCard extends StatefulWidget {
  final CaptionStyle style;
  final String lang;
  final bool isSelected;
  final bool dark;
  final VoidCallback onTap;

  const _StyleCard({
    required this.style,
    required this.lang,
    required this.isSelected,
    required this.dark,
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
          color: widget.dark ? const Color(0xFF1E1E1E) : null,
          border: Border.all(
            color: widget.isSelected
                ? (widget.dark
                    ? Colors.red
                    : Theme.of(context).colorScheme.primary)
                : (widget.dark ? Colors.white24 : Colors.grey.shade300),
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
                  color: widget.dark ? Colors.white : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
