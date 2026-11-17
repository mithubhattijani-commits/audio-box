import 'package:flutter/material.dart';

import '../services/caption_service.dart';
import '../services/caption_styles.dart';
import '../services/video_export_service.dart';
import 'caption_style_picker.dart';

/// Shared Caption Studio editor widgets (v1.0.10, mockup v3) — used
/// identically by the Video Caption Maker and the AI Caption
/// Generator so the two screens never drift apart again.

/// Dark style panel: presets + style cards + controls.
class CaptionStylePanel extends StatelessWidget {
  final String lang;
  final CaptionStyle style;
  final ValueChanged<CaptionStyle> onStyleSelected;
  final String presetId;
  final ValueChanged<CaptionPreset> onPresetSelected;
  final CaptionPosition position;
  final ValueChanged<CaptionPosition> onPositionChanged;
  final CaptionSize size;
  final ValueChanged<CaptionSize> onSizeChanged;
  final int highlight;
  final ValueChanged<int> onHighlightChanged;
  final CaptionFont font;
  final ValueChanged<CaptionFont> onFontChanged;
  final bool fxOutline;
  final ValueChanged<bool> onOutlineChanged;
  final bool fxShadow;
  final ValueChanged<bool> onShadowChanged;
  final bool fxBackground;
  final ValueChanged<bool> onBackgroundChanged;
  final bool dualLanguage;
  final ValueChanged<bool> onDualChanged;

  const CaptionStylePanel({
    super.key,
    required this.lang,
    required this.style,
    required this.onStyleSelected,
    required this.presetId,
    required this.onPresetSelected,
    required this.position,
    required this.onPositionChanged,
    required this.size,
    required this.onSizeChanged,
    required this.highlight,
    required this.onHighlightChanged,
    required this.font,
    required this.onFontChanged,
    required this.fxOutline,
    required this.onOutlineChanged,
    required this.fxShadow,
    required this.onShadowChanged,
    required this.fxBackground,
    required this.onBackgroundChanged,
    required this.dualLanguage,
    required this.onDualChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CaptionPresetPicker(
            selectedPresetId: presetId,
            onPresetSelected: onPresetSelected,
            lang: lang,
            dark: true,
          ),
          const SizedBox(height: 12),
          CaptionStylePicker(
            selected: style,
            lang: lang,
            onStyleSelected: onStyleSelected,
            dark: true,
          ),
          const SizedBox(height: 12),
          CaptionStyleControls(
            position: position,
            onPositionChanged: onPositionChanged,
            size: size,
            onSizeChanged: onSizeChanged,
            highlightColor: highlight,
            onHighlightChanged: onHighlightChanged,
            lang: lang,
            font: font,
            onFontChanged: onFontChanged,
            dark: true,
            outline: fxOutline,
            onOutlineChanged: onOutlineChanged,
            shadow: fxShadow,
            onShadowChanged: onShadowChanged,
            background: fxBackground,
            onBackgroundChanged: onBackgroundChanged,
            dualLanguage: dualLanguage,
            onDualChanged: onDualChanged,
          ),
        ],
      ),
    );
  }
}

/// Dark editor toolbar: Split / Merge / + Line / Translate / Undo /
/// Redo + total duration.
class CaptionEditorToolbar extends StatelessWidget {
  final Duration total;
  final bool canUndo;
  final bool canRedo;
  final VoidCallback onSplit;
  final VoidCallback onMerge;
  final VoidCallback onAddLine;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onTranslate;

  const CaptionEditorToolbar({
    super.key,
    required this.total,
    required this.canUndo,
    required this.canRedo,
    required this.onSplit,
    required this.onMerge,
    required this.onAddLine,
    required this.onUndo,
    required this.onRedo,
    required this.onTranslate,
  });

  String _clock(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Widget _toolButton(
    String label,
    IconData icon,
    VoidCallback? onTap, {
    bool enabled = true,
  }) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.white12,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: Colors.white),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _toolButton('Split', Icons.call_split, onSplit),
                _toolButton('Merge', Icons.merge_type, onMerge),
                _toolButton('+ Line', Icons.add, onAddLine),
                _toolButton('Translate', Icons.translate, onTranslate),
                _toolButton('Undo', Icons.undo, onUndo, enabled: canUndo),
                _toolButton('Redo', Icons.redo, onRedo, enabled: canRedo),
              ],
            ),
          ),
          Text(
            _clock(total),
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

/// Dark timeline strip: one chip per caption line; the selected chip
/// is green.
class CaptionTimelineStrip extends StatelessWidget {
  final List<CaptionSegment> segments;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const CaptionTimelineStrip({
    super.key,
    required this.segments,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'TIMELINE',
            style: TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: segments.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final selected = i == selectedIndex;
                return GestureDetector(
                  onTap: () => onSelect(i),
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: selected ? Colors.green : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: selected ? Colors.green : Colors.white24,
                      ),
                    ),
                    child: Text(
                      segments[i].timeLabel,
                      style: TextStyle(
                        color: selected ? Colors.white : Colors.white70,
                        fontWeight:
                            selected ? FontWeight.bold : FontWeight.normal,
                        fontSize: 12,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Selected-line editor card (dark): time chip, ±0.1s nudge, text,
/// edit + delete.
class SelectedCaptionLineCard extends StatelessWidget {
  final CaptionSegment segment;
  final ValueChanged<double> onNudge;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const SelectedCaptionLineCard({
    super.key,
    required this.segment,
    required this.onNudge,
    required this.onEdit,
    required this.onDelete,
  });

  Widget _nudgeButton(String label, double delta) {
    return GestureDetector(
      onTap: () => onNudge(delta),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(label, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  segment.timeLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _nudgeButton('−0.1s', -0.1),
              const SizedBox(width: 6),
              _nudgeButton('+0.1s', 0.1),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.edit, color: Colors.white70),
                onPressed: onEdit,
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.red),
                onPressed: onDelete,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            segment.text,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          if (segment.translation.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                segment.translation,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ),
        ],
      ),
    );
  }
}

/// Export-sheet format choices (mockup v3-export).
enum CaptionExportFormat { srt, ass, vtt, txt, video, copy }

/// What the user picked in the export sheet.
class CaptionExportChoice {
  const CaptionExportChoice({
    required this.format,
    required this.quality,
    required this.dualLanguage,
  });

  final CaptionExportFormat format;
  final VideoExportQuality quality;
  final bool dualLanguage;
}

/// Result of the edit-line / add-line dialog.
class EditedCaptionLine {
  const EditedCaptionLine({
    required this.text,
    required this.translation,
    required this.start,
    required this.end,
  });

  final String text;
  final String translation;
  final double? start;
  final double? end;
}
