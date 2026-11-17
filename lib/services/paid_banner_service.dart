// User-paid advertising banners (v1.0.10).
//
// A user books a 2-hour slot ('top' / 'bottom') on the Home screen
// for 200 coins. The booking is stored in public.banner_ads with
// status='pending'; the 2-hour clock starts only when the owner
// approves it in the website admin panel (starts_at/ends_at are set
// there, never by the app). A rejection refunds the 200 coins
// automatically from the admin side (ledger type
// 'audiobox_banner_refund') — the app never refunds a rejection
// itself, it only shows the status the server returns.
//
// Coin flow (spend-before, same pattern as caption transcription in
// caption_service.dart):
//   auto-checks -> charge 200 -> upload image -> insert row.
// If the upload or insert fails after the charge, the 200 coins are
// refunded immediately with CoinsService.add (reason
// 'audiobox_banner_refund').
//
// No push notifications: the app polls the slot status on launch and
// while Home is visible, and expiry is by timestamp (ends_at > now)
// so a slot reverts to the owner's banner automatically.
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'coins_service.dart';
import 'supabase_service.dart';

/// Thrown by the paid-banner calls with a message safe to show the user.
class PaidBannerException implements Exception {
  /// True when the failure is because the public.banner_reports table
  /// does not exist yet (admin side still creating it). The Report
  /// button must surface this distinctly instead of pretending the
  /// report was saved.
  final bool tableMissing;

  final String message;

  const PaidBannerException(this.message, {this.tableMissing = false});

  @override
  String toString() => message;
}

/// One row of public.banner_ads.
class PaidBanner {
  final String id;
  final String slot;
  final String imageUrl;
  final String contact;
  final String status;
  final DateTime? endsAt;
  final String? rejectReason;
  final DateTime? createdAt;

  const PaidBanner({
    required this.id,
    required this.slot,
    required this.imageUrl,
    required this.contact,
    required this.status,
    required this.endsAt,
    required this.rejectReason,
    required this.createdAt,
  });

  factory PaidBanner.fromJson(Map<String, dynamic> j) {
    DateTime? parseDate(Object? v) {
      if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
      return null;
    }

    return PaidBanner(
      id: (j['id'] ?? '').toString(),
      slot: (j['slot'] ?? '').toString(),
      imageUrl: (j['image_url'] ?? '').toString(),
      contact: (j['contact'] ?? '').toString(),
      status: (j['status'] ?? '').toString(),
      endsAt: parseDate(j['ends_at']),
      rejectReason: (j['reject_reason'] as String?)?.trim().isEmpty == true
          ? null
          : j['reject_reason'] as String?,
      createdAt: parseDate(j['created_at']),
    );
  }

  bool get isPending => status == 'pending';
  bool get isRejected => status == 'rejected';
  bool get isApproved => status == 'approved';

  /// Live = approved and the 2-hour window has not ended yet.
  bool get isLive =>
      isApproved && endsAt != null && endsAt!.isAfter(DateTime.now());
}

class PaidBannerService {
  /// Coins charged for one 2-hour banner booking. Fixed by the user;
  /// do not change without his say-so.
  static const int bookingCostCoins = 200;

  /// How long a booking runs once approved (the clock starts at
  /// approval, server-side). Shown in the booking summary only.
  static const Duration bookingDuration = Duration(hours: 2);

  /// Storage bucket for banner images (public read, authenticated
  /// upload, 5 MB limit, jpeg/png/webp).
  static const String bucket = 'banner-ads';

  /// Max image size, matching the bucket limit.
  static const int maxImageBytes = 5 * 1024 * 1024;

  static const List<String> allowedExtensions = [
    'jpg',
    'jpeg',
    'png',
    'webp',
  ];

