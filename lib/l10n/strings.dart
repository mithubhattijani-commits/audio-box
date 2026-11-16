import 'package:flutter/material.dart';

/// Minimal EN/UR strings (default English, Urdu second — same as
/// nigraantv.xyz). v1 keeps this hand-rolled instead of gen_l10n so the
/// scaffold compiles with zero codegen steps.
class AppStrings {
  static const Map<String, Map<String, String>> _values = {
    'app_name': {
      'en': 'Magic Box From Jaani',
      'ur': 'میجک باکس — جانی',
    },
    'home': {'en': 'Home', 'ur': 'ہوم'},
    'tts_studio': {'en': 'TTS Studio', 'ur': 'ٹی ٹی ایس اسٹوڈیو'},
    'coins': {'en': 'Coins', 'ur': 'کوائنز'},
    'my_audio': {'en': 'My Audio', 'ur': 'میری آڈیو'},
    'tools': {'en': 'Audio Tools', 'ur': 'آڈیو ٹولز'},
    'article_listen': {'en': 'Article Listen', 'ur': 'خبر سنیں'},
    'news_briefing': {'en': 'News Briefing', 'ur': 'نیوز بریفنگ'},
    'speech_writer': {'en': 'Speech Writer', 'ur': 'تقریر لکھیں'},
    'mp3_converter': {'en': 'MP3 Converter', 'ur': 'ایم پی تھری کنورٹر'},
    'caption_generator': {
      'en': 'AI Caption Generator',
      'ur': 'اے آئی کیپشن جنریٹر',
    },
    'caption_translation': {
      'en': 'Caption Translation',
      'ur': 'کیپشن ترجمہ',
    },
    'audio_trimmer': {
      'en': 'Audio Trimmer + Joiner',
      'ur': 'آڈیو ٹرمر + جوائنر',
    },
    'video_caption_maker': {
      'en': 'Video Caption Maker (AI)',
      'ur': 'ویڈیو کیپشن میکر (اے آئی)',
    },
    'not_enough_coins_captions': {
      'en':
          'Not enough coins — open the Coins tab and watch ads to earn more.',
      'ur':
          'کوائنز کم ہیں — کوائنز ٹیب کھولیں اور اشتہار دیکھ کر مزید کمائیں۔',
    },
    'type_text': {
      'en': 'Type or paste your text here…',
      'ur': 'یہاں اپنا متن لکھیں یا پیسٹ کریں…',
    },
    'voice': {'en': 'Voice', 'ur': 'آواز'},
    'language': {'en': 'Language', 'ur': 'زبان'},
    'generate_audio': {'en': 'Generate Audio (50 coins)', 'ur': 'آڈیو بنائیں (50 کوائنز)'},
    'not_enough_coins': {
      'en': 'Not enough coins — watch ads or claim your daily coins.',
      'ur': 'کوائنز کم ہیں — اشتہار دیکھیں یا روزانہ کوائنز لیں۔',
    },
    'daily_coins': {'en': 'Claim daily 100 free coins', 'ur': 'روزانہ 100 مفت کوائنز لیں'},
    'daily_claimed': {
      'en': 'Daily coins already claimed — come back tomorrow.',
      'ur': 'آج کے کوائنز مل چکے ہیں — کل پھر آئیں۔',
    },
    'watch_ads': {'en': 'Watch 2 ads — get 50 coins', 'ur': '2 اشتہار دیکھیں — 50 کوائنز پائیں'},
    'balance': {'en': 'Balance', 'ur': 'بیلنس'},
    'play': {'en': 'Play', 'ur': 'چلائیں'},
    'download': {'en': 'Download', 'ur': 'ڈاؤن لوڈ'},
    'share': {'en': 'Share', 'ur': 'شیئر کریں'},
    'delete': {'en': 'Delete', 'ur': 'حذف کریں'},
    'convert_mp3': {'en': 'Convert to MP3', 'ur': 'ایم پی تھری میں بدلیں'},
    'no_audio_yet': {
      'en': 'No audio yet — generate your first one in TTS Studio.',
      'ur': 'ابھی کوئی آڈیو نہیں — ٹی ٹی ایس اسٹوڈیو میں پہلی آڈیو بنائیں۔',
    },
    'generating': {'en': 'Making audio…', 'ur': 'آواز بن رہی ہے…'},
    'ads_not_ready': {
      'en': 'Ads are not ready yet — please try again in a moment.',
      'ur': 'اشتہار ابھی تیار نہیں — تھوڑی دیر بعد دوبارہ کوشش کریں۔',
    },
    'watch_both_ads': {
      'en': 'Please watch both ads fully to earn 50 coins.',
      'ur': '50 کوائنز کے لیے دونوں اشتہار مکمل دیکھیں۔',
    },
    'coins_earned': {'en': 'You earned 50 coins!', 'ur': 'آپ کو 50 کوائنز ملے!'},
    'local_only': {
      'en': 'Local-only mode — coins are stored on this device.',
      'ur': 'لوکل موڈ — کوائنز اسی ڈیوائس پر محفوظ ہیں۔',
    },
    'latest_articles': {'en': 'Latest News', 'ur': 'تازہ ترین خبریں'},
    'read_on_website': {
      'en': 'Read on nigraantv.xyz — free, no coins needed.',
      'ur': 'nigraantv.xyz پر پڑھیں — مفت، کوائنز نہیں چاہییں۔',
    },
    'check_updates': {'en': 'Check for updates', 'ur': 'اپ ڈیٹ چیک کریں'},
    'listen_free_note': {
      'en': 'Listening uses audio generation and costs coins, like TTS Studio. Reading is free.',
      'ur': 'سننے پر آڈیو بنتی ہے اور کوائنز لگتے ہیں، جیسے ٹی ٹی ایس اسٹوڈیو میں۔ پڑھنا مفت ہے۔',
    },
    'daily_cap_reached': {
      'en': 'Daily generation limit reached — come back tomorrow.',
      'ur': 'آج کی حد مکمل ہو گئی — کل پھر آئیں۔',
    },
    'fallback_used': {
      'en': 'Gemini was busy — generated with a free Edge voice instead.',
      'ur': 'جیمنائی مصروف تھا — مفت ایج آواز سے بنا دیا گیا۔',
    },
    'speech_topic': {'en': 'Speech topic', 'ur': 'تقریر کا موضوع'},
    'write_speech': {'en': 'Write Speech', 'ur': 'تقریر لکھیں'},
    'send_to_tts': {'en': 'Send to TTS Studio', 'ur': 'ٹی ٹی ایس اسٹوڈیو میں بھیجیں'},
    'briefing_note': {
      'en': 'Hourly news briefing from Nigraan TV — free to listen.',
      'ur': 'نگران ٹی وی کی ہر گھنٹے کی نیوز بریفنگ — سننا مفت ہے۔',
    },
  };

  static String tr(String key, Locale locale) {
    final map = _values[key];
    if (map == null) return key;
    return map[locale.languageCode] ?? map['en'] ?? key;
  }
}
