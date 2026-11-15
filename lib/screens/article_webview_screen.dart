import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/ads_service.dart';
import '../services/rss_service.dart';

/// Full article page on nigraantv.xyz, in-app.
///
/// STRATEGY (the core purpose of this app): the app funnels users to
/// website articles. This screen loads the REAL article page —
/// https://nigraantv.xyz/article/<id>/ — with JavaScript fully enabled,
/// no reader mode, no ad blocking, nothing stripped. The user sees the
/// website's own banner ads on every article and the site earns from
/// those impressions, while the user gets NOTHING (no coins) for reading.
/// A stripped reader view would defeat the whole point, so it is
/// deliberately not used here.
///
/// Links inside the page: nigraantv.xyz links stay in the WebView;
/// other hosts open in the external browser.
class ArticleWebViewScreen extends StatefulWidget {
  final RssArticle article;

  const ArticleWebViewScreen({super.key, required this.article});

  @override
  State<ArticleWebViewScreen> createState() => _ArticleWebViewScreenState();
}

class _ArticleWebViewScreenState extends State<ArticleWebViewScreen> {
  late final WebViewController _controller;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      // JavaScript MUST stay unrestricted: the site's banner ads need it.
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri != null && uri.host.endsWith('nigraantv.xyz')) {
              return NavigationDecision.navigate;
            }
            // External link (incl. ad clicks): open in the system browser.
            unawaited(_openExternal(request.url));
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.article.link));
  }

  Future<void> _openExternal(String url) async {
    try {
      final uri = Uri.parse(url);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.article.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
          IconButton(
            icon: const Icon(Icons.open_in_browser),
            onPressed: () => _openExternal(widget.article.link),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_progress < 100)
            LinearProgressIndicator(
              value: _progress / 100,
              backgroundColor: Colors.grey.shade200,
            ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
      // Passive banner, zone 'tools' (article reading surface).
      bottomNavigationBar: const UnityBannerAdWidget(zone: 'tools'),
    );
  }
}
