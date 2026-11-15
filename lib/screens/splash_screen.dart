import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_startup.dart';
import '../services/remote_config_service.dart';

/// Cold-start splash screen: the user's Text-to-Speech poster, full
/// screen, with a live 1-100% loading count and a progress bar.
/// When startup finishes, [onFinished] opens the app.
class SplashScreen extends StatefulWidget {
  final VoidCallback onFinished;

  const SplashScreen({super.key, required this.onFinished});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  double _target = 0;
  double _shown = 0;
  String _label = 'Loading...';
  Timer? _ticker;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    // Ease the shown % toward the target so the count climbs 1-100
    // steadily instead of jumping between startup steps.
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted) return;
      setState(() {
        _shown = _shown + (_target - _shown) * 0.18;
        if (_target - _shown < 0.005) _shown = _target;
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    await AppStartup.run(
      onProgress: (progress, label) {
        if (!mounted) return;
        setState(() {
          _target = progress;
          _label = label;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _target = 1;
      _label = 'Ready';
    });
    // Let the count ease up to 100 before opening the app.
    while (mounted && _shown < 0.995) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    if (!mounted || _finished) return;
    _finished = true;
    widget.onFinished();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Splash poster: a remotely-set picture URL when the config has one
  /// (applies from the next launch after the config is fetched), else
  /// the bundled poster. A broken remote URL falls back to the poster.
  Widget _posterImage() {
    final url = RemoteConfigService.instance.config.splash.imageUrl.trim();
    if (url.isEmpty) {
      return Image.asset(
        'assets/images/splash.jpg',
        fit: BoxFit.contain,
      );
    }
    return Image.network(
      url,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => Image.asset(
        'assets/images/splash.jpg',
        fit: BoxFit.contain,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pct = (_shown * 100).round().clamp(0, 100);
    return Scaffold(
      body: Container(
        // Matches the poster's own edges (deep blue top, near-black
        // bottom) so the letterbox bands blend into the picture.
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF011985), Color(0xFF1C1B29)],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _posterImage(),
            Positioned(
              left: 32,
              right: 32,
              bottom: 56,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$pct%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 44,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _label,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: _shown,
                      minHeight: 8,
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Color(0xFFFFC107),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
