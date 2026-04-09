import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/ad_blocker.dart';

/// Callback when user taps "Cast" on a detected video URL.
typedef OnCastUrl = void Function(String url);

// ── Quick-access bookmarks ──────────────────────────────────────────────────

class _Bookmark {
  final String label;
  final String url;
  final IconData icon;
  const _Bookmark(this.label, this.url, this.icon);
}

const _bookmarks = [
  _Bookmark('YouTube', 'https://m.youtube.com', Icons.play_circle_fill),
  _Bookmark('Vimeo', 'https://vimeo.com', Icons.video_library),
  _Bookmark('Dailymotion', 'https://www.dailymotion.com', Icons.ondemand_video),
  _Bookmark('Twitch', 'https://m.twitch.tv', Icons.live_tv),
  _Bookmark('Reddit', 'https://www.reddit.com', Icons.forum),
  _Bookmark('Twitter/X', 'https://x.com', Icons.alternate_email),
];

// ── Browser Screen ──────────────────────────────────────────────────────────

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

  /// Videos detected on the current page via JS injection.
  final List<_DetectedVideo> _detectedVideos = [];
  bool _showBookmarks = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('VideoDetector', onMessageReceived: _onVideoDetected)
      ..setNavigationDelegate(NavigationDelegate(
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
              _detectedVideos.clear();
              _showBookmarks = false;
            });
            _urlController.text = url;
          }
          // Inject CSS ad-blocker early
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
          // Inject ad blocker JS + video detection JS
          _controller.runJavaScript(AdBlocker.jsScript);
          _controller.runJavaScript(AdBlocker.videoDetectorScript);
        },
      ))
      ..loadRequest(Uri.parse('https://www.google.com'));
    _urlController.text = 'https://www.google.com';
  }

  /// Called from the VideoDetector JavaScriptChannel.
  void _onVideoDetected(JavaScriptMessage msg) {
    try {
      final data = jsonDecode(msg.message) as Map<String, dynamic>;
      final url = data['url'] as String? ?? '';
      final type = data['type'] as String? ?? '';
      if (url.isEmpty) return;
      if (_detectedVideos.any((v) => v.url == url)) return;

      if (mounted) {
        setState(() {
          _detectedVideos.add(_DetectedVideo(url: url, type: type));
        });
      }
    } catch (_) {}
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

    if (!url.contains('.') || url.contains(' ')) {
      url = 'https://www.google.com/search?q=${Uri.encodeComponent(url)}';
    } else if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }

    _controller.loadRequest(Uri.parse(url));
    _urlFocus.unfocus();
  }

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

  String _videoLabel(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;

    if (url.contains('youtube.com/embed/')) {
      final parts = uri.pathSegments;
      final idx = parts.indexOf('embed');
      if (idx >= 0 && idx + 1 < parts.length) return 'YouTube embed: ${parts[idx + 1]}';
    }
    if (url.contains('player.vimeo.com')) return 'Vimeo player';
    if (url.contains('dailymotion.com/embed')) return 'Dailymotion embed';

    final last =
        uri.pathSegments.isNotEmpty ? Uri.decodeComponent(uri.pathSegments.last) : '';
    if (last.length > 4) return last.length > 50 ? '${last.substring(0, 50)}…' : last;
    return uri.host;
  }

  void _showDetectedVideos() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.video_library, color: cs.primary),
              const SizedBox(width: 8),
              Text(
                '${_detectedVideos.length} video${_detectedVideos.length == 1 ? '' : 's'} found',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ]),
            const SizedBox(height: 12),
            ..._detectedVideos.map((v) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    v.type == 'embed' ? Icons.ondemand_video : Icons.videocam,
                    color: cs.primary,
                  ),
                  title: Text(_videoLabel(v.url),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14)),
                  subtitle: Text(v.type,
                      style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                  trailing: FilledButton.icon(
                    icon: const Icon(Icons.cast, size: 16),
                    label: const Text('Cast'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      var castUrl = v.url;
                      if (castUrl.contains('youtube.com/embed/')) {
                        final id = Uri.parse(castUrl).pathSegments.last;
                        castUrl = 'https://www.youtube.com/watch?v=$id';
                      }
                      widget.onCastUrl(castUrl);
                    },
                  ),
                )),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    final videoDetected = _isVideoUrl(_currentUrl) || _detectedVideos.isNotEmpty;

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
                child: LinearProgressIndicator(value: _progress, minHeight: 2),
              )
            : null,
      ),
      body: Column(
        children: [
          if (_showBookmarks) _buildBookmarksGrid(cs),
          Expanded(child: WebViewWidget(controller: _controller)),
          _CastBar(
            url: _currentUrl,
            videoDetected: videoDetected,
            detectedCount: _detectedVideos.length,
            onCast: () => widget.onCastUrl(_currentUrl),
            onShowDetected: _detectedVideos.isNotEmpty ? _showDetectedVideos : null,
          ),
        ],
      ),
      bottomNavigationBar: _buildNavRow(cs),
    );
  }

  Widget _buildBookmarksGrid(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: _bookmarks
            .map((b) => ActionChip(
                  avatar: Icon(b.icon, size: 16),
                  label: Text(b.label, style: const TextStyle(fontSize: 12)),
                  onPressed: () => _controller.loadRequest(Uri.parse(b.url)),
                ))
            .toList(),
      ),
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
              onPressed: () {
                setState(() => _showBookmarks = true);
                _controller.loadRequest(Uri.parse('https://www.google.com'));
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── Detected Video Model ────────────────────────────────────────────────────

class _DetectedVideo {
  final String url;
  final String type;
  const _DetectedVideo({required this.url, required this.type});
}

// ── Cast Bar ────────────────────────────────────────────────────────────────

class _CastBar extends StatelessWidget {
  final String url;
  final bool videoDetected;
  final int detectedCount;
  final VoidCallback onCast;
  final VoidCallback? onShowDetected;

  const _CastBar({
    required this.url,
    required this.videoDetected,
    required this.detectedCount,
    required this.onCast,
    this.onShowDetected,
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
              detectedCount > 0
                  ? '$detectedCount video${detectedCount == 1 ? '' : 's'} found on page'
                  : videoDetected
                      ? 'Video page — ready to cast'
                      : 'Browse to a video page to cast it',
              style: TextStyle(
                fontSize: 12,
                color: videoDetected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
              ),
            ),
          ),
          if (detectedCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: OutlinedButton.icon(
                icon: Badge.count(
                  count: detectedCount,
                  child: const Icon(Icons.video_library, size: 16),
                ),
                label: const Text('Pick'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  textStyle: const TextStyle(fontSize: 12),
                ),
                onPressed: onShowDetected,
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
