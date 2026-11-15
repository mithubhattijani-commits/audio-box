import 'package:flutter/material.dart';

import '../services/google_auth_service.dart';

/// Login gate (v1.0.3): shown after the splash whenever there is no
/// Google-linked Supabase session — first launch, after reinstall, or
/// after the session expired. MainShell and every coin feature (daily
/// claim, rewarded ads, generation) sit behind this screen.
///
/// One button, one job: "Sign in with Google". Coins are tied to the
/// Google account, so they survive reinstalls — an anonymous account
/// on this device is linked onto the same user.id first (see
/// GoogleAuthService), so existing coins are kept. Cancel / failure
/// shows a message and stays here: never a crash, never a silent
/// fallback to anonymous for coins.
class LoginScreen extends StatefulWidget {
  final VoidCallback onSignedIn;

  const LoginScreen({super.key, required this.onSignedIn});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await GoogleAuthService.signInWithGoogle();
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.ok) {
      if (!mounted) return;
      widget.onSignedIn();
      return;
    }
    if (!mounted) return;
    setState(
      () => _error = result.error ?? 'Sign-in failed. Please try again.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.audiotrack,
                size: 72,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              const Text(
                'Audio Box From Jaani',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                'Sign in with your Google account to use Audio Box.\n'
                'Your coins are tied to your Google account, so they '
                'stay with you even if you reinstall the app.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: Colors.grey),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _busy ? null : _signIn,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black87,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: Colors.grey),
                ),
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'G',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF4285F4),
                            ),
                          ),
                          SizedBox(width: 12),
                          Text(
                            'Sign in with Google',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red, fontSize: 14),
                ),
              ],
              const SizedBox(height: 24),
              const Text(
                'Nigraan TV  •  Text to audio, free with coins',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
