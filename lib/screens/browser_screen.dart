import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/ad_blocker.dart';

/// Callback when user taps the "Cast this page" button.
typedef OnCastUrl = void Function(String url);

class BrowserScreen extends StatefulWidget {
  final OnCastUrl onCastUrl;
  const BrowserScreen({super.key, required this.onCastUrl});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen>
    with AutomaticKeepAliveClientMixin {
  late final WebViewController _controller;
  final _urlController = TextEditingController();
  final _urlFocus = FocusNode();

  String _currentUrl = '';
  double _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;

  @override
  bool get wantKeepAlive => true; // keep WebView alive when switching tabs

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        // ── Ad blocker: block requests to known ad domains ────────────
        onNavigationRequest: (request) {
          if (AdBlocker.shouldBlock(request.url)) {
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onPageStarted: (url) {
          if (mounted) {
            setState(() {
              _currentUrl = url;
              _progress = 0;
            });
            _urlController.text = url;
          }
          // ── Ad blocker: inject CSS to hide ad containers early ──────
          _controller.runJavaScript('''
            (function(){
              var s = document.createElement('style');
              s.textContent = ${_escapeJsString(AdBlocker.cssRules)};
              (document.head || document.documentElement).appendChild(s);
            })();
          ''');
        },
        onProgress: (p) {
          if (mounted) setState(() => _progress = p / 100);
        },
        onPageFinished: (url) async {
          if (!mounted) return;
          final back = await _controller.canGoBack();
          final fwd = await _controller.canGoForward();
          setState(() {
            _currentUrl = url;
            _progress = 1;
            _canGoBack = back;
            _canGoForward = fwd;
          });
          // ── Ad blocker: inject JS to remove ad elements & overlays ─
          _controller.runJavaScript(AdBlocker.jsScript);
        },
      ))
      ..loadRequest(Uri.parse('https://www.google.com'));
    _urlController.text = 'https://www.google.com';
  }

  @override
  void dispose() {
    _urlController.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  void _navigateTo(String input) {
    var url = input.trim();
    if (url.isEmpty) return;

    // If user typed a search query instead of a URL, use Google search.
    if (!url.contains('.') || url.contains(' ')) {
      url = 'https://www.google.com/search?q=${Uri.encodeComponent(url)}';
    } else if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }

    _controller.loadRequest(Uri.parse(url));
    _urlFocus.unfocus();
  }

  /// Escapes a multi-line Dart string for safe embedding in a JS template literal.
  static String _escapeJsString(String s) {
    final escaped = s
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '');
    return "'$escaped'";
  }

  bool _isVideoUrl(String url) {
    final lower = url.toLowerCase();
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return host.contains('youtube.com') ||
        host.contains('youtu.be') ||
        lower.contains('.mp4') ||
        lower.contains('.m3u8') ||
        lower.contains('.webm') ||
        lower.contains('.mkv');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    final cs = Theme.of(context).colorScheme;
    final videoDetected = _isVideoUrl(_currentUrl);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _buildUrlBar(cs),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: 'Reload',
            onPressed: () => _controller.reload(),
          ),
        ],
        bottom: _progress < 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 2,
                ),
              )
            : null,
      ),
      body: Column(
        children: [
          Expanded(child: WebViewWidget(controller: _controller)),

          // Cast bar at bottom
          _CastBar(
            url: _currentUrl,
            videoDetected: videoDetected,
            onCast: () => widget.onCastUrl(_currentUrl),
          ),
        ],
      ),

      // Navigation row
      bottomNavigationBar: _buildNavRow(cs),
    );
  }

  Widget _buildUrlBar(ColorScheme cs) {
    return SizedBox(
      height: 38,
      child: TextField(
        controller: _urlController,
        focusNode: _urlFocus,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: 'Search or enter URL…',
          prefixIcon: const Icon(Icons.language, size: 18),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(color: cs.outlineVariant),
          ),
          filled: true,
          fillColor: cs.surfaceContainerHighest.withAlpha(100),
        ),
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.go,
        onSubmitted: _navigateTo,
        onTap: () => _urlController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _urlController.text.length,
        ),
      ),
    );
  }

  Widget _buildNavRow(ColorScheme cs) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_ios, size: 18),
              tooltip: 'Back',
              onPressed: _canGoBack ? () => _controller.goBack() : null,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward_ios, size: 18),
              tooltip: 'Forward',
              onPressed: _canGoForward ? () => _controller.goForward() : null,
            ),
            IconButton(
              icon: const Icon(Icons.home_outlined, size: 20),
              tooltip: 'Home',
              onPressed: () =>
                  _controller.loadRequest(Uri.parse('https://www.google.com')),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Cast Bar ────────────────────────────────────────────────────────────────

class _CastBar extends StatelessWidget {
  final String url;
  final bool videoDetected;
  final VoidCallback onCast;

  const _CastBar({
    required this.url,
    required this.videoDetected,
    required this.onCast,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: videoDetected
            ? cs.primaryContainer.withAlpha(200)
            : cs.surfaceContainerHighest.withAlpha(120),
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(
        children: [
          Icon(
            videoDetected ? Icons.cast : Icons.cast_outlined,
            size: 20,
            color: videoDetected ? cs.primary : cs.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              videoDetected
                  ? 'Video detected — ready to cast'
                  : 'Browse to a video page to cast it',
              style: TextStyle(
                fontSize: 12,
                color: videoDetected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
              ),
            ),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.cast, size: 16),
            label: const Text('Cast'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              textStyle: const TextStyle(fontSize: 13),
            ),
            onPressed: url.isNotEmpty ? onCast : null,
          ),
        ],
      ),
    );
  }
}
