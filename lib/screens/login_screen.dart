import 'package:flutter/material.dart';

import '../services/email_auth_service.dart';
import '../services/google_auth_service.dart';

/// Login gate (v1.0.3 Google, v1.0.4 + email): shown after the splash
/// whenever there is no permanent Supabase session — first launch,
/// after reinstall, or after the session expired. MainShell and every
/// coin feature (daily claim, rewarded ads, generation) sit behind
/// this screen.
///
/// Two ways in, same as TJ Earn had:
///  * Email + password — Login for an existing account, Register for
///    a new one. Register attaches the email to the anonymous user
///    when one exists, so its coins survive; Login signs into the
///    email account's own coins.
///  * "Sign in with Google" — one tap, coins tied to the Google
///    account.
///
/// Cancel / failure shows a message and stays here: never a crash,
/// never a silent fallback to anonymous for coins.
class LoginScreen extends StatefulWidget {
  final VoidCallback onSignedIn;

  const LoginScreen({super.key, required this.onSignedIn});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // Register first: most installs are fresh, and a returning user who
  // taps Register with an existing email is signed in anyway.
  bool _isRegister = true;
  bool _busy = false;
  String? _error;

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _switchMode(bool register) {
    if (_busy) return;
    setState(() {
      _isRegister = register;
      _error = null;
    });
  }

  Future<void> _submitEmail() async {
    if (_busy) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = 'Please enter a valid email address.');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = _isRegister
        ? await EmailAuthService.registerWithEmail(
            email: email,
            password: password,
          )
        : await EmailAuthService.signInWithEmail(
            email: email,
            password: password,
          );
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

  Future<void> _signInGoogle() async {
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
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
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
                  'Sign in to use Audio Box.\n'
                  'Your coins stay with your account, so they '
                  'are safe even if you reinstall the app.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: Colors.grey),
                ),
                const SizedBox(height: 28),
                // Login / Register switch.
                Row(
                  children: [
                    Expanded(
                      child: _ModeButton(
                        label: 'Login',
                        selected: !_isRegister,
                        onTap: () => _switchMode(false),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ModeButton(
                        label: 'Register',
                        selected: _isRegister,
                        onTap: () => _switchMode(true),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: TextInputAction.next,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    hintText: 'you@example.com',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  textInputAction: TextInputAction.done,
                  enabled: !_busy,
                  onSubmitted: (_) => _submitEmail(),
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    hintText: 'At least 6 characters',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                ),
                const SizedBox(height: 18),
                ElevatedButton(
                  onPressed: _busy ? null : _submitEmail,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          _isRegister ? 'Register' : 'Login',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
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
                const Row(
                  children: [
                    Expanded(child: Divider()),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'or',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                    Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _busy ? null : _signInGoogle,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black87,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(color: Colors.grey),
                  ),
                  child: const Row(
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
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        backgroundColor: selected
            ? theme.colorScheme.primary
            : Colors.transparent,
        foregroundColor: selected
            ? theme.colorScheme.onPrimary
            : theme.colorScheme.onSurface,
        side: BorderSide(
          color: selected
              ? theme.colorScheme.primary
              : Colors.grey,
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    );
  }
}
