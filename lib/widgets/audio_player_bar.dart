import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

/// Compact play/pause + seek bar for one audio file or stream URL.
/// One [AudioPlayer] per bar; disposed with the widget.
class AudioPlayerBar extends StatefulWidget {
  final File? file;
  final String? url;
  final String title;

  const AudioPlayerBar({super.key, this.file, this.url, this.title = ''});

  @override
  State<AudioPlayerBar> createState() => _AudioPlayerBarState();
}

class _AudioPlayerBarState extends State<AudioPlayerBar> {
  final AudioPlayer _player = AudioPlayer();
  bool _playing = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _position = Duration.zero;
        });
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    try {
      if (_playing) {
        await _player.pause();
        if (mounted) setState(() => _playing = false);
        return;
      }
      if (_position > Duration.zero && _position < _duration) {
        await _player.resume();
      } else {
        if (widget.file != null) {
          await _player.play(DeviceFileSource(widget.file!.path));
        } else if (widget.url != null) {
          await _player.play(UrlSource(widget.url!));
        } else {
          return;
        }
      }
      if (mounted) setState(() => _playing = true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not play this audio.')),
        );
      }
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final maxMs = _duration.inMilliseconds.toDouble();
    final posMs = _position.inMilliseconds.toDouble().clamp(0.0, maxMs);
    return Row(
      children: [
        IconButton(
          icon: Icon(
            _playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
            size: 40,
            color: Theme.of(context).colorScheme.primary,
          ),
          onPressed: _toggle,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.title.isNotEmpty)
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              Slider(
                value: maxMs > 0 ? posMs : 0.0,
                max: maxMs > 0 ? maxMs : 1.0,
                onChanged: (v) async {
                  await _player.seek(Duration(milliseconds: v.round()));
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(_position), style: const TextStyle(fontSize: 11)),
                  Text(_fmt(_duration), style: const TextStyle(fontSize: 11)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
