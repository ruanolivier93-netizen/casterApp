import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../services/ad_blocker.dart';
import '../providers/bookmarks_history.dart';
import '../providers/app_state.dart';
import '../models/dlna_device.dart';

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

// ── Browser Tab Model ───────────────────────────────────────────────────────

class _BrowserTab {
  final String id;
  final WebViewController controller;
  String url;
  String title = 'New Tab';
  double progress = 0;
  bool canGoBack = false;
  bool canGoForward = false;
  bool showBookmarks;
  final List<_DetectedVideo> detectedVideos;

  _BrowserTab({
    required this.id,
    required this.controller,
    this.url = '',
    this.showBookmarks = true,
    List<_DetectedVideo>? detectedVideos,
  }) : detectedVideos = detectedVideos ?? [];
}

const _kMaxTabs = 8;

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
  final _tabs = <_BrowserTab>[];
  int _activeTabIndex = 0;
  final _urlController = TextEditingController();
  final _urlFocus = FocusNode();
  bool _desktopMode = false;

  static const _desktopUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  // ── Convenience accessors (delegate to active tab) ──
  _BrowserTab get _activeTab => _tabs[_activeTabIndex];
  WebViewController get _controller => _activeTab.controller;
  String get _currentUrl => _activeTab.url;
  double get _progress => _activeTab.progress;
  bool get _canGoBack => _activeTab.canGoBack;
  bool get _canGoForward => _activeTab.canGoForward;
  List<_DetectedVideo> get _detectedVideos => _activeTab.detectedVideos;
  bool get _showBookmarks => _activeTab.showBookmarks;
  set _showBookmarks(bool v) => _activeTab.showBookmarks = v;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final tab = _buildTab(url: 'https://www.google.com');
    _tabs.add(tab);
    _activeTabIndex = 0;
    _urlController.text = 'https://www.google.com';
    widget.onControllerCreated?.call(tab.controller);
  }

  // ── Tab factory ───────────────────────────────────────────────────────────

  _BrowserTab _buildTab({String? url}) {
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    final tab = _BrowserTab(
      id: 'tab_${DateTime.now().microsecondsSinceEpoch}',
      controller: WebViewController.fromPlatformCreationParams(params),
      url: url ?? '',
      showBookmarks: url == null || url == 'https://www.google.com',
    );

    tab.controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('VideoDetector',
          onMessageReceived: (msg) => _onVideoDetectedForTab(tab, msg))
      ..addJavaScriptChannel('NewTab',
          onMessageReceived: (msg) => _onNewTabRequested(msg.message))
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          if (AdBlocker.shouldBlock(request.url)) {
            return NavigationDecision.prevent;
          }
          if (AdBlocker.isPopupOrRedirect(request.url)) {
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onPageStarted: (pageUrl) {
          if (!mounted) return;
          setState(() {
            tab.url = pageUrl;
            tab.progress = 0;
            tab.detectedVideos.clear();
            tab.showBookmarks = false;
          });
          if (_tabs.indexOf(tab) == _activeTabIndex) {
            _urlController.text = pageUrl;
          }
          tab.controller.runJavaScript('''
            (function(){
              var s = document.createElement('style');
              s.textContent = ${_escapeJsString(AdBlocker.cssRules)};
              (document.head || document.documentElement).appendChild(s);
            })();
          ''');
          tab.controller.runJavaScript(AdBlocker.videoDetectorScript);
        },
        onProgress: (p) {
          if (mounted) setState(() => tab.progress = p / 100);
        },
        onPageFinished: (pageUrl) async {
          if (!mounted) return;
          final back = await tab.controller.canGoBack();
          final fwd = await tab.controller.canGoForward();
          final title = await tab.controller.getTitle() ?? pageUrl;
          setState(() {
            tab.url = pageUrl;
            tab.progress = 1;
            tab.canGoBack = back;
            tab.canGoForward = fwd;
            tab.title = title;
          });
          if (_tabs.indexOf(tab) == _activeTabIndex) {
            _urlController.text = pageUrl;
          }
          tab.controller.runJavaScript(AdBlocker.jsScript);
          tab.controller.runJavaScript(AdBlocker.videoDetectorScript);
          ref.read(historyProvider.notifier).add(pageUrl, title);
        },
      ));

    if (tab.controller.platform is AndroidWebViewController) {
      final android = tab.controller.platform as AndroidWebViewController;
      android.setMediaPlaybackRequiresUserGesture(false);
    }

    if (_desktopMode) {
      tab.controller.setUserAgent(_desktopUA);
    }

    final loadUrl = url ?? 'https://www.google.com';
    tab.controller.loadRequest(Uri.parse(loadUrl));
    if (url == null) tab.title = 'Home';

    return tab;
  }

  // ── Tab management ────────────────────────────────────────────────────────

  void _addNewTab({String? url, bool switchTo = true}) {
    if (_tabs.length >= _kMaxTabs) {
      // Close oldest non-active tab to make room
      final oldest = _tabs.indexWhere((t) => _tabs.indexOf(t) != _activeTabIndex);
      if (oldest >= 0) _closeTab(oldest);
    }

    final tab = _buildTab(url: url);
    setState(() {
      _tabs.add(tab);
      if (switchTo) {
        _activeTabIndex = _tabs.length - 1;
        _urlController.text = tab.url;
      }
    });

    if (switchTo) {
      widget.onControllerCreated?.call(tab.controller);
    }
  }

  void _closeTab(int index) {
    if (_tabs.length <= 1) return; // Always keep at least one tab
    setState(() {
      _tabs.removeAt(index);
      if (_activeTabIndex >= _tabs.length) {
        _activeTabIndex = _tabs.length - 1;
      } else if (_activeTabIndex > index) {
        _activeTabIndex--;
      }
    });
    _urlController.text = _activeTab.url;
    widget.onControllerCreated?.call(_activeTab.controller);
  }

  void _switchToTab(int index) {
    if (index < 0 || index >= _tabs.length || index == _activeTabIndex) return;
    setState(() => _activeTabIndex = index);
    _urlController.text = _activeTab.url;
    widget.onControllerCreated?.call(_activeTab.controller);
  }

  void _onNewTabRequested(String url) {
    if (url.isEmpty) return;
    if (AdBlocker.shouldBlock(url) || AdBlocker.isPopupOrRedirect(url)) return;

    _addNewTab(url: url, switchTo: false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Opened in new tab'),
          duration: const Duration(seconds: 2),
          action: SnackBarAction(
            label: 'Switch',
            onPressed: () => _switchToTab(_tabs.length - 1),
          ),
        ),
      );
    }
  }

  void _onVideoDetectedForTab(_BrowserTab tab, JavaScriptMessage msg) {
    try {
      final data = jsonDecode(msg.message) as Map<String, dynamic>;
      final url = data['url'] as String? ?? '';
      final type = data['type'] as String? ?? '';
      if (url.isEmpty) return;
      if (tab.detectedVideos.any((v) => v.url == url)) return;
      if (mounted) {
        setState(() {
          tab.detectedVideos.add(_DetectedVideo(url: url, type: type));
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

  void _toggleDesktopMode() {
    setState(() => _desktopMode = !_desktopMode);
    for (final tab in _tabs) {
      tab.controller.setUserAgent(_desktopMode ? _desktopUA : null);
    }
    _controller.reload();
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
                      'Tap a video to cast it to your TV.',
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
          // ── Tab strip (visible when 2+ tabs) ──
          if (_tabs.length > 1) _buildTabStrip(cs),
          if (_showBookmarks) _buildBookmarksGrid(cs),
          Expanded(
            child: IndexedStack(
              index: _activeTabIndex,
              children: _tabs
                  .map((tab) => KeyedSubtree(
                        key: ValueKey(tab.id),
                        child: WebViewWidget(controller: tab.controller),
                      ))
                  .toList(),
            ),
          ),
          // ── Inline Cast Panel ─────────────────────────────────────────────
          const _BrowserCastPanel(),
        ],
      ),
      bottomNavigationBar: _buildNavRow(cs),
    );
  }

  // ── Tab strip ──────────────────────────────────────────────────────────────

  Widget _buildTabStrip(ColorScheme cs) {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: cs.outlineVariant, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _tabs.length,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              itemBuilder: (_, i) {
                final tab = _tabs[i];
                final isActive = i == _activeTabIndex;
                return GestureDetector(
                  onTap: () => _switchToTab(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    constraints: const BoxConstraints(maxWidth: 160, minWidth: 60),
                    margin: const EdgeInsets.only(right: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: isActive
                          ? cs.primaryContainer
                          : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      border: isActive
                          ? Border.all(color: cs.primary.withAlpha(80), width: 1)
                          : null,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          tab.progress < 1 && tab.progress > 0
                              ? Icons.hourglass_top
                              : Icons.public,
                          size: 12,
                          color: isActive
                              ? cs.onPrimaryContainer
                              : cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            tab.title.isNotEmpty ? tab.title : 'New Tab',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight:
                                  isActive ? FontWeight.w600 : FontWeight.normal,
                              color: isActive
                                  ? cs.onPrimaryContainer
                                  : cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => _closeTab(i),
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Icon(
                              Icons.close,
                              size: 13,
                              color: isActive
                                  ? cs.onPrimaryContainer
                                  : cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (_tabs.length < _kMaxTabs)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _addNewTab(),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.add, size: 16, color: cs.onSurfaceVariant),
                ),
              ),
            ),
        ],
      ),
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
            // ── Tab counter ──
            _TabCountButton(
              count: _tabs.length,
              onTap: _tabs.length > 1
                  ? _showTabOverview
                  : () => _addNewTab(),
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
            IconButton(
              icon: Icon(
                _desktopMode ? Icons.desktop_windows : Icons.phone_android,
                size: 20,
                color: _desktopMode ? cs.primary : null,
              ),
              tooltip: _desktopMode ? 'Switch to mobile' : 'Switch to desktop',
              onPressed: _toggleDesktopMode,
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

  void _showTabOverview() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: cs.onSurfaceVariant.withAlpha(80),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Icon(Icons.tab, color: cs.primary, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '${_tabs.length} Tab${_tabs.length == 1 ? '' : 's'}',
                        style: Theme.of(ctx)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      if (_tabs.length < _kMaxTabs)
                        TextButton.icon(
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('New Tab',
                              style: TextStyle(fontSize: 12)),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _addNewTab();
                          },
                        ),
                    ],
                  ),
                  const Divider(height: 12),
                  ...List.generate(_tabs.length, (i) {
                    final tab = _tabs[i];
                    final isActive = i == _activeTabIndex;
                    return ListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      tileColor:
                          isActive ? cs.primaryContainer.withAlpha(80) : null,
                      leading: Icon(
                        Icons.public,
                        color: isActive ? cs.primary : cs.onSurfaceVariant,
                        size: 20,
                      ),
                      title: Text(
                        tab.title.isNotEmpty ? tab.title : 'New Tab',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              isActive ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        tab.url.isNotEmpty ? tab.url : 'about:blank',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10, color: cs.onSurfaceVariant),
                      ),
                      trailing: _tabs.length > 1
                          ? IconButton(
                              icon: const Icon(Icons.close, size: 16),
                              visualDensity: VisualDensity.compact,
                              onPressed: () {
                                _closeTab(i);
                                if (_tabs.length <= 1) {
                                  Navigator.pop(ctx);
                                } else {
                                  setSheetState(() {});
                                }
                              },
                            )
                          : null,
                      onTap: () {
                        Navigator.pop(ctx);
                        _switchToTab(i);
                      },
                    );
                  }),
                ],
              ),
            );
          },
        );
      },
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

