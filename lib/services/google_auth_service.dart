import 'dart:async';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import 'supabase_service.dart';

/// Google sign-in (v1.0.3): coins are tied to a real Google account.
///
/// WHY: v1.0.2 used anonymous Supabase sign-in. Coins are keyed to the
/// anonymous `user.id`, which lives only in the on-device session — an
/// uninstall / clear-data created a new anonymous user and a fresh 100
/// daily coins. A Google-linked account survives reinstalls, so the
/// same `user.id` (and coins) come back.
///
/// NATIVE FLOW ONLY: `google_sign_in` (v7 singleton) -> `idToken` (+ an
/// `accessToken` for the `email` scope, best-effort) -> Supabase
/// `signInWithIdToken` / `linkIdentityWithIdToken`. No web OAuth
/// redirect, no deep-link scheme, no `google-services.json` (the Web
/// client ID is passed as `serverClientId` — see [AppConfig]).
///
/// LINK-FIRST: when the current Supabase user is anonymous (the
/// v1.0.2 upgrade path, or a fresh install that just created an
/// anonymous session as the pre-link step), the Google identity is
/// linked onto that SAME user with `linkIdentityWithIdToken`, so the
/// `user.id` and its coins are preserved. `linkIdentityWithIdToken`
/// exists in the resolved supabase_flutter 2.x (verified present in
/// the 2.18.3 API docs; pubspec `^2.9.0` resolves to latest 2.x).
/// It needs "Enable Manual Linking" turned on in the Supabase
/// dashboard (Auth -> Providers) — without it the link call fails.
///
/// FALLBACK: if linking fails because this Google account already owns
/// a different Supabase user (e.g. reinstall after a previous Google
/// sign-in), plain `signInWithIdToken` signs into THAT user instead.
/// Coins then belong to the Google account's user, not to the old
/// anonymous one. Any other link failure is reported, not silently
/// converted into a fresh account — coins must never silently restart.
class GoogleAuthService {
  static bool _googleInitialized = false;

  /// True once the Web OAuth client ID has been supplied (see
  /// [AppConfig.googleServerClientId]). False until the browser task
  /// creates the Google Cloud OAuth clients and the value is pasted in.
  static bool get isConfigured =>
      AppConfig.googleServerClientId.isNotEmpty &&
      AppConfig.googleServerClientId !=
          'REPLACE_ME_GOOGLE_WEB_CLIENT_ID';

  /// True when the current Supabase session belongs to a Google-linked
  /// (non-anonymous) user — the only session allowed past the login
  /// gate. Anonymous sessions and "no session" both return false.
  static bool get isSignedIn => SupabaseService.hasGoogleSession;

