import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// WhatsApp help contact — Rai Ghulam Jilani Bhatti, 03090808180.
/// Shown at the very end of the caption tools + home screen so any
/// user who needs a guideline can reach him directly on WhatsApp.
class HelpContact {
  static const String name = 'Rai Ghulam Jilani Bhatti';
  static const String numberDisplay = '03090808180';

  /// wa.me link (Pakistan code 92, leading 0 dropped).
  static const String whatsappUrl = 'https://wa.me/923090808180';

  static Future<void> openWhatsApp(BuildContext context) async {
    try {
      await launchUrl(
        Uri.parse(whatsappUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open WhatsApp.')),
      );
    }
  }
}

/// Green WhatsApp button (labelled "WhatsApp").
class WhatsAppButton extends StatelessWidget {
  final String lang;

  const WhatsAppButton({super.key, required this.lang});

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF25D366),
        foregroundColor: Colors.white,
      ),
      onPressed: () => HelpContact.openWhatsApp(context),
      icon: const Icon(Icons.chat, size: 18),
      label: const Text('WhatsApp'),
    );
  }
}

/// "For Help" row — placed at the very END of a screen, under all
/// other content: a guideline line, the contact name, WhatsApp button.
class HelpWhatsAppRow extends StatelessWidget {
  final String lang;

  const HelpWhatsAppRow({super.key, required this.lang});

  @override
  Widget build(BuildContext context) {
    final isUr = lang == 'ur';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        const SizedBox(height: 8),
        Text(
          isUr
              ? 'مدد کے لیے — کوئی بھی گائیڈ لائن چاہیے تو واٹس ایپ کریں'
              : 'For Help — need any guideline? Message us on WhatsApp',
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          HelpContact.name,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Center(child: WhatsAppButton(lang: lang)),
      ],
    );
  }
}
