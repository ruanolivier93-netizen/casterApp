import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/ad_blocker.dart';
import '../providers/bookmarks_history.dart';
import '../providers/app_state.dart';

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

// ── Detected Video ──────────────────────────────────────────────────────────

class _DetectedVideo {
  final String url;
  final String type; // 'video', 'source', 'xhr', 'fetch', 'resource', 'embed', 'link', 'meta', etc.
  const _DetectedVideo({required this.url, required this.type});

  /// Priority — lower is better. Direct streams > meta > embeds > links.
  int get priority {
    switch (type) {
      case 'video':
      case 'source':
        return 0;
      case 'xhr':
      case 'fetch':
      case 'resource':
        return 1;
      case 'meta':
      case 'json-ld':
      case 'data-attr':
        return 2;
      case 'embed':
        return 3;
      case 'link':
        return 4;
      default:
        return 5;
    }
  }
}

// ── Browser Screen ──────────────────────────────────────────────────────────

class BrowserScreen extends ConsumerStatefulWidget {
  final OnCastUrl onCastUrl;
  final ValueChanged<WebViewController>? onControllerCreated;
  const BrowserScreen({super.key, required this.onCastUrl, this.onControllerCreated});

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen>
    with AutomaticKeepAliveClientMixin {
  late final WebViewController _controller;
  final _urlController = TextEditingController();
  final _urlFocus = FocusNode();

  String _currentUrl = '';
  double _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;

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
          // Inject CSS ad-blocker + network interceptor EARLY.
          _controller.runJavaScript('''
            (function(){
              var s = document.createElement('style');
              s.textContent = ${_escapeJsString(AdBlocker.cssRules)};
              (document.head || document.documentElement).appendChild(s);
            })();
          ''');
          _controller.runJavaScript(AdBlocker.videoDetectorScript);
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
          _controller.runJavaScript(AdBlocker.jsScript);
          _controller.runJavaScript(AdBlocker.videoDetectorScript);
          // Record in browsing history
          final title = await _controller.getTitle() ?? url;
          ref.read(historyProvider.notifier).add(url, title);
        },
      ))
      ..loadRequest(Uri.parse('https://www.google.com'));
    widget.onControllerCreated?.call(_controller);
    _urlController.text = 'https://www.google.com';
  }

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

  bool _isPlatformUrl(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return host.contains('youtube.com') ||
        host.contains('youtu.be') ||
        host.contains('m.youtube.com');
  }

  String _normalizeForCast(String url) {
    if (url.contains('youtube.com/embed/')) {
      final uri = Uri.tryParse(url);
      if (uri != null) {
        final parts = uri.pathSegments;
        final idx = parts.indexOf('embed');
        if (idx >= 0 && idx + 1 < parts.length) {
          return 'https://www.youtube.com/watch?v=${parts[idx + 1]}';
        }
      }
    }
    if (url.contains('youtube.com/shorts/')) {
      final uri = Uri.tryParse(url);
      if (uri != null && uri.pathSegments.length >= 2) {
        return 'https://www.youtube.com/watch?v=${uri.pathSegments[1]}';
      }
    }
    if (url.contains('player.vimeo.com/video/')) {
      final uri = Uri.tryParse(url);
      if (uri != null && uri.pathSegments.length >= 2) {
        return 'https://vimeo.com/${uri.pathSegments.last}';
      }
    }
    if (url.contains('dailymotion.com/embed/video/')) {
      final uri = Uri.tryParse(url);
      if (uri != null && uri.pathSegments.isNotEmpty) {
        return 'https://www.dailymotion.com/video/${uri.pathSegments.last}';
      }
    }
    return url;
  }

  String _videoLabel(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final host = uri.host.toLowerCase();
    if (host.contains('youtube.com') || host.contains('youtu.be')) return 'YouTube video';
    if (host.contains('vimeo.com')) return 'Vimeo video';
    if (host.contains('dailymotion.com') || host.contains('dai.ly')) return 'Dailymotion video';
    if (host.contains('twitch.tv')) return 'Twitch stream';
    if (host.contains('facebook.com')) return 'Facebook video';
    final last = uri.pathSegments.isNotEmpty
        ? Uri.decodeComponent(uri.pathSegments.last.split('?').first)
        : '';
    if (last.length > 4) return last.length > 50 ? '${last.substring(0, 50)}…' : last;
    return host.isNotEmpty ? host : url;
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'video':
      case 'source':
        return 'Direct stream';
      case 'xhr':
      case 'fetch':
        return 'Network stream';
      case 'resource':
        return 'Resource';
      case 'embed':
        return 'Embedded player';
      case 'link':
        return 'Video link';
      case 'meta':
      case 'json-ld':
        return 'Page metadata';
      case 'data-attr':
        return 'Data attribute';
      default:
        return type;
    }
  }

  IconData _typeIcon(String type) {
    switch (type) {
      case 'video':
      case 'source':
        return Icons.play_circle;
      case 'xhr':
      case 'fetch':
      case 'resource':
        return Icons.cloud_download;
      case 'embed':
        return Icons.ondemand_video;
      case 'link':
        return Icons.link;
      default:
        return Icons.videocam;
    }
  }

  void _castBest() {
    if (_detectedVideos.isNotEmpty) {
      final sorted = List<_DetectedVideo>.from(_detectedVideos)
        ..sort((a, b) => a.priority.compareTo(b.priority));
      widget.onCastUrl(_normalizeForCast(sorted.first.url));
    } else if (_isPlatformUrl(_currentUrl)) {
      widget.onCastUrl(_normalizeForCast(_currentUrl));
    }
  }

  void _showVideoPicker() {
    final cs = Theme.of(context).colorScheme;

    // Sort: direct streams first, embeds last
    final sorted = List<_DetectedVideo>.from(_detectedVideos)
      ..sort((a, b) => a.priority.compareTo(b.priority));

    // Also add current page URL if it's a platform URL and not already in list
    final items = <_DetectedVideo>[...sorted];
    if (_isPlatformUrl(_currentUrl) &&
        !items.any((v) => _normalizeForCast(v.url) == _normalizeForCast(_currentUrl))) {
      items.insert(0, _DetectedVideo(url: _currentUrl, type: 'page'));
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final maxH = MediaQuery.of(ctx).size.height * 0.7;
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            shrinkWrap: true,
            itemCount: items.length + 1, // +1 for header
            itemBuilder: (_, i) {
              if (i == 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40, height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: cs.onSurfaceVariant.withAlpha(80),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Row(children: [
                      Icon(Icons.cast, color: cs.primary, size: 22),
                      const SizedBox(width: 8),
                      Text(
                        'Cast a video',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      Text(
                        '${items.length} found',
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    Text(
                      'Tap a video to send it to the Cast tab for TV selection.',
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    const Divider(height: 1),
                  ],
                );
              }
              final v = items[i - 1];
              final label = v.type == 'page' ? 'This page' : _videoLabel(v.url);
              final typeText = v.type == 'page' ? 'YouTube page' : _typeLabel(v.type);
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
                leading: CircleAvatar(
                  backgroundColor: cs.primaryContainer,
                  child: Icon(_typeIcon(v.type), color: cs.primary, size: 20),
                ),
                title: Text(label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                subtitle: Text(typeText,
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
                    widget.onCastUrl(_normalizeForCast(v.url));
                  },
                ),
              );
            },
          ),
        );
      },
    );
  }

  int get _castableCount {
    int count = _detectedVideos.length;
    if (_isPlatformUrl(_currentUrl)) count = count > 0 ? count : 1;
    return count;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    final hasCastable = _castableCount > 0;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _buildUrlBar(cs),
        actions: [
          // ── Cast button — the star of the show ──
          if (hasCastable)
            _AnimatedCastButton(
              count: _castableCount,
              onTap: _castableCount == 1 && _detectedVideos.isEmpty
                  ? _castBest // single platform page → cast directly
                  : _showVideoPicker,
            ),
          if (!hasCastable)
            IconButton(
              icon: const Icon(Icons.cast_outlined, size: 22),
              tooltip: 'No videos detected',
              onPressed: null, // disabled look
            ),
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
        ],
      ),
      bottomNavigationBar: _buildNavRow(cs),
    );
  }

  Widget _buildBookmarksGrid(ColorScheme cs) {
    final userBookmarks = ref.watch(bookmarksProvider);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // User-saved bookmarks
          if (userBookmarks.isNotEmpty) ...[
            Row(
              children: [
                Text('Bookmarks',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        color: cs.onSurfaceVariant)),
                const Spacer(),
                TextButton(
                  onPressed: () => ref.read(bookmarksProvider.notifier).clear(),
                  child: const Text('Clear', style: TextStyle(fontSize: 10)),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: userBookmarks.take(8).map((b) {
                final host = Uri.tryParse(b.url)?.host ?? '';
                return ActionChip(
                  avatar: const Icon(Icons.bookmark, size: 14),
                  label: Text(
                    b.title.isNotEmpty
                        ? (b.title.length > 15 ? '${b.title.substring(0, 15)}…' : b.title)
                        : host,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onPressed: () => _controller.loadRequest(Uri.parse(b.url)),
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
          ],
          // Quick-access sites
          Wrap(
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
        ],
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
    final bookmarks = ref.watch(bookmarksProvider);
    final isBookmarked = _currentUrl.isNotEmpty &&
        bookmarks.any((b) => b.url == _currentUrl);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
            IconButton(
              icon: Icon(
                isBookmarked ? Icons.bookmark : Icons.bookmark_border,
                size: 20,
                color: isBookmarked ? cs.primary : null,
              ),
              tooltip: isBookmarked ? 'Remove bookmark' : 'Bookmark this page',
              onPressed: () {
                if (_currentUrl.isEmpty) return;
                if (isBookmarked) {
                  ref.read(bookmarksProvider.notifier).remove(_currentUrl);
                } else {
                  ref.read(bookmarksProvider.notifier).add(
                        _currentUrl,
                        _urlController.text,
                      );
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.history, size: 20),
              tooltip: 'History',
              onPressed: _showHistorySheet,
            ),
            if (_detectedVideos.isNotEmpty)
              IconButton(
                icon: Icon(Icons.download, size: 20, color: cs.primary),
                tooltip: 'Download video',
                onPressed: _showDownloadPicker,
              ),
          ],
        ),
      ),
    );
  }

  void _showHistorySheet() {
    final history = ref.read(historyProvider);
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          builder: (_, scrollCtrl) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      Icon(Icons.history, color: cs.primary, size: 22),
                      const SizedBox(width: 8),
                      Text('Browsing History',
                          style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600)),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          ref.read(historyProvider.notifier).clear();
                          Navigator.pop(ctx);
                        },
                        child: const Text('Clear all', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: history.isEmpty
                      ? Center(
                          child: Text('No browsing history yet',
                              style: TextStyle(color: cs.onSurfaceVariant)))
                      : ListView.builder(
                          controller: scrollCtrl,
                          itemCount: history.length,
                          itemBuilder: (_, i) {
                            final entry = history[i];
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.language, size: 18),
                              title: Text(entry.title.isNotEmpty ? entry.title : entry.url,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: Text(entry.url,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11, color: cs.onSurfaceVariant)),
                              onTap: () {
                                Navigator.pop(ctx);
                                _controller.loadRequest(Uri.parse(entry.url));
                              },
                              trailing: IconButton(
                                icon: const Icon(Icons.close, size: 16),
                                onPressed: () {
                                  ref.read(historyProvider.notifier).removeEntry(entry.url);
                                },
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showDownloadPicker() {
    final cs = Theme.of(context).colorScheme;
    final sorted = List<_DetectedVideo>.from(_detectedVideos)
      ..sort((a, b) => a.priority.compareTo(b.priority));

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: cs.onSurfaceVariant.withAlpha(80),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Icon(Icons.download, color: cs.primary),
                  const SizedBox(width: 8),
                  Text('Download Video',
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 8),
              ...sorted.take(10).map((v) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(_typeIcon(v.type), color: cs.primary, size: 20),
                    title: Text(_videoLabel(v.url),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                    subtitle: Text(_typeLabel(v.type),
                        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                    trailing: IconButton(
                      icon: Icon(Icons.download, color: cs.primary),
                      onPressed: () {
                        Navigator.pop(ctx);
                        ref.read(downloadServiceProvider).download(
                          url: v.url,
                          filename: _filenameFromUrl(v.url),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Download started — check Files tab'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                    ),
                  )),
            ],
          ),
        );
      },
    );
  }

  String _filenameFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final last = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'video';
      final name = Uri.decodeComponent(last.split('?').first);
      if (name.contains('.')) return name;
      return '$name.mp4';
    } catch (_) {
      return 'video_${DateTime.now().millisecondsSinceEpoch}.mp4';
    }
  }
}

// ── Animated Cast Button (pulses when videos found) ─────────────────────────

class _AnimatedCastButton extends StatefulWidget {
  final int count;
  final VoidCallback onTap;
  const _AnimatedCastButton({required this.count, required this.onTap});

  @override
  State<_AnimatedCastButton> createState() => _AnimatedCastButtonState();
}

class _AnimatedCastButtonState extends State<_AnimatedCastButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _scale = Tween(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: ScaleTransition(
        scale: _scale,
        child: Badge.count(
          count: widget.count,
          backgroundColor: cs.error,
          child: IconButton(
            icon: Icon(Icons.cast, color: cs.primary, size: 24),
            tooltip: '${widget.count} video${widget.count == 1 ? '' : 's'} — tap to cast',
            onPressed: widget.onTap,
          ),
        ),
      ),
    );
  }
}
