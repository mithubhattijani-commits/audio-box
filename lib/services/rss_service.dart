import 'package:http/http.dart' as http;

import '../config.dart';

/// One article from the Nigraan TV RSS feed.
class RssArticle {
  final String title;
  final String link;
  final String description;
  final String pubDate;
  final String category;

  const RssArticle({
    required this.title,
    required this.link,
    required this.description,
    required this.pubDate,
    required this.category,
  });

  /// Text read aloud by Article Listen: title + description excerpt.
  /// (Full article bodies live in the site SPA; fetching them is a
  /// follow-up — see README. The RSS excerpt is enough for a listen.)
  String get listenText =>
      description.isNotEmpty ? '$title. $description' : title;

  /// Short dek for the article list (first ~140 chars of the excerpt).
  String get dek {
    if (description.length <= 140) return description;
    return '${description.substring(0, 140)}…';
  }

  /// Human relative time ("25m ago", "3h ago", "2d ago").
  String get relativeTime => RssService.relativeTime(pubDate);
}

/// Fetches https://nigraantv.xyz/rss.xml and parses its item entries
/// with a small hand-rolled parser (no extra dependency for v1).
///
/// FEED SOURCE (verified 15 Nov 2026): the site itself declares it —
/// working-site/index.html line 13:
///   <link rel="alternate" type="application/rss+xml"
///         title="Nigraan TV News RSS"
///         href="https://nigraantv.xyz/rss.xml" />
/// and deploy/dist/rss.xml exists. Fetched live: real RSS 2.0 with
/// title/link/description/pubDate/category per item. The ticker, the
/// article list and Article Listen all read this ONE feed.
class RssService {
  static List<RssArticle>? _cached;
  static DateTime? _cachedAt;
  static const _cacheTtl = Duration(minutes: 5);

  static Future<List<RssArticle>> fetchLatest({int limit = 30}) async {
    final res = await http
        .get(Uri.parse(AppConfig.siteRssUrl))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception('RSS failed (${res.statusCode})');
    }
    return parse(res.body, limit: limit);
  }

  /// Cached fetch for widgets rebuilt often (e.g. Home's FutureBuilder):
  /// returns the in-memory list when it is under 5 minutes old, so a
  /// rebuild never re-fetches. The ticker calls [fetchLatest] directly
  /// on its own 5-minute timer.
  static Future<List<RssArticle>> fetchLatestCached({int limit = 30}) async {
    if (_cached != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheTtl) {
      return _cached!.take(limit).toList();
    }
    final fresh = await fetchLatest(limit: 30);
    _cached = fresh;
    _cachedAt = DateTime.now();
    return fresh.take(limit).toList();
  }

  static List<RssArticle> parse(String xml, {int limit = 30}) {
    final items = <RssArticle>[];
    final itemRe = RegExp(r'<item>(.*?)</item>', dotAll: true);
    for (final m in itemRe.allMatches(xml)) {
      final block = m.group(1)!;
      items.add(RssArticle(
        title: _tag(block, 'title'),
        link: _tag(block, 'link'),
        description: _clean(_tag(block, 'description')),
        pubDate: _tag(block, 'pubDate'),
        category: _tag(block, 'category'),
      ));
      if (items.length >= limit) break;
    }
    return items;
  }

  static String _tag(String block, String tag) {
    final m = RegExp(
      '<$tag(?:\\s[^>]*)?>(.*?)</$tag>',
      dotAll: true,
    ).firstMatch(block);
    if (m == null) return '';
    var v = m.group(1)!.trim();
    // CDATA: <![CDATA[ ... ]]>
    if (v.startsWith('<![CDATA[') && v.endsWith(']]>')) {
      v = v.substring(9, v.length - 3);
    }
    return v.trim();
  }

  static String _clean(String html) {
    var s = html.replaceAll(RegExp(r'<[^>]+>'), ' ');
    s = s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static const _months = {
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };

  /// "Sun, 15 Nov 2026 07:00:00 +0500" -> "25m ago" / "3h ago" / "2d ago".
  static String relativeTime(String pubDate) {
    try {
      final m = RegExp(
        r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})',
      ).firstMatch(pubDate);
      if (m == null) return '';
      final month = _months[m.group(2)!] ?? 1;
      final dt = DateTime.utc(
        int.parse(m.group(3)!),
        month,
        int.parse(m.group(1)!),
        int.parse(m.group(4)!),
        int.parse(m.group(5)!),
      );
      final diff = DateTime.now().toUtc().difference(dt);
      if (diff.inMinutes < 1) return 'just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      return '${diff.inDays}d ago';
    } catch (_) {
      return '';
    }
  }
}