// ── Tab Count Button ────────────────────────────────────────────────────────

class _TabCountButton extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _TabCountButton({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: cs.onSurface, width: 1.8),
        ),
        alignment: Alignment.center,
        child: Text(
          '$count',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
          ),
        ),
      ),
    );
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

// ── Browser Cast Panel ──────────────────────────────────────────────────────
//
// An inline panel shown at the bottom of the browser when a video has been
// extracted or is being cast. Provides device selection, cast button, and
// full playback controls (seek, forward/rewind, volume) so the user never
// has to leave the browser.

class _BrowserCastPanel extends ConsumerStatefulWidget {
  const _BrowserCastPanel();

  @override
  ConsumerState<_BrowserCastPanel> createState() => _BrowserCastPanelState();
}

class _BrowserCastPanelState extends ConsumerState<_BrowserCastPanel> {
  bool _expanded = true;
  double? _volume;
  bool _volumeFetched = false;

  @override
  Widget build(BuildContext context) {
    final videoState = ref.watch(videoProvider);
    final castState = ref.watch(castProvider);
    final devicesState = ref.watch(devicesProvider);

    // Show nothing if no video is loaded/loading and we're not casting.
    final showPanel = videoState is VideoLoaded ||
        videoState is VideoLoading ||
        castState is CastPlaying ||
        castState is CastPreparing ||
        castState is CastError;

    if (!showPanel) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;

    // Auto-scan for devices when a new video appears.
    if (videoState is VideoLoaded) {
      final ds = ref.read(devicesProvider);
      if (ds is DevicesIdle) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ref.read(devicesProvider.notifier).scan();
        });
      }
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Casting controls (shown when actively casting) ──
          if (castState is CastPlaying) _buildPlaybackControls(cs, castState),

          if (castState is CastPreparing)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
                  ),
                  const SizedBox(width: 10),
                  Text('Starting stream…',
                      style: TextStyle(fontSize: 13, color: cs.onSurface)),
                ],
              ),
            ),

          if (castState is CastError)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 18, color: cs.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(castState.message,
                        style: TextStyle(fontSize: 12, color: cs.error)),
                  ),
                  TextButton(
                    onPressed: () => ref.read(castProvider.notifier).stop(),
                    child: const Text('Dismiss', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ),

          // ── Pre-cast: device picker + cast button ──
          if (castState is! CastPlaying &&
              castState is! CastPreparing &&
              videoState is VideoLoaded)
            _buildPreCastRow(cs, videoState, devicesState),

          // ── Loading state ──
          if (videoState is VideoLoading && castState is CastIdle)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
                  ),
                  const SizedBox(width: 8),
                  Text('Extracting video…',
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPreCastRow(
      ColorScheme cs, VideoLoaded videoState, DevicesState devicesState) {
    final selectedDevice = ref.watch(selectedDeviceProvider);
    final selectedFormat = ref.watch(selectedFormatProvider);
    final settings = ref.watch(settingsProvider);
    final lastDeviceLocation = ref.watch(lastDeviceProvider);

    // Gather available devices
    final List<DlnaDevice> devices;
    final bool isScanning;
    if (devicesState is DevicesScanning) {
      devices = devicesState.devicesFoundSoFar;
      isScanning = true;
    } else if (devicesState is DevicesResult) {
      devices = devicesState.devices;
      isScanning = false;
    } else {
      devices = [];
      isScanning = false;
    }

    // Auto-select best format
    if (selectedFormat == null && videoState.info.formats.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(selectedFormatProvider.notifier).state =
            videoState.info.formats.first;
      });
    }

    // Auto-select last used device
    if (selectedDevice == null && lastDeviceLocation != null && devices.isNotEmpty) {
      final match = devices.where((d) => d.location == lastDeviceLocation).firstOrNull;
      if (match != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ref.read(selectedDeviceProvider.notifier).state = match;
        });
      }
    }

    // Auto-select single device
    if (selectedDevice == null && !isScanning && devices.length == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(selectedDeviceProvider.notifier).state = devices.first;
      });
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Title
          Row(
            children: [
              Icon(Icons.play_circle_fill, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  videoState.info.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                ),
              ),
              // Close panel / dismiss video
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                visualDensity: VisualDensity.compact,
                onPressed: () => ref.read(videoProvider.notifier).reset(),
                tooltip: 'Dismiss',
              ),
            ],
          ),
          const SizedBox(height: 4),

          // Device picker row
          Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _showDevicePicker(cs, devices, isScanning),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      border: Border.all(color: cs.outlineVariant),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.tv, size: 16, color: cs.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            selectedDevice?.name ??
                                (isScanning ? 'Scanning…' : 'Select TV'),
                            style: TextStyle(
                              fontSize: 12,
                              color: selectedDevice != null
                                  ? cs.onSurface
                                  : cs.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isScanning)
                          SizedBox(
                            width: 12, height: 12,
                            child: CircularProgressIndicator(
                                strokeWidth: 1.5, color: cs.primary),
                          )
                        else
                          Icon(Icons.arrow_drop_down,
                              size: 18, color: cs.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Cast button
              FilledButton.icon(
                icon: const Icon(Icons.cast, size: 18),
                label: const Text('Cast'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                onPressed: selectedDevice != null && selectedFormat != null
                    ? () {
                        ref.read(castHistoryProvider.notifier).add(
                          videoState.sourceUrl,
                          videoState.info.title,
                          videoState.info.thumbnailUrl,
                        );
                        ref.read(lastDeviceProvider.notifier).save(selectedDevice.location);
                        ref.read(castProvider.notifier).cast(
                          device: selectedDevice,
                          format: selectedFormat,
                          title: videoState.info.title,
                          routeThroughPhone: settings.routeThroughPhone,
                          durationSeconds: videoState.info.durationSeconds,
                        );
                      }
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showDevicePicker(
      ColorScheme cs, List<DlnaDevice> devices, bool isScanning) {
    final selectedDevice = ref.read(selectedDeviceProvider);
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
                  Icon(Icons.tv, color: cs.primary, size: 20),
                  const SizedBox(width: 8),
                  Text('Select TV',
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  if (isScanning)
                    const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    TextButton.icon(
                      icon: const Icon(Icons.refresh, size: 14),
                      label: const Text('Rescan', style: TextStyle(fontSize: 12)),
                      onPressed: () {
                        ref.read(devicesProvider.notifier).scan();
                        Navigator.pop(ctx);
                      },
                    ),
                ],
              ),
              const Divider(height: 12),
              if (devices.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    isScanning
                        ? 'Looking for TVs on your network…'
                        : 'No TVs found. Make sure your TV is on and on the same WiFi.',
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ),
              ...devices.map((d) {
                final sel = selectedDevice == d;
                return ListTile(
                  dense: true,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  tileColor: sel ? cs.primaryContainer.withAlpha(80) : null,
                  leading: Icon(Icons.tv,
                      color: sel ? cs.primary : cs.onSurfaceVariant, size: 20),
                  title: Text(d.name,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: sel ? FontWeight.w600 : FontWeight.normal)),
                  subtitle: d.manufacturer.isNotEmpty
                      ? Text(d.manufacturer, style: const TextStyle(fontSize: 11))
                      : null,
                  trailing: sel
                      ? Icon(Icons.check_circle, color: cs.primary, size: 18)
                      : null,
                  onTap: () {
                    ref.read(selectedDeviceProvider.notifier).state = d;
                    Navigator.pop(ctx);
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlaybackControls(ColorScheme cs, CastPlaying castState) {
    final progress = ref.watch(castPositionProvider);
    final total = progress.total.inSeconds;
    final pos = progress.position.inSeconds.clamp(0, total > 0 ? total : 1);

    // Fetch volume once
    if (!_volumeFetched) {
      _volumeFetched = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          if (castState.device.protocol == CastProtocol.chromecast) {
            if (mounted) setState(() => _volume ??= 50);
          } else {
            final v = await ref.read(dlnaServiceProvider).getVolume(castState.device);
            if (mounted && v != null) setState(() => _volume = v.toDouble());
          }
        } catch (_) {}
      });
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Now playing header ──
          Row(
            children: [
              Icon(Icons.cast_connected, color: cs.primary, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(castState.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12)),
                    Text('on ${castState.device.name}',
                        style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              // Collapse / expand toggle
              IconButton(
                icon: Icon(
                  _expanded ? Icons.expand_more : Icons.expand_less,
                  size: 20,
                ),
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _expanded = !_expanded),
              ),
            ],
          ),

          // ── Seek bar ──
          if (total > 0) ...[
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: pos.toDouble(),
                min: 0,
                max: total.toDouble(),
                onChanged: (_) {},
                onChangeEnd: (v) =>
                    ref.read(castProvider.notifier).seek(Duration(seconds: v.toInt())),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(progress.position),
                      style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
                  Text(_fmt(progress.total),
                      style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
                ],
              ),
            ),
          ],

          // ── Transport controls ──
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Rewind 10s
              IconButton(
                icon: const Icon(Icons.replay_10, size: 22),
                visualDensity: VisualDensity.compact,
                tooltip: 'Rewind 10s',
                onPressed: () {
                  final newPos = Duration(
                      seconds: (progress.position.inSeconds - 10).clamp(0, total));
                  ref.read(castProvider.notifier).seek(newPos);
                },
              ),
              // Play / Pause
              IconButton.filled(
                icon: Icon(
                  castState.isPaused ? Icons.play_arrow : Icons.pause,
                  size: 26,
                ),
                onPressed: () => ref.read(castProvider.notifier).pauseResume(),
                tooltip: castState.isPaused ? 'Play' : 'Pause',
              ),
              // Forward 10s
              IconButton(
                icon: const Icon(Icons.forward_10, size: 22),
                visualDensity: VisualDensity.compact,
                tooltip: 'Forward 10s',
                onPressed: () {
                  final newPos = Duration(
                      seconds: (progress.position.inSeconds + 10).clamp(0, total));
                  ref.read(castProvider.notifier).seek(newPos);
                },
              ),
              // Stop
              IconButton(
                icon: const Icon(Icons.stop, size: 22),
                visualDensity: VisualDensity.compact,
                tooltip: 'Stop',
                onPressed: () {
                  setState(() {
                    _volume = null;
                    _volumeFetched = false;
                  });
                  ref.read(castProvider.notifier).stop();
                },
              ),
            ],
          ),

          // ── Volume (collapsible) ──
          if (_expanded) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                const Icon(Icons.volume_down, size: 16),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 5),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                    ),
                    child: Slider(
                      value: (_volume ?? 50).clamp(0, 100).toDouble(),
                      min: 0,
                      max: 100,
                      divisions: 20,
                      label: '${(_volume ?? 50).round()}',
                      onChanged: (v) => setState(() => _volume = v),
                      onChangeEnd: (v) async {
                        setState(() => _volume = v);
                        if (castState.device.protocol == CastProtocol.chromecast) {
                          await ref.read(chromecastServiceProvider).setVolume(v / 100);
                        } else {
                          await ref.read(dlnaServiceProvider).setVolume(
                              castState.device, v.round());
                        }
                      },
                    ),
                  ),
                ),
                const Icon(Icons.volume_up, size: 16),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
