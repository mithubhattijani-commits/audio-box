// Paid banner slot (v1.0.10) — one of the two Home slots ('top' /
// 'bottom'). Each slot is independent: one booked does not block the
// other.
//
// States:
//   - live paid banner: the advertiser's image + remaining-time
//     countdown; tap the image to open the advertiser's contact, and
//     a small Report button files a banner_reports row.
//   - free: the owner's banner (existing AdvertisingBanner, still
//     gated by the advertising_banner remote-config switch) + an
//     "Advertise here — 200 coins" prompt that opens the booking flow.
//     When the switch is off the owner's banner hides as before and
//     only the prompt shows — the switch controls the owner's banner,
//     never paid banners.
//   - my pending / rejected booking for this slot: a compact status
//     line on the slot ("Pending review" / "Rejected — 200 coins
//     refunded" + reason when present).
//
// The slot loads on init, refreshes every 30 s (countdown) with a
// server reload every 2 minutes, and reloads when the app resumes,
// so approval/expiry show up without a restart. Expiry is by
// timestamp (ends_at > now in the query) — reverting to the owner's
// banner needs no extra code.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/coins_service.dart';
import '../services/paid_banner_service.dart';
import '../services/remote_config_service.dart';
import 'advertising_banner.dart';

class PaidBannerSlot extends StatefulWidget {
  /// 'top' or 'bottom'.
  final String slot;
  final CoinsService coins;
  final String lang;

  const PaidBannerSlot({
    super.key,
    required this.slot,
    required this.coins,
    required this.lang,
  });

  @override
  State<PaidBannerSlot> createState() => _PaidBannerSlotState();
}