  static const Map<String, String> _contentTypes = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
  };

  // ------------------------------------------------------------------
  // Bad-words blocklist (client-side auto-check, before any charge).
  //
  // English + Urdu abuse / sexual / gambling / scam words. The check
  // runs on the contact field the user types. Single words match whole
  // tokens; entries with a space match as a phrase. This is a
  // first-line filter only — the owner still reviews every submission
  // before it goes live.
  // ------------------------------------------------------------------
  static const List<String> badWords = [
    // English profanity / sexual.
    'fuck', 'fucking', 'shit', 'bitch', 'bastard', 'whore', 'slut',
    'porn', 'porno', 'sex', 'sexy', 'xxx', 'nude', 'naked', 'dick',
    'pussy', 'cock', 'boobs', 'escort', 'callgirl', 'call girl',
    // English gambling / scam.
    'casino', 'betting', 'gamble', 'gambling', 'lottery', 'lotto',
    'bitcoin', 'crypto', 'investment', 'double your money',
    'free money', 'easy money', 'make money fast', 'viagra',
    // Roman Urdu abuse.
    'chutiya', 'chutiye', 'madarchod', 'behenchod', 'behnchod',
    'randi', 'harami', 'haramzada', 'haramzadi', 'gandu', 'gand',
    'lund', 'bakchod', 'kanjar', 'gashti', 'tatti', 'kutta', 'kuttay',
    'chut', 'lulli', 'bhosda', 'bhosdi', 'chudai', 'gandmar',
    // Urdu script abuse.
    'چوتیا', 'مادرچود', 'بہن چود', 'رنڈی', 'حرامی', 'حرامزادہ',
    'گانڈو', 'کتا', 'لنڈ', 'بکچود', 'کنجر', 'گشتی', 'چوت',
  ];

  /// Returns the matched bad word, or null when [text] is clean.
  /// Matching is case-insensitive; single words match whole tokens,
  /// phrases match as a substring.
  static String? checkBadWords(String text) {
    final normalized = text.toLowerCase();
    final tokens = normalized
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((t) => t.isNotEmpty)
        .toSet();
    for (final word in badWords) {
      if (word.contains(' ')) {
        if (normalized.contains(word)) return word;
      } else if (tokens.contains(word)) {
        return word;
      }
    }
    return null;
  }

  /// Extension of [fileName] in lower case, without the dot.
  static String extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).toLowerCase();
  }

  /// Client-side image check (format + size). Returns an error message
  /// to show the user, or null when the image is acceptable.
  static String? validateImage({
    required String fileName,
    required int sizeBytes,
  }) {
    final ext = extensionOf(fileName);
    if (!allowedExtensions.contains(ext)) {
      return 'Only JPG, PNG or WebP images are allowed.';
    }
    if (sizeBytes > maxImageBytes) {
      return 'Image is too large — max 5 MB.';
    }
    if (sizeBytes <= 0) {
      return 'That image looks empty — pick another one.';
    }
    return null;
  }

  /// True when [contact] is a usable WhatsApp number or link:
  /// at least 10 digits, or an http(s) / wa.me link.
  static bool isValidContact(String contact) {
    final trimmed = contact.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.startsWith('http://') ||
        trimmed.startsWith('https://') ||
        trimmed.contains('wa.me')) {
      return true;
    }
    final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.length >= 10;
  }

  /// Turns the advertiser's contact into a link to open: a WhatsApp
  /// number becomes a wa.me link (Pakistani 0-prefixed numbers get the
  /// 92 country code), a link is used as given.
  static String contactUrl(String contact) {
    final trimmed = contact.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    if (trimmed.contains('wa.me')) {
      return trimmed.startsWith('http') ? trimmed : 'https://$trimmed';
    }
    var digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('00')) digits = digits.substring(2);
    if (digits.startsWith('0')) digits = '92${digits.substring(1)}';
    return 'https://wa.me/$digits';
  }

  /// SHA-256 hex of the image bytes. Used both for the stored
  /// image_hash and for the duplicate check before charging.
  static String sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  /// The currently live approved banner for [slot], or null when the
  /// slot is free. Fail-soft: any error returns null so the slot
  /// falls back to the owner's banner.
  static Future<PaidBanner?> fetchLiveBanner(String slot) async {
    try {
      final client = SupabaseService.client;
      final row = await client
          .from('banner_ads')
          .select()
          .eq('slot', slot)
          .eq('status', 'approved')
          .gt('ends_at', _nowIso())
          .order('ends_at', ascending: false)
          .limit(1)
          .maybeSingle()
          .timeout(const Duration(seconds: 25));
      if (row == null) return null;
      return PaidBanner.fromJson(row);
    } catch (_) {
      return null;
    }
  }

  /// The current user's own banner_ads rows, newest first. Fail-soft:
  /// any error (or no session) returns an empty list.
  static Future<List<PaidBanner>> fetchMyBookings() async {
    try {
      final user = SupabaseService.currentUser;
      if (user == null) return const [];
      final rows = await SupabaseService.client
          .from('banner_ads')
          .select()
          .eq('user_id', user.id)
          .order('created_at', ascending: false)
          .limit(10)
          .timeout(const Duration(seconds: 25)) as List;
      return rows
          .whereType<Map<String, dynamic>>()
          .map(PaidBanner.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// True when an identical image (same SHA-256) is already pending or
  /// approved — spam protection, checked BEFORE charging. Fail-soft on
  /// error: returns false so a network blip never blocks a booking
  /// (the owner review still catches real duplicates).
  static Future<bool> isDuplicateImage(String imageHash) async {
    try {
      final row = await SupabaseService.client
          .from('banner_ads')
          .select('id')
          .eq('image_hash', imageHash)
          .inFilter('status', const ['pending', 'approved'])
          .limit(1)
          .maybeSingle()
          .timeout(const Duration(seconds: 25));
      return row != null;
    } catch (_) {
      return false;
    }
  }

  /// Full booking flow. Order is fixed:
  ///   1. auto-checks (image, contact, bad words, duplicate) — no charge
  ///   2. charge 200 coins (spend-before)
  ///   3. upload the image to the 'banner-ads' bucket
  ///   4. insert the banner_ads row as status='pending'
  /// If step 3 or 4 fails after the charge, the 200 coins are refunded
  /// immediately via CoinsService.add and the error is rethrown.
  /// Throws [PaidBannerException] with a user-facing message.
  static Future<PaidBanner> submitBooking({
    required CoinsService coins,
    required String slot,
    required Uint8List imageBytes,
    required String fileName,
    required String contact,
  }) async {
    // 1. Auto-checks — nothing is charged for a rejected submission.
    final imageError =
        validateImage(fileName: fileName, sizeBytes: imageBytes.length);
    if (imageError != null) throw PaidBannerException(imageError);
    final cleanContact = contact.trim();
    if (cleanContact.isEmpty) {
      throw const PaidBannerException(
        'Enter a WhatsApp number or link so people can contact you.',
      );
    }
    if (!isValidContact(cleanContact)) {
      throw const PaidBannerException(
        'Enter a valid WhatsApp number or link.',
      );
    }
    final badWord = checkBadWords(cleanContact);
    if (badWord != null) {
      throw const PaidBannerException(
        'That contact text is not allowed — please change it.',
      );
    }
    final user = SupabaseService.currentUser;
    if (user == null) {
      throw const PaidBannerException(
        'Please sign in first to book a banner.',
      );
    }
    final imageHash = sha256Hex(imageBytes);
    if (await isDuplicateImage(imageHash)) {
      throw const PaidBannerException(
        'This image was already submitted — please use a different image.',
      );
    }

    // 2. Charge 200 coins first (spend-before).
    if (!coins.canAfford(bookingCostCoins)) {
      throw const PaidBannerException(
        'Not enough coins — watch ads or claim your daily coins.',
      );
    }
    final spent = await coins.spend(
      bookingCostCoins,
      reason: 'audiobox_banner_booking',
    );
    if (!spent) {
      throw const PaidBannerException(
        'Not enough coins — watch ads or claim your daily coins.',
      );
    }

    // 3 + 4. Upload, then insert. Any failure here refunds the charge.
    try {
      final ext = extensionOf(fileName);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final path = '${user.id}/${slot}_$stamp.$ext';
      final client = SupabaseService.client;
      await client.storage
          .from(bucket)
          .uploadBinary(
            path,
            imageBytes,
            fileOptions: FileOptions(
              contentType: _contentTypes[ext] ?? 'image/jpeg',
              upsert: false,
            ),
          )
          .timeout(const Duration(seconds: 30));
      final imageUrl = client.storage.from(bucket).getPublicUrl(path);
      final inserted = await client
          .from('banner_ads')
          .insert({
            'slot': slot,
            'user_id': user.id,
            'image_url': imageUrl,
            'contact': cleanContact,
            'status': 'pending',
            'image_hash': imageHash,
            // starts_at / ends_at stay NULL — the 2-hour clock starts
            // at approval, set by the owner in the admin panel.
          })
          .select()
          .single()
          .timeout(const Duration(seconds: 25));
      return PaidBanner.fromJson(inserted);
    } catch (e) {
      // Upload or insert failed after the charge: refund in full.
      await coins.add(bookingCostCoins, reason: 'audiobox_banner_refund');
      if (e is PaidBannerException) rethrow;
      throw PaidBannerException(
        'Booking failed (${_shortError(e)}) — your 200 coins were refunded.',
      );
    }
  }

  /// Insert a row in public.banner_reports for [bannerId].
  /// [reason] is optional; defaults to 'inappropriate'. Throws
  /// [PaidBannerException] (with tableMissing=true when the table
  /// does not exist yet) — callers must NOT pretend the report was
  /// saved when this throws.
  static Future<void> reportBanner({
    required String bannerId,
    String reason = 'inappropriate',
  }) async {
    final user = SupabaseService.currentUser;
    if (user == null) {
      throw const PaidBannerException('Please sign in first to report.');
    }
    try {
      await SupabaseService.client
          .from('banner_reports')
          .insert({
            'banner_id': bannerId,
            'reporter_user_id': user.id,
            'reason': reason.trim().isEmpty ? 'inappropriate' : reason.trim(),
          })
          .timeout(const Duration(seconds: 25));
    } on PostgrestException catch (e) {
      // 42P01 = undefined_table: the admin agent is still creating
      // public.banner_reports. Surface it clearly; never claim the
      // report was noted locally.
      if (e.code == '42P01' || e.message.contains('does not exist')) {
        throw const PaidBannerException(
          'Reporting is still being set up — please try again later.',
          tableMissing: true,
        );
      }
      throw PaidBannerException(
        'Could not send the report (${_shortError(e)}).',
      );
    } catch (e) {
      throw PaidBannerException(
        'Could not send the report (${_shortError(e)}).',
      );
    }
  }

  static String _shortError(Object e) {
    final text = e.toString();
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }
}
