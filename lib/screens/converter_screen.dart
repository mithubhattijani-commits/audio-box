import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/audio_item.dart';
import '../models/tts_voice.dart';
import '../services/ads_service.dart';
import '../services/audio_convert_service.dart';
import '../services/audio_library_service.dart';
import '../services/mp3_utils.dart';
import '../services/tts_service.dart';
import '../widgets/audio_player_bar.dart';

/// Audio Converter (v1.0.10) — white interface per the mockup
/// (light grey background, white cards, red #E62129 accent, green
/// result card).
///
/// 6 manual options, all selectable BEFORE converting: output format
/// (MP3 / WAV / M4A / OGG), voice Asad / Uzma (Re-generate mode
/// only), quality 128 / 192 / 320 kbps, sample rate 44.1 / 48 kHz,
/// channels Stereo / Mono, mode Convert file | Re-generate voice.
/// Plus the 8 "More tools": trim, speed, volume boost/normalize,
/// video-to-audio, ID3 tags, history, batch queue, fade in/out.
///
/// Convert-file mode is REAL transcoding of the original audio via
/// ffmpeg (ffmpeg_kit_flutter_new 4.6.8) — never re-generation.
/// Re-generate mode keeps the old Edge TTS path (Asad/Uzma via the
/// proxy) and then still runs the result through ffmpeg so the
/// chosen format / bitrate / sample rate / channels apply.
///
/// ADS (user rule, 17 Nov):
/// - Export/download of a converted file = 1 rewarded ad, fail-soft
///   ([AudioConvertService.downloadConverted] → the existing
///   download service; skip = no delivery, no ad available = direct).
/// - Heavy features show ONE rewarded unlock ad BEFORE they run:
///   batch convert (one ad unlocks the WHOLE batch, not one per
///   file) and video-to-audio. Skip/close early = the feature does
///   NOT run. No ad available at all = fail-soft, the feature runs
///   anyway. That unlock ad IS the ad for that use — files from an
///   unlocked run download with NO second ad.
/// - Single-file Convert needs no unlock — only its download ad.
/// - Conversion itself is free; no coins are involved anywhere here.
class ConverterScreen extends StatefulWidget {
  final AudioLibraryService library;

  const ConverterScreen({super.key, required this.library});

  @override
  State<ConverterScreen> createState() => _ConverterScreenState();
}

class _QueueEntry {
  final File file;
  final String name;
  final AudioItem? libraryItem; // set when added from My Audio
  final double? durationSec;
  final int sizeBytes;
  double progress = 0; // 0.0–1.0 while running
  String status = 'queued'; // 'queued' | 'running' | 'done' | 'failed'
  String? error;

  _QueueEntry({
    required this.file,
    required this.name,
    this.libraryItem,
    this.durationSec,
    required this.sizeBytes,
  });
}

class _ConverterScreenState extends State<ConverterScreen> {
  static const Color _red = Color(0xFFE62129);
  static const Color _resultGreen = Color(0xFFE9F7EC);
  static const Color _darkGreen = Color(0xFF1B7A3D);

  // --- Manual options (chosen before converting) ---
  String _mode = 'convert'; // 'convert' | 'regen'
  ConvertFormat _format = ConvertFormat.mp3;
  int _bitrate = 192;
  int _sampleRate = 44100;
  int _channels = 2;
  String _voiceId = 'asad';

  // --- Queue / run state ---
  final List<_QueueEntry> _queue = [];
  bool _converting = false;
  bool _busy = false; // video extraction in flight
  double? _videoProgress;
  String? _message;
  bool _messageIsError = false;
  ConvertedFile? _result;
  List<ConvertedFile> _history = [];
  int _wavCount = 0;
  int _mp3Count = 0;