class _PaidBannerSlotState extends State<PaidBannerSlot>
    with WidgetsBindingObserver {
  PaidBanner? _live;
  PaidBanner? _mine;
  bool _loading = true;
  Timer? _timer;
  int _tick = 0;

  String get _slotLabel => widget.slot == 'top' ? 'Top' : 'Bottom';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    // Countdown refresh every 30 s; full server reload every 4th tick
    // (2 minutes) so approvals and expiry appear while Home is open.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      _tick++;
      if (_tick % 4 == 0) {
        _load();
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      PaidBannerService.fetchLiveBanner(widget.slot),
      PaidBannerService.fetchMyBookings(),
    ]);
    if (!mounted) return;
    final live = results[0] as PaidBanner?;
    final mine = (results[1] as List<PaidBanner>)
        .where((b) => b.slot == widget.slot)
        .firstOrNull;
    setState(() {
      _live = live;
      _mine = mine;
      _loading = false;
    });
  }

  String _remainingLabel(DateTime endsAt) {
    final left = endsAt.difference(DateTime.now());
    if (left.isNegative) return 'Expired';
    final h = left.inHours;
    final m = left.inMinutes % 60;
    if (h > 0) return '${h}h ${m}m left';
    return '${m}m left';
  }

  Future<void> _openContact(String contact) async {
    try {
      await launchUrl(
        Uri.parse(PaidBannerService.contactUrl(contact)),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the contact link.')),
      );
    }
  }

  Future<void> _startBooking() async {
    final submitted = await showDialog<bool>(
      context: context,
      builder: (_) => _BookingDialog(
        slot: widget.slot,
        slotLabel: _slotLabel,
        coins: widget.coins,
      ),
    );
    if (submitted == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Submitted for review — you'll be notified when approved.",
          ),
        ),
      );
      await _load();
    }
  }

  Future<void> _report(PaidBanner banner) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _ReportDialog(),
    );
    if (reason == null || !mounted) return;
    try {
      await PaidBannerService.reportBanner(
        bannerId: banner.id,
        reason: reason,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Reported — the owner will review it.'),
        ),
      );
    } on PaidBannerException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final live = _live;
    final mine = _mine;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (live != null)
          _buildLiveBanner(live)
        else
          _buildFreeSlot(),
        if (mine != null && mine.isPending)
          _buildStatusLine(
            'Pending review — your ad is waiting for approval.',
            Colors.amber.shade800,
          ),
        if (mine != null && mine.isRejected)
          _buildStatusLine(
            mine.rejectReason != null && mine.rejectReason!.isNotEmpty
                ? 'Rejected — 200 coins refunded (${mine.rejectReason})'
                : 'Rejected — 200 coins refunded.',
            Colors.red.shade700,
          ),
      ],
    );
  }

  Widget _buildStatusLine(String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildLiveBanner(PaidBanner banner) {
    final endsAt = banner.endsAt;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: () => _openContact(banner.contact),
            child: Stack(
              children: [
                Image.network(
                  banner.imageUrl,
                  height: 120,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    height: 120,
                    color: Colors.grey.shade200,
                    alignment: Alignment.center,
                    child: const Icon(Icons.image_not_supported),
                  ),
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'AD',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.schedule, size: 16, color: Colors.grey),
                const SizedBox(width: 4),
                Text(
                  endsAt == null ? '' : _remainingLabel(endsAt),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                const Text(
                  '• tap the banner to contact the advertiser',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _report(banner),
                  icon: const Icon(Icons.flag_outlined, size: 16),
                  label: const Text('Report'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFreeSlot() {
    return ValueListenableBuilder<RemoteConfig>(
      valueListenable: RemoteConfigService.instance.notifier,
      builder: (context, cfg, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Owner's banner, unchanged, still gated by the
            // advertising_banner remote-config switch. Paid slots are
            // not gated by it — the prompt below always shows.
            if (cfg.advertisingBannerEnabled)
              AdvertisingBanner(lang: widget.lang),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _startBooking,
              icon: const Icon(Icons.campaign_outlined, size: 18),
              label: Text(
                'Advertise here — 200 coins · 2 hours ($_slotLabel slot)',
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Booking dialog: pick an image, enter a contact, see the summary,
/// confirm. The 200-coin charge happens only on confirm, after all
/// auto-checks pass, inside PaidBannerService.submitBooking.
class _BookingDialog extends StatefulWidget {
  final String slot;
  final String slotLabel;
  final CoinsService coins;

  const _BookingDialog({
    required this.slot,
    required this.slotLabel,
    required this.coins,
  });

  @override
  State<_BookingDialog> createState() => _BookingDialogState();
}

class _BookingDialogState extends State<_BookingDialog> {
  final _contactController = TextEditingController();
  Uint8List? _bytes;
  String? _fileName;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _contactController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    setState(() => _error = null);
    try {
      // file_picker 13.x API: FilePicker.pickFile() returns a single
      // PlatformFile (null on cancel); the old FilePicker.platform +
      // FilePickerResult API is gone in 13.x.
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      );
      if (picked == null) return;
      final Uint8List bytes;
      // Prefer the local path (Android); fall back to reading bytes
      // directly (e.g. web/blob URIs).
      if (picked.path != null) {
        bytes = await File(picked.path!).readAsBytes();
      } else {
        bytes = await picked.readAsBytes();
      }
      final error = PaidBannerService.validateImage(
        fileName: picked.name,
        sizeBytes: bytes.length,
      );
      if (error != null) {
        setState(() => _error = error);
        return;
      }
      setState(() {
        _bytes = bytes;
        _fileName = picked.name;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not pick an image — try again.');
      }
    }
  }

  Future<void> _submit() async {
    final bytes = _bytes;
    final fileName = _fileName;
    if (bytes == null || fileName == null) {
      setState(() => _error = 'Choose an image first.');
      return;
    }
    final contact = _contactController.text.trim();
    if (contact.isEmpty) {
      setState(
        () => _error = 'Enter a WhatsApp number or link for your ad.',
      );
      return;
    }
    if (PaidBannerService.checkBadWords(contact) != null) {
      setState(
        () => _error = 'That contact text is not allowed — please change it.',
      );
      return;
    }
    if (!PaidBannerService.isValidContact(contact)) {
      setState(() => _error = 'Enter a valid WhatsApp number or link.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await PaidBannerService.submitBooking(
        coins: widget.coins,
        slot: widget.slot,
        imageBytes: bytes,
        fileName: fileName,
        contact: contact,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on PaidBannerException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Something went wrong — please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cost = PaidBannerService.bookingCostCoins;
    return AlertDialog(
      title: Text('Advertise — ${widget.slotLabel} slot'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickImage,
              icon: const Icon(Icons.image_outlined),
              label: const Text('Choose image (JPG, PNG, WebP, max 5 MB)'),
            ),
            if (_fileName != null) ...[
              const SizedBox(height: 8),
              if (_bytes != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    _bytes!,
                    height: 90,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                _fileName!,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _contactController,
              enabled: !_busy,
              keyboardType: TextInputType.text,
              decoration: const InputDecoration(
                labelText: 'WhatsApp number or link',
                hintText: 'e.g. 03001234567 or https://wa.me/92300…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text('Slot: ${widget.slotLabel}'),
            const Text('Duration: 2 hours (starts when approved)'),
            Text('Cost: $cost coins'),
            ValueListenableBuilder<int>(
              valueListenable: widget.coins.balance,
              builder: (context, balance, _) {
                return Text('Your balance: $balance coins');
              },
            ),
            const SizedBox(height: 8),
            const Text(
              'Your ad goes live only after the owner approves it. '
              'If it is rejected, the 200 coins are refunded.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: (_busy || _bytes == null) ? null : _submit,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('Pay $cost coins & submit'),
        ),
      ],
    );
  }
}

/// Report dialog: an optional reason (defaults to 'inappropriate').
/// Returns the reason string, or null when cancelled.
class _ReportDialog extends StatefulWidget {
  const _ReportDialog();

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  final _reasonController = TextEditingController();

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Report this ad'),
      content: TextField(
        controller: _reasonController,
        decoration: const InputDecoration(
          labelText: 'Reason (optional)',
          hintText: 'e.g. inappropriate, misleading, spam',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final reason = _reasonController.text.trim();
            Navigator.of(context).pop(
              reason.isEmpty ? 'inappropriate' : reason,
            );
          },
          child: const Text('Report'),
        ),
      ],
    );
  }
}
