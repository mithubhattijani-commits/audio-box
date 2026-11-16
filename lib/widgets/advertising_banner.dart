import 'package:flutter/material.dart';

import 'help_whatsapp_button.dart';

/// Advertising banner (v1.0.6): the chairman's photo + a contact line
/// for anyone who wants to advertise in the app. Tapping WhatsApp
/// opens a chat with Rai Ghulam Jilani Bhatti (03090808180).
class AdvertisingBanner extends StatelessWidget {
  final String lang;

  const AdvertisingBanner({super.key, required this.lang});

  @override
  Widget build(BuildContext context) {
    final isUr = lang == 'ur';
    return Card(
      color: Colors.amber.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset(
                'assets/images/owner.jpg',
                width: 72,
                height: 96,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isUr
                        ? 'ایڈورٹائزنگ کروانے کے لیے رابطہ کریں'
                        : 'Contact us for advertising',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    HelpContact.name,
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  WhatsAppButton(lang: lang),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
