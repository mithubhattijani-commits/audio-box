import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Email + password login / register (v1.0.4) — the same auth TJ Earn
/// had: an account with an email and a password, so coins survive
/// reinstalls without needing Google.
///
/// REGISTER: when the current Supabase user is anonymous (fresh
/// install / v1.0.2 upgrade), the email is attached to THAT user with
/// updateUser, so the same user.id (and coins) survives. When there
/// is no session at all, signUp creates the account directly. When
/// the email is already registered, the flow falls back to signing
/// into that account with the given password (same "already
/// registered" message Supabase returns) — so a returning user who
/// taps Register by mistake still gets in.
///
/// LOGIN: signInWithPassword into the existing email account. Coins
/// then belong to that account; any coins on the anonymous session of
/// this device do not move over (same trade-off as the Google
/// fallback in GoogleAuthService).
///
/// "Confirm email" is OFF in this project (verified 15 Nov 2026:
/// signUp returns a session immediately), so registration signs the
/// user in at once — no confirmation email, no deep link.
class EmailAuthService {
  /// Login with an existing email account. Never throws; the result
  /// carries a user-facing error message on failure.
  static Future<EmailAuthResult> signInWithEmail({
    required String email,
    required String password,
  }) async {
    if (!SupabaseService.isInitialized) {
      await SupabaseService.init();
    }
    try {
      await SupabaseService.signInWithPassword(
        email: email,
        password: password,
      );
    } on AuthException catch (e) {
      return EmailAuthResult(ok: false, error: _friendlyError(e.message));
    } on TimeoutException {
      return const EmailAuthResult(
        ok: false,
        error: 'Request timed out. Check your connection and try again.',
      );
    } catch (e) {
      return EmailAuthResult(
        ok: false,
        error: 'Could not sign in ($e). Please try again.',
      );
    }
    final user = SupabaseService.currentUser;
    if (user == null || user.isAnonymous) {
      return const EmailAuthResult(
        ok: false,
        error: 'Sign-in did not create a session. Please try again.',
      );
    }
    return const EmailAuthResult(ok: true);
  }

  /// Register a new email account. Never throws; the result carries a
  /// user-facing error message on failure.
  static Future<EmailAuthResult> registerWithEmail({
    required String email,
    required String password,
  }) async {
    if (!SupabaseService.isInitialized) {
      await SupabaseService.init();
    }

    final current = SupabaseService.currentUser;

    // Anonymous user present: attach the email to THAT user so its
    // user.id (and coins) survives. Already-registered email falls
    // through to signing into that account.
    if (current != null && current.isAnonymous) {
      try {
        await SupabaseService.convertAnonymousToEmail(
          email: email,
          password: password,
        );
      } on AuthException catch (e) {
        if (_isAlreadyRegistered(e.message)) {
          return signInWithEmail(email: email, password: password);
        }
        return EmailAuthResult(ok: false, error: _friendlyError(e.message));
      } on TimeoutException {
        return const EmailAuthResult(
          ok: false,
          error: 'Request timed out. Check your connection and try again.',
        );
      } catch (e) {
        return EmailAuthResult(
          ok: false,
          error: 'Could not register ($e). Please try again.',
        );
      }
      final user = SupabaseService.currentUser;
      if (user == null || user.isAnonymous) {
        return const EmailAuthResult(
          ok: false,
          error: 'Registration did not complete. Please try again.',
        );
      }
      return const EmailAuthResult(ok: true, registeredNew: true);
    }

    // No session at all: create the account directly.
    try {
      await SupabaseService.signUpWithEmail(email: email, password: password);
    } on AuthException catch (e) {
      if (_isAlreadyRegistered(e.message)) {
        return signInWithEmail(email: email, password: password);
      }
      return EmailAuthResult(ok: false, error: _friendlyError(e.message));
    } on TimeoutException {
      return const EmailAuthResult(
        ok: false,
        error: 'Request timed out. Check your connection and try again.',
      );
    } catch (e) {
      return EmailAuthResult(
        ok: false,
        error: 'Could not register ($e). Please try again.',
      );
    }
    var user = SupabaseService.currentUser;
    if (user == null || user.isAnonymous) {
      // signUp returned no session (e.g. the email was already
      // registered but GoTrue masked it): try signing in with the
      // same credentials instead of leaving the user stuck.
      return signInWithEmail(email: email, password: password);
    }
    return const EmailAuthResult(ok: true, registeredNew: true);
  }

  static bool _isAlreadyRegistered(String message) {
    final msg = message.toLowerCase();
    return msg.contains('already') &&
        (msg.contains('register') || msg.contains('exists'));
  }

  static String _friendlyError(String message) {
    final msg = message.toLowerCase();
    if (msg.contains('invalid login credentials') ||
        msg.contains('invalid email or password')) {
      return 'Wrong email or password. Please try again.';
    }
    if (msg.contains('password') &&
        (msg.contains('short') ||
            msg.contains('at least 6') ||
            msg.contains('characters'))) {
      return 'Password must be at least 6 characters.';
    }
    if (msg.contains('invalid') && msg.contains('email')) {
      return 'Please enter a valid email address.';
    }
    if (msg.contains('already') && msg.contains('register')) {
      return 'This email is already registered. Try logging in instead.';
    }
    if (msg.contains('too many') || msg.contains('rate limit')) {
      return 'Too many attempts. Please wait a bit and try again.';
    }
    return 'Could not complete this ($message). Please try again.';
  }
}

/// Outcome of [EmailAuthService.signInWithEmail] /
/// [EmailAuthService.registerWithEmail].
class EmailAuthResult {
  const EmailAuthResult({required this.ok, this.error, this.registeredNew = false});

  /// True when a non-anonymous Supabase session now exists.
  final bool ok;

  /// User-facing failure message (null when [ok] is true).
  final String? error;

  /// True when a brand-new account was just registered (as opposed to
  /// signing into an existing one).
  final bool registeredNew;
}