  // --- More-tools state ---
  String? _openTool; // 'trim' | 'speed' | 'volume' | 'video' | 'tags' | 'fade'
  bool _trimEnabled = false;
  double _trimStart = 0;
  double _trimEnd = 0;
  double _speed = 1.0;
  double _volume = 1.0;
  bool _normalize = false;
  double _fadeIn = 0;
  double _fadeOut = 0;
  final _titleCtrl = TextEditingController();
  final _artistCtrl = TextEditingController();
  final _queueKey = GlobalKey();
  final _historyKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    await widget.library.load();
    final history = await AudioConvertService.loadHistory();
    if (!mounted) return;
    setState(() {
      _wavCount =
          widget.library.items.where((i) => i.ext == 'wav').length;
      _mp3Count =
          widget.library.items.where((i) => i.ext == 'mp3').length;
      _history = history;
    });
  }

  void _setMessage(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _messageIsError = error;
    });
  }

  ConvertOptions _currentOptions() => ConvertOptions(
        format: _format,
        bitrateKbps: _bitrate,
        sampleRateHz: _sampleRate,
        channels: _channels,
        voiceId: _voiceId,
        trimStartSec: _trimEnabled ? _trimStart : null,
        trimEndSec: _trimEnabled ? _trimEnd : null,
        speed: _speed,
        volumeGain: _volume,
        normalize: _normalize,
        fadeInSec: _fadeIn,
        fadeOutSec: _fadeOut,
        title: _titleCtrl.text.trim(),
        artist: _artistCtrl.text.trim(),
      );

  double get _trimDuration =>
      _queue.isEmpty ? 0 : (_queue.first.durationSec ?? 0);

  /// Keep the trim range inside the first queued file's duration.
  /// Called inside setState — plain assignments only.
  void _syncTrimLocked() {
    if (_queue.isEmpty) {
      _trimEnabled = false;
      _trimStart = 0;
      _trimEnd = 0;
      return;
    }
    final dur = _queue.first.durationSec;
    if (dur == null || dur <= 0) return;
    if (_trimEnd <= 0 || _trimEnd > dur) _trimEnd = dur;
    if (_trimStart >= _trimEnd) _trimStart = 0;
  }

  Future<void> _addPickedFile(
    File file,
    String name, {
    AudioItem? libraryItem,
  }) async {
    if (_queue.any((e) => e.file.path == file.path)) return;
    if (!await file.exists()) return;
    final size = await file.length();
    final duration = await AudioConvertService.probeDurationSec(file);
    if (!mounted) return;
    setState(() {
      _queue.add(
        _QueueEntry(
          file: file,
          name: name,
          libraryItem: libraryItem,
          durationSec: duration,
          sizeBytes: size,
        ),
      );
      _syncTrimLocked();
    });
  }

  Future<void> _pickFiles({bool replace = false}) async {
    if (_converting) return;
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav', 'mp3', 'm4a', 'ogg', 'flac', 'aac'],
    );
    if (picked.isEmpty) return;
    if (replace) {
      setState(() {
        _queue.clear();
        _trimEnabled = false;
        _trimStart = 0;
        _trimEnd = 0;
      });
    }
    for (final f in picked) {
      if (f.path == null) continue;
      await _addPickedFile(File(f.path!), f.name);
      if (!mounted) return;
    }
  }

  /// Add saved WAV items from My Audio — the only queue entries that
  /// carry text, so the only ones Re-generate mode can use.
  Future<void> _addFromLibrary() async {
    if (_converting) return;
    await widget.library.load();
    final wavItems =
        widget.library.items.where((i) => i.ext == 'wav').toList();
    if (!mounted) return;
    if (wavItems.isEmpty) {
      _setMessage('My Audio mein koi WAV file nahi hai.', error: true);
      return;
    }
    final selected = <String>{};
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('My Audio — WAV files'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: wavItems.length,
              itemBuilder: (ctx, i) {
                final item = wavItems[i];
                return CheckboxListTile(
                  title: Text(item.displayTitle),
                  subtitle: Text(item.voiceId),
                  value: selected.contains(item.id),
                  onChanged: (v) => setDialogState(() {
                    if (v == true) {
                      selected.add(item.id);
                    } else {
                      selected.remove(item.id);
                    }
                  }),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(selected),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (result == null || result.isEmpty || !mounted) return;
    for (final id in result) {
      final item = wavItems.firstWhere((e) => e.id == id);
      await _addPickedFile(
        File(item.filePath),
        item.filePath.split('/').last,
        libraryItem: item,
      );
      if (!mounted) return;
    }
  }

  /// Re-generate one library entry's text with the chosen Edge voice
  /// (Asad/Uzma) via the proxy, then transcode the MP3 bytes through
  /// ffmpeg so the chosen format / bitrate / sample rate / channels
  /// and effects apply. If ffmpeg fails but the target is MP3, the
  /// genuine Edge MP3 bytes are saved as-is instead of failing.
  Future<ConvertedFile> _regenerate(
    _QueueEntry entry,
    ConvertOptions options,
    bool adUnlocked,
  ) async {
    final item = entry.libraryItem!;
    final voice = TtsVoice.byId(options.voiceId);
    final text = item.text.trim();
    final chunks = TtsService.chunkText(text, voice);
    if (chunks.isEmpty) {
      throw Exception('Is audio mein koi text nahi hai.');
    }
    final tts = TtsService();
    final parts = <Uint8List>[];
    for (final chunk in chunks) {
      final gen = await tts.generateChunk(chunk, voice);
      parts.add(gen.bytes);
    }
    final mp3Bytes =
        parts.length == 1 ? parts.first : concatMp3(parts);
    final dir = await AudioConvertService.convertedDir();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final tmp = File('${dir.path}/regen_tmp_$stamp.mp3');
    try {
      await tmp.writeAsBytes(mp3Bytes);
      final tmpDuration =
          await AudioConvertService.probeDurationSec(tmp);
      try {
        return await AudioConvertService.convertFile(
          input: tmp,
          inputName: entry.name,
          options: options,
          inputDurationSec: tmpDuration ?? entry.durationSec,
          adUnlocked: adUnlocked,
        );
      } catch (_) {
        if (options.format != ConvertFormat.mp3) rethrow;
        final base = AudioConvertService.baseNameOf(entry.name);
        final outFile = File('${dir.path}/${base}_$stamp.mp3');
        await outFile.writeAsBytes(mp3Bytes);
        return ConvertedFile(
          id: stamp.toString(),
          fileName: outFile.path.split('/').last,
          filePath: outFile.path,
          format: 'mp3',
          bitrateLabel: 'Edge MP3',
          sampleRateHz: options.sampleRateHz,
          channels: options.channels,
          durationSec: tmpDuration ?? entry.durationSec ?? 0,
          sizeBytes: mp3Bytes.length,
          createdAtMs: stamp,
          adUnlocked: adUnlocked,
        );
      }
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  Future<void> _convertAll() async {
    if (_converting || _queue.isEmpty) return;
    if (_mode == 'regen') {
      final bad = _queue.where(
        (e) =>
            e.libraryItem == null ||
            e.libraryItem!.text.trim().isEmpty,
      );
      if (bad.isNotEmpty) {
        _setMessage(
          'Re-generate ke liye My Audio se WAV file add karein — '
          'picked files mein text nahi hota.',
          error: true,
        );
        return;
      }
    }
    // Batch unlock: ONE rewarded ad unlocks the WHOLE batch run
    // (not one per file). Single-file convert needs no unlock.
    // Skip = the run does not start; no ad available = fail-soft,
    // the run goes ahead (see AudioConvertService.playUnlockAd).
    final isBatch = _queue.length > 1;
    var adUnlockedRun = false;
    if (isBatch) {
      final ok = await AudioConvertService.playUnlockAd(context);
      if (!mounted) return;
      if (!ok) {
        _setMessage('Ad skip ki — batch convert nahi hua.', error: true);
        return;
      }
      adUnlockedRun = true;
    }
    setState(() {
      _converting = true;
      _message = null;
      _result = null;
    });
    var done = 0;
    var failed = 0;
    try {
      for (final entry in _queue) {
        if (!mounted) return;
        setState(() {
          entry.status = 'running';
          entry.progress = 0;
          entry.error = null;
        });
        try {
          final options = _currentOptions();
          final ConvertedFile out;
          if (_mode == 'regen') {
            out = await _regenerate(entry, options, adUnlockedRun);
          } else {
            out = await AudioConvertService.convertFile(
              input: entry.file,
              inputName: entry.name,
              options: options,
              inputDurationSec: entry.durationSec,
              adUnlocked: adUnlockedRun,
              onProgress: (p) {
                if (mounted) setState(() => entry.progress = p);
              },
            );
          }
          final updated =
              await AudioConvertService.addToHistory(out);
          if (!mounted) return;
          setState(() {
            entry.status = 'done';
            entry.progress = 1;
            _result = out;
            _history = updated;
          });
          done++;
        } catch (e) {
          if (!mounted) return;
          setState(() {
            entry.status = 'failed';
            entry.error = '$e';
          });
          failed++;
        }
      }
      if (!mounted) return;
      setState(() {
        if (failed == 0) {
          _message =
              'Converted $done file${done > 1 ? 's' : ''} — download '
              'ke liye neeche result dekhein.';
          _messageIsError = false;
        } else {
          _message =
              'Converted $done, failed $failed — failed file ka error '
              'uske neeche dekhein.';
          _messageIsError = true;
        }
      });
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }

  /// Video-to-audio (More tools): pick an MP4 video, unlock with ONE
  /// rewarded ad, extract MP3. Skip = no extraction; no ad
  /// available = fail-soft, extraction runs. The unlock ad IS this
  /// file's ad — its download shows no second ad.
  Future<void> _pickVideoAndExtract() async {
    if (_busy || _converting) return;
    final picked = await FilePicker.pickFile(type: FileType.video);
    if (picked == null || picked.path == null) return;
    if (!mounted) return;
    setState(() {
      _busy = true;
      _videoProgress = 0;
      _message = null;
    });
    try {
      final ok = await AudioConvertService.playUnlockAd(context);
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _message = 'Ad skip ki — video se audio nahi nikla.';
          _messageIsError = true;
          _busy = false;
          _videoProgress = null;
        });
        return;
      }
      final video = File(picked.path!);
      final result =
          await AudioConvertService.extractAudioFromVideo(
        video: video,
        videoName: picked.name,
        options: _currentOptions(),
        adUnlocked: true,
        onProgress: (p) {
          if (mounted) setState(() => _videoProgress = p);
        },
      );
      final updated = await AudioConvertService.addToHistory(result);
      if (!mounted) return;
      setState(() {
        _result = result;
        _history = updated;
        _message = 'Video se audio nikal liya — MP3 ready.';
        _messageIsError = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = 'Video se audio nahi nikla: $e';
          _messageIsError = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _videoProgress = null;
        });
      }
    }
  }

  Future<void> _download(ConvertedFile file) async {
    await AudioConvertService.downloadConverted(context, file);
  }

  Future<void> _removeHistory(ConvertedFile file) async {
    final updated =
        await AudioConvertService.removeFromHistory(file.id);
    if (!mounted) return;
    setState(() {
      _history = updated;
      if (_result?.id == file.id) _result = null;
    });
  }

  void _scrollTo(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
      );
    }
  }

  void _onToolTap(String key) {
    if (key == 'history') {
      _scrollTo(_historyKey);
      return;
    }
    if (key == 'batch') {
      _scrollTo(_queueKey);
      return;
    }
    setState(() => _openTool = _openTool == key ? null : key);
  }

  // ---------- formatting helpers ----------

  String _clock(double seconds) {
    final total = seconds.round();
    final m = total ~/ 60;
    final s = total % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _sizeLabel(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  String _dateLabel(int ms) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.day} ${months[dt.month - 1]}';
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
      );

  Widget _choiceChips<T>({
    required List<T> values,
    required T selected,
    required String Function(T) label,
    required void Function(T) onTap,
    bool enabled = true,
  }) {
    final chips = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final v in values)
          ChoiceChip(
            label: Text(label(v)),
            selected: v == selected,
            selectedColor: _red,
            backgroundColor: Colors.white,
            labelStyle: TextStyle(
              color: v == selected ? Colors.white : Colors.black87,
              fontWeight:
                  v == selected ? FontWeight.bold : FontWeight.normal,
            ),
            side: BorderSide(
              color: v == selected ? _red : Colors.grey.shade300,
            ),
            onSelected: enabled ? (_) => onTap(v) : null,
          ),
      ],
    );
    if (!enabled) return Opacity(opacity: 0.45, child: chips);
    return chips;
  }

  Widget _toolCard({
    required String key,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final open = _openTool == key;
    return Card(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: open ? _red : Colors.grey.shade300,
          width: open ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _onToolTap(key),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFFDECEC),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: _red),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolPanel() {
    final tool = _openTool;
    if (tool == null) return const SizedBox.shrink();
    final body = switch (tool) {
      'trim' => _trimPanel(),
      'speed' => _speedPanel(),
      'volume' => _volumePanel(),
      'video' => _videoPanel(),
      'tags' => _tagsPanel(),
      'fade' => _fadePanel(),
      _ => const SizedBox.shrink(),
    };
    return Card(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: body,
      ),
    );
  }

  Widget _trimPanel() {
    if (_queue.isEmpty) {
      return const Text(
        'Trim ke liye pehle upar se koi audio file add karein.',
      );
    }
    final dur = _trimDuration;
    if (dur <= 0) {
      return const Text(
        'Is file ki duration maloom nahi — trim nahi ho sakta.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: const Text('Trim on/off'),
          subtitle: const Text('Convert karte waqt sirf ye hissa rakhein'),
          value: _trimEnabled,
          activeThumbColor: _red,
          contentPadding: EdgeInsets.zero,
          onChanged: (v) => setState(() {
            _trimEnabled = v;
            if (v && _trimEnd <= 0) _trimEnd = dur;
          }),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Start: ${_clock(_trimStart)}'),
            Text('End: ${_clock(_trimEnd)}'),
          ],
        ),
        RangeSlider(
          values: RangeValues(_trimStart, _trimEnd),
          min: 0,
          max: dur,
          divisions: (dur * 10).round().clamp(1, 600),
          labels: RangeLabels(_clock(_trimStart), _clock(_trimEnd)),
          activeColor: _red,
          onChanged: _trimEnabled
              ? (v) => setState(() {
                    _trimStart = v.start;
                    _trimEnd = v.end;
                  })
              : null,
        ),
        const Text(
          'Trim ffmpeg se convert ke saath hi lagta hai — alag file '
          'nahi banti.',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
      ],
    );
  }

  Widget _speedPanel() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Speed: ${_speed.toStringAsFixed(2)}×',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Slider(
            value: _speed,
            min: 0.5,
            max: 2.0,
            divisions: 30,
            label: '${_speed.toStringAsFixed(2)}×',
            activeColor: _red,
            onChanged: (v) => setState(() => _speed = v),
          ),
          const Text(
            '0.5× slow, 2× tez. Speed se pitch bhi badalti hai.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      );

  Widget _volumePanel() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Volume: ${_volume.toStringAsFixed(1)}×',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Slider(
            value: _volume,
            min: 0.5,
            max: 2.0,
            divisions: 15,
            label: '${_volume.toStringAsFixed(1)}×',
            activeColor: _red,
            onChanged: _normalize
                ? null
                : (v) => setState(() => _volume = v),
          ),
          SwitchListTile(
            title: const Text('Normalize (loudness standard)'),
            subtitle: const Text('Halki awaz standard level tak le aayein'),
            value: _normalize,
            activeThumbColor: _red,
            contentPadding: EdgeInsets.zero,
            onChanged: (v) => setState(() => _normalize = v),
          ),
          const Text(
            'Normalize on ho to volume slider band ho jata hai.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      );

  Widget _videoPanel() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'MP4 video ki audio MP3 mein nikal lein — video stream '
            'hata di jati hai.',
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickVideoAndExtract,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Pick MP4 video'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _red,
              side: const BorderSide(color: _red),
            ),
          ),
          if (_busy && _videoProgress != null) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: _videoProgress,
              color: _red,
              backgroundColor: Colors.grey.shade200,
            ),
          ],
          const SizedBox(height: 8),
          const Text(
            'Video se audio nikalne se pehle 1 rewarded ad dikhega — '
            'skip ki to extract nahi hoga, ad na mile to bhi chalega.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      );

  Widget _tagsPanel() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Title / artist MP3 ki ID3 tags mein likhe jate hain.',
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _titleCtrl,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _artistCtrl,
            decoration: const InputDecoration(labelText: 'Artist'),
          ),
        ],
      );

  Widget _fadePanel() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Fade in: ${_fadeIn.toStringAsFixed(1)}s',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Slider(
            value: _fadeIn,
            min: 0,
            max: 5,
            divisions: 10,
            label: '${_fadeIn.toStringAsFixed(1)}s',
            activeColor: _red,
            onChanged: (v) => setState(() => _fadeIn = v),
          ),
          Text(
            'Fade out: ${_fadeOut.toStringAsFixed(1)}s',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Slider(
            value: _fadeOut,
            min: 0,
            max: 5,
            divisions: 10,
            label: '${_fadeOut.toStringAsFixed(1)}s',
            activeColor: _red,
            onChanged: (v) => setState(() => _fadeOut = v),
          ),
          const Text(
            'Awaz halki se aaye aur halki se khatam ho.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      );

  Widget _resultCard() {
    final result = _result;
    if (result == null) return const SizedBox.shrink();
    final durationLabel =
        result.durationSec > 0 ? _clock(result.durationSec) : '--:--';
    final channelsLabel = result.channels == 2 ? 'Stereo' : 'Mono';
    return Container(
      decoration: BoxDecoration(
        color: _resultGreen,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.green.shade200),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '✓ Converted!',
            style: TextStyle(
              color: _darkGreen,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            result.fileName,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            '${result.format.toUpperCase()} • ${result.bitrateLabel} • '
            '${result.sampleRateHz == 48000 ? '48' : '44.1'} kHz • '
            '$channelsLabel • $durationLabel • '
            '${_sizeLabel(result.sizeBytes)}',
            style: const TextStyle(color: Colors.black87, fontSize: 13),
          ),
          const SizedBox(height: 8),
          AudioPlayerBar(
            file: File(result.filePath),
            title: result.fileName,
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () => _download(result),
            icon: const Icon(Icons.download),
            label: Text(
              result.adUnlocked
                  ? 'Download • ad already watched'
                  : 'Download • 1 ad',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green[700],
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          if (result.adUnlocked)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Batch / video unlock ad already watched — '
                'download par dobara ad nahi dikhega.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final first = _queue.isEmpty ? null : _queue.first;
    final isRegen = _mode == 'regen';
    return Scaffold(
      appBar: AppBar(title: const Text('Audio Converter')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Convert audio files — format, voice aur quality khud '
              'select karein.',
            ),
            const SizedBox(height: 12),
            // Selected file card.
            Card(
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFDECEC),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.music_note,
                        color: _red,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            first?.name ?? 'No file selected',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            first == null
                                ? 'Neeche se files add karein'
                                : '${first.name.split('.').last.toUpperCase()} • '
                                    '${first.durationSec != null ? _clock(first.durationSec!) : '--:--'} • '
                                    '${_sizeLabel(first.sizeBytes)}',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            'Saved files: $_wavCount WAV • $_mp3Count MP3',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    OutlinedButton(
                      onPressed: _converting
                          ? null
                          : () => _pickFiles(replace: true),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _red,
                        side: const BorderSide(color: _red),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                      ),
                      child: const Text('Change file'),
                    ),
                  ],
                ),
              ),
            ),
            // Mode.
            _sectionTitle('Mode'),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'convert',
                  icon: Icon(Icons.transform),
                  label: Text('Convert file'),
                ),
                ButtonSegment(
                  value: 'regen',
                  icon: Icon(Icons.record_voice_over),
                  label: Text('Re-generate voice'),
                ),
              ],
              selected: {_mode},
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: _red,
                selectedForegroundColor: Colors.white,
              ),
              onSelectionChanged: _converting
                  ? null
                  : (s) => setState(() {
                        _mode = s.first;
                        _message = null;
                      }),
            ),
            // Output format.
            _sectionTitle('Output format'),
            _choiceChips<ConvertFormat>(
              values: ConvertFormat.values,
              selected: _format,
              label: (f) => f.label,
              onTap: (f) => setState(() => _format = f),
            ),
            // Voice (Re-generate only).
            _sectionTitle('Voice  (Re-generate mode mein)'),
            _choiceChips<String>(
              values: const ['asad', 'uzma'],
              selected: _voiceId,
              label: (v) => v == 'asad' ? 'Asad' : 'Uzma',
              onTap: (v) => setState(() => _voiceId = v),
              enabled: isRegen,
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Convert file mode mein original audio hi rehta hai — '
                'awaz nahi badalti.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
            // Quality.
            _sectionTitle('Quality  (bitrate)'),
            _choiceChips<int>(
              values: const [128, 192, 320],
              selected: _bitrate,
              label: (b) => '$b kbps',
              onTap: (b) => setState(() => _bitrate = b),
            ),
            // Sample rate.
            _sectionTitle('Sample rate'),
            _choiceChips<int>(
              values: const [44100, 48000],
              selected: _sampleRate,
              label: (r) => r == 44100 ? '44.1 kHz' : '48 kHz',
              onTap: (r) => setState(() => _sampleRate = r),
            ),
            // Channels.
            _sectionTitle('Channels'),
            _choiceChips<int>(
              values: const [2, 1],
              selected: _channels,
              label: (c) => c == 2 ? 'Stereo' : 'Mono',
              onTap: (c) => setState(() => _channels = c),
            ),
            // Batch queue.
            _sectionTitle('Batch queue — ${_queue.length} files'),
            Container(
              key: _queueKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed:
                              _converting ? null : () => _pickFiles(),
                          icon: const Icon(Icons.add),
                          label: const Text('Add files'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _red,
                            side: const BorderSide(color: _red),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed:
                              _converting ? null : _addFromLibrary,
                          icon: const Icon(Icons.library_music),
                          label: const Text('My Audio'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _red,
                            side: const BorderSide(color: _red),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_queue.isEmpty)
                    const Card(
                      color: Colors.white,
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'Abhi koi file nahi — audio files add karein, '
                          'ya Re-generate ke liye My Audio se WAV chunein.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ),
                  for (final entry in _queue)
                    Card(
                      color: Colors.white,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  entry.status == 'done'
                                      ? Icons.check_circle
                                      : entry.status == 'failed'
                                          ? Icons.error
                                          : Icons.audio_file,
                                  color: entry.status == 'done'
                                      ? _darkGreen
                                      : entry.status == 'failed'
                                          ? Colors.red
                                          : Colors.grey,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '${entry.name}  →  .${_format.ext}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                Text(
                                  entry.status == 'done'
                                      ? 'Done'
                                      : entry.status == 'failed'
                                          ? 'Failed'
                                          : entry.status == 'running'
                                              ? '${(entry.progress * 100).round()}%'
                                              : 'Queued',
                                  style: TextStyle(
                                    color: entry.status == 'done'
                                        ? _darkGreen
                                        : entry.status == 'failed'
                                            ? Colors.red
                                            : _red,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close, size: 18),
                                  tooltip: 'Remove',
                                  onPressed: _converting
                                      ? null
                                      : () => setState(() {
                                            _queue.remove(entry);
                                            _syncTrimLocked();
                                          }),
                                ),
                              ],
                            ),
                            if (entry.status == 'running')
                              Padding(
                                padding:
                                    const EdgeInsets.only(top: 8),
                                child: LinearProgressIndicator(
                                  value: entry.progress > 0
                                      ? entry.progress
                                      : null,
                                  color: _red,
                                  backgroundColor: Colors.grey.shade200,
                                ),
                              ),
                            if (entry.status == 'failed' &&
                                entry.error != null)
                              Padding(
                                padding:
                                    const EdgeInsets.only(top: 6),
                                child: Text(
                                  entry.error!,
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            ElevatedButton.icon(
              onPressed:
                  (_converting || _queue.isEmpty) ? null : _convertAll,
              icon: _converting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.swap_horiz),
              label: Text(
                _converting
                    ? 'Converting…'
                    : 'Convert — ${_queue.length} file${_queue.length == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 17),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _red,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            if (_queue.length > 1)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Batch convert se pehle 1 rewarded ad dikhega — '
                  'skip ki to convert nahi hoga, ad na mile to bhi '
                  'chalega.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _message!,
                  style: TextStyle(
                    color: _messageIsError ? Colors.red : _darkGreen,
                  ),
                ),
              ),
            const SizedBox(height: 14),
            _resultCard(),
            const SizedBox(height: 12),
            const Text(
              'Converted files ki history neeche — dobara download '
              'kabhi bhi.',
              style: TextStyle(color: Colors.grey),
            ),
            // History.
            _sectionTitle('Converted files — history'),
            Container(
              key: _historyKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_history.isEmpty)
                    const Card(
                      color: Colors.white,
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'Abhi koi converted file nahi hai.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ),
                  for (final item in _history)
                    Card(
                      color: Colors.white,
                      child: ListTile(
                        leading: const Icon(
                          Icons.music_note,
                          color: _red,
                        ),
                        title: Text(item.fileName),
                        subtitle: Text(
                          '${item.format.toUpperCase()} • '
                          '${item.bitrateLabel} • '
                          '${_dateLabel(item.createdAtMs)}'
                          '${item.adUnlocked ? ' • ad watched' : ''}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              onPressed: () => _download(item),
                              style: TextButton.styleFrom(
                                foregroundColor: _red,
                              ),
                              child: const Text('Download'),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, size: 20),
                              tooltip: 'Delete',
                              onPressed: () => _removeHistory(item),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Download pehle 1 rewarded ad dekhein — skip ki to file '
                'save nahi hogi.',
                style: TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ),
            // More tools.
            _sectionTitle('More tools'),
            const Text(
              'Ye sab aik hi Audio Converter mein — alag tool kholne ki '
              'zaroorat nahi.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 10),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 2.1,
              children: [
                _toolCard(
                  key: 'trim',
                  icon: Icons.content_cut,
                  title: 'Trim audio',
                  subtitle: 'Start / end set karein',
                ),
                _toolCard(
                  key: 'speed',
                  icon: Icons.speed,
                  title: 'Speed 0.5–2×',
                  subtitle: 'Tez ya slow karein',
                ),
                _toolCard(
                  key: 'volume',
                  icon: Icons.volume_up,
                  title: 'Volume boost',
                  subtitle: 'Halki awaz tez karein',
                ),
                _toolCard(
                  key: 'video',
                  icon: Icons.play_arrow,
                  title: 'Video se audio',
                  subtitle: 'MP4 se MP3 nikal lein',
                ),
                _toolCard(
                  key: 'tags',
                  icon: Icons.edit,
                  title: 'File tags',
                  subtitle: 'Title / artist likhein',
                ),
                _toolCard(
                  key: 'history',
                  icon: Icons.history,
                  title: 'History',
                  subtitle: 'Dobara download karein',
                ),
                _toolCard(
                  key: 'batch',
                  icon: Icons.grid_view,
                  title: 'Batch queue',
                  subtitle: 'Kai files aik saath',
                ),
                _toolCard(
                  key: 'fade',
                  icon: Icons.show_chart,
                  title: 'Fade in / out',
                  subtitle: 'Awaz halki se aaye',
                ),
              ],
            ),
            const SizedBox(height: 10),
            _toolPanel(),
            const SizedBox(height: 16),
            const Text(
              'Kul 14 cheezein — 6 manual options + 8 extra tools.',
              style: TextStyle(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const Text(
              'Real format conversion (MP3 ↔ WAV, bina dobara bolay) '
              'ffmpeg se hoti hai — APK ~30 MB barhega. Re-generate '
              '(Asad/Uzma) abhi bhi hai.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
      bottomNavigationBar: const UnityBannerAdWidget(zone: 'converter'),
    );
  }
}