  /// One-time GoogleSignIn setup + silent restore of a previous Google
  /// account. Best-effort, never throws: false means Google sign-in is
  /// unavailable right now (not configured, or no Play Services).
  /// The Supabase session — not the Google account — is the source of
  /// truth for the login gate; this only pre-warms the Google side.
  static Future<bool> ensureInitialized() async {
    if (_googleInitialized) return true;
    if (!isConfigured) return false;
    try {
      await GoogleSignIn.instance.initialize(
        serverClientId: AppConfig.googleServerClientId,
      );
      _googleInitialized = true;
      try {
        // Silent restore of the previously chosen Google account.
        // Its result is intentionally ignored: the Supabase session
        // decides the gate, and a tap re-authenticates if needed.
        await GoogleSignIn.instance
            .attemptLightweightAuthentication()
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        // No previous Google account (or offline) — the sign-in
        // button still works.
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Full interactive Google sign-in (called from the login button, so
  /// it runs inside a user gesture). Never throws; the result carries
  /// a user-facing error message on failure. On failure the caller
  /// stays on the login screen — never a crash, never a silent
  /// fallback to anonymous for coins.
  static Future<GoogleSignInResult> signInWithGoogle() async {
    if (!isConfigured) {
      return const GoogleSignInResult(
        ok: false,
        error:
            'Google sign-in is not set up yet. Please update the app when a new version is available.',
      );
    }
    if (!await ensureInitialized()) {
      return const GoogleSignInResult(
        ok: false,
        error:
            'Could not start Google sign-in. Check your connection and that Google Play Services is available, then try again.',
      );
    }

    // A first launch that started offline never initialized Supabase:
    // retry now that the user is interacting (and likely online).
    if (!SupabaseService.isInitialized) {
      await SupabaseService.init();
    }

    GoogleSignInAccount account;
    try {
      // Interactive native sign-in (account chooser / Credential
      // Manager). Throws GoogleSignInException on cancel or error.
      account = await GoogleSignIn.instance.authenticate().timeout(
            const Duration(seconds: 120),
          );
    } on TimeoutException {
      return const GoogleSignInResult(
        ok: false,
        error: 'Google sign-in timed out. Please try again.',
      );
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('canceled') || msg.contains('cancelled')) {
        return const GoogleSignInResult(
          ok: false,
          error: 'Sign-in was cancelled. Tap "Sign in with Google" to try again.',
        );
      }
      return GoogleSignInResult(
        ok: false,
        error: 'Google sign-in failed ($e). Please try again.',
      );
    }

    // ID token: the credential Supabase verifies. Null means the Web
    // OAuth client ID is missing/wrong — nothing else can proceed.
    String? idToken;
    try {
      final googleAuth = await account.authentication;
      idToken = googleAuth.idToken;
    } catch (_) {
      idToken = null;
    }
    if (idToken == null || idToken.isEmpty) {
      return const GoogleSignInResult(
        ok: false,
        error:
            'Google did not return an ID token. The app\'s Google setup is incomplete — please try again later.',
      );
    }

    // Access token (email scope): optional for signInWithIdToken /
    // linkIdentityWithIdToken, so a failure here is non-fatal — the
    // ID token alone is enough to sign in.
    final String? accessToken = await _fetchAccessToken(account);

    final current = SupabaseService.currentUser;

    // Already Google-linked (e.g. restored session): nothing to do.
    if (current != null && !current.isAnonymous) {
      return const GoogleSignInResult(ok: true);
    }

    // Anonymous user present (v1.0.2 upgrade, or the pre-link step
    // below): link Google onto the SAME user so user.id + coins live on.
    if (current != null && current.isAnonymous) {
      final linked = await _tryLink(idToken, accessToken);
      if (linked.ok) return const GoogleSignInResult(ok: true, linkedExisting: true);
      if (linked.alreadyLinkedElsewhere) {
        // This Google account already owns a Supabase user: sign into
        // THAT user (its coins) instead of the anonymous one.
        return _signInWithIdToken(idToken, accessToken);
      }
      return GoogleSignInResult(ok: false, error: linked.error);
    }

    // No Supabase user at all (fresh install): create the anonymous
    // session first, then link — same UID either way. If anonymous
    // creation fails (offline / not enabled), fall through to a plain
    // Google sign-in so the user is not blocked.
    final anonReady = await SupabaseService.ensureAnonymousSession();
    if (anonReady) {
      final linked = await _tryLink(idToken, accessToken);
      if (linked.ok) return const GoogleSignInResult(ok: true, linkedExisting: true);
      if (linked.alreadyLinkedElsewhere) {
        return _signInWithIdToken(idToken, accessToken);
      }
      return GoogleSignInResult(ok: false, error: linked.error);
    }
    return _signInWithIdToken(idToken, accessToken);
  }

  /// Plain Google sign-in (new Google-owned user). Returns ok only
  /// when the resulting Supabase user is non-anonymous.
  static Future<GoogleSignInResult> _signInWithIdToken(
    String idToken,
    String? accessToken,
  ) async {
    try {
      await SupabaseService.signInWithGoogleIdToken(
        idToken: idToken,
        accessToken: accessToken,
      );
    } catch (e) {
      return GoogleSignInResult(
        ok: false,
        error: 'Could not sign in with Google ($e). Please try again.',
      );
    }
    final user = SupabaseService.currentUser;
    if (user == null || user.isAnonymous) {
      return const GoogleSignInResult(
        ok: false,
        error: 'Google sign-in did not create a session. Please try again.',
      );
    }
    return const GoogleSignInResult(ok: true, freshGoogleUser: true);
  }

  /// Link the Google identity onto the current (anonymous) user.
  static Future<_LinkResult> _tryLink(
    String idToken,
    String? accessToken,
  ) async {
    try {
      await SupabaseService.linkGoogleIdentity(
        idToken: idToken,
        accessToken: accessToken,
      );
    } on AuthException catch (e) {
      final msg = e.message.toLowerCase();
      if (msg.contains('already') && msg.contains('link')) {
        return const _LinkResult(
          ok: false,
          alreadyLinkedElsewhere: true,
        );
      }
      return _LinkResult(
        ok: false,
        error:
            'Could not link your Google account to this app account (${e.message}). '
            'Your coins are safe on this device — please try again later.',
      );
    } catch (e) {
      return _LinkResult(
        ok: false,
        error: 'Could not link your Google account ($e). Please try again.',
      );
    }
    final user = SupabaseService.currentUser;
    if (user == null || user.isAnonymous) {
      return const _LinkResult(
        ok: false,
        error:
            'Linking did not complete. Your coins are safe on this device — please try again.',
      );
    }
    return const _LinkResult(ok: true);
  }

  /// Best-effort access token for the `email` scope. Returns null on
  /// any failure — the ID token alone is enough to sign in.
  static Future<String?> _fetchAccessToken(
    GoogleSignInAccount account,
  ) async {
    try {
      const scopes = ['email'];
      final existing = await account.authorizationClient
          .authorizationForScopes(scopes)
          .timeout(const Duration(seconds: 15));
      if (existing != null) return existing.accessToken;
      final fresh = await account.authorizationClient
          .authorizeScopes(scopes)
          .timeout(const Duration(seconds: 60));
      return fresh.accessToken;
    } catch (_) {
      return null;
    }
  }
}

/// Outcome of [GoogleAuthService.signInWithGoogle].
class GoogleSignInResult {
  const GoogleSignInResult({
    required this.ok,
    this.error,
    this.linkedExisting = false,
    this.freshGoogleUser = false,
  });

  /// True when a Google-linked Supabase session now exists.
  final bool ok;

  /// User-facing failure message (null when [ok] is true).
  final String? error;

  /// True when an existing anonymous user.id (and its coins) was
  /// preserved by linking Google onto it.
  final bool linkedExisting;

  /// True when the session belongs to a Google-owned user created /
  /// signed into directly (no anonymous user was linked). Coins then
  /// belong to the Google account, not to any previous anonymous user.
  final bool freshGoogleUser;
}

class _LinkResult {
  const _LinkResult({
    required this.ok,
    this.error,
    this.alreadyLinkedElsewhere = false,
  });

  final bool ok;
  final String? error;
  final bool alreadyLinkedElsewhere;
}
