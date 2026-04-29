import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/ad_blocker.dart';
import '../services/native_cast_service.dart';
import '../providers/bookmarks_history.dart';
import '../providers/app_state.dart';
import '../providers/native_cast_provider.dart';
import '../providers/privacy_telemetry.dart';
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
  final String
      type; // 'video', 'source', 'xhr', 'fetch', 'resource', 'embed', 'link', 'meta', etc.
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

  /// Extract a human-readable stream label from the URL path.
  /// e.g. "master", "index-v1-a1", "720p", etc.
  String get streamLabel {
    try {
      final uri = Uri.parse(url);
      final last = uri.pathSegments.isNotEmpty
          ? Uri.decodeComponent(uri.pathSegments.last.split('?').first)
          : '';
      // Strip extension
      final name = last.replaceAll(
          RegExp(r'\.(m3u8|mpd|mp4|ts|webm|mkv|avi|mov|flv)$',
              caseSensitive: false),
          '');
      if (name.isNotEmpty && name.length < 60) return name;
    } catch (_) {}
    return '';
  }

  /// Detect format type badge text: "m3u8 (HLS)", "mp4", "mpd (DASH)", etc.
  String get formatBadge {
    final lower = url.toLowerCase();
    String resolution = _extractResolution;
    if (lower.contains('.m3u8')) {
      if (resolution.isEmpty && lower.contains('master')) return 'm3u8 (HLS)';
      return resolution.isNotEmpty ? 'm3u8 ($resolution)' : 'm3u8';
    }
    if (lower.contains('.mpd')) {
      return resolution.isNotEmpty ? 'mpd ($resolution)' : 'mpd (DASH)';
    }
    if (lower.contains('.mp4')) {
      return resolution.isNotEmpty ? 'mp4 ($resolution)' : 'mp4';
    }
    if (lower.contains('.webm')) {
      return resolution.isNotEmpty ? 'webm ($resolution)' : 'webm';
    }
    if (lower.contains('.mkv')) return 'mkv';
    if (lower.contains('.ts')) return 'ts';
    if (lower.contains('.flv')) return 'flv';
    if (lower.contains('.mov')) return 'mov';
    if (lower.contains('.avi')) return 'avi';
    // For embed URLs
    if (type == 'embed') return 'embed';
    if (type == 'page') return 'page';
    return 'stream';
  }

  /// Try to extract resolution from URL path (e.g., 720, 1080, 1280x720).
  String get _extractResolution {
    final lower = url.toLowerCase();
    // Match patterns like 1920x1080, 1280x720
    final dimMatch = RegExp(r'(\d{3,4})x(\d{3,4})').firstMatch(lower);
    if (dimMatch != null) return '${dimMatch.group(1)}x${dimMatch.group(2)}';
    // Match patterns like /720p, -1080p, _480p
    final pMatch = RegExp(r'[\/_\-](\d{3,4})p').firstMatch(lower);
    if (pMatch != null) return '${pMatch.group(1)}p';
    // Match patterns like /720/, height=720
    final hMatch = RegExp(r'(?:height|h)[=\/](\d{3,4})').firstMatch(lower);
    if (hMatch != null) return '${hMatch.group(1)}p';
    return '';
  }

  /// Whether this is likely an HLS master playlist (contains variant streams).
  bool get isMasterPlaylist {
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') &&
        (lower.contains('master') ||
            lower.contains('index') && !RegExp(r'v\d').hasMatch(lower));
  }

  /// Extract the CDN/host domain for display.
  String get hostLabel {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return '';
    }
  }
}

// ── Browser Tab Model ───────────────────────────────────────────────────────

class _BrowserTab {
  final String id;
  InAppWebViewController? controller; // set by onWebViewCreated
  String url;
  String title = 'New Tab';
  double progress = 0;
  bool canGoBack = false;
  bool canGoForward = false;
  bool showBookmarks;
  final List<_DetectedVideo> detectedVideos;
  String? thumbnailUrl;
  String? lastBlockedDomain;
  DateTime? lastBlockedTime;

  _BrowserTab({
    required this.id,
    this.url = '',
    this.showBookmarks = true,
    List<_DetectedVideo>? detectedVideos,
  }) : detectedVideos = detectedVideos ?? [];
}

const _kMaxTabs = 8;

// ── Browser Screen ──────────────────────────────────────────────────────────

class BrowserScreen extends ConsumerStatefulWidget {
  final OnCastUrl onCastUrl;
  final ValueChanged<InAppWebViewController>? onControllerCreated;
  const BrowserScreen(
      {super.key, required this.onCastUrl, this.onControllerCreated});

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen>
    with AutomaticKeepAliveClientMixin {
  static bool _startupPrivacyApplied = false;

  final _tabs = <_BrowserTab>[];
  int _activeTabIndex = 0;
  final _urlController = TextEditingController();
  final _urlFocus = FocusNode();
  bool _desktopMode = false;
  bool? _adBlockAppliedValue;

  static const _desktopUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// Content blocker rules built from AdBlocker.blockedDomains.
  late final List<ContentBlocker> _contentBlockers = _buildContentBlockers();

  // ── Convenience accessors (delegate to active tab) ──
  _BrowserTab get _activeTab => _tabs[_activeTabIndex];
  InAppWebViewController? get _controller => _activeTab.controller;
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
    _adBlockAppliedValue = ref.read(settingsProvider).adBlockEnabled;
    _applyStartupPrivacyPolicy();
    final tab = _createTab(url: 'https://www.google.com');
    _tabs.add(tab);
    _activeTabIndex = 0;
    _urlController.text = 'https://www.google.com';
  }

  Future<void> _applyStartupPrivacyPolicy() async {
    if (_startupPrivacyApplied) return;
    _startupPrivacyApplied = true;

    final prefs = await SharedPreferences.getInstance();
    final clearOnStart = prefs.getBool(kPrivacyClearOnStartKey) ?? false;
    if (!clearOnStart) return;

    try {
      await InAppWebViewController.clearAllCache();
      await CookieManager.instance().deleteAllCookies();
      await WebStorageManager.instance().deleteAllData();
      await ref.read(historyProvider.notifier).clear();
      await ref.read(telemetryProvider.notifier).log(
            'privacy_startup_clear_applied',
          );
    } catch (_) {}
  }

  // ── Content blocker builder ───────────────────────────────────────────────

  List<ContentBlocker> _buildContentBlockers() {
    const blockedResourceTypes = <ContentBlockerTriggerResourceType>[
      ContentBlockerTriggerResourceType.SCRIPT,
      ContentBlockerTriggerResourceType.STYLE_SHEET,
      ContentBlockerTriggerResourceType.IMAGE,
      ContentBlockerTriggerResourceType.FONT,
      ContentBlockerTriggerResourceType.SVG_DOCUMENT,
    ];

    final blockers = <ContentBlocker>[];
    for (final domain in AdBlocker.blockedDomains) {
      blockers.add(ContentBlocker(
        trigger: ContentBlockerTrigger(
          urlFilter: '^https?://([^/]+\\.)?${RegExp.escape(domain)}([/:].*)?',
          resourceType: blockedResourceTypes,
        ),
        action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
      ));
    }
    return blockers;
  }

  List<ContentBlocker> _contentBlockersForPage(String pageUrl, bool enabled) {
    if (!enabled || AdBlocker.isPlaybackSensitiveUrl(pageUrl)) {
      return const [];
    }
    return _contentBlockers;
  }

  List<UserScript> _initialScripts(bool adBlockEnabled, String pageUrl) {
    // Strategy (Brave / AdGuard / uBO Lite mobile model):
    //   1. Network-level URL blocking via native ContentBlocker (handled in
    //      `_buildContentBlockers()` and applied through InAppWebViewSettings).
    //   2. Cosmetic CSS hiding via `_cssInjectionScript` — purely declarative,
    //      cannot break page JS (the `:has(video)` PROTECT block in
    //      `AdBlocker.cssRules` re-shows any wrapper that contains a player).
    //   3. A tiny `_bridgeScript` so target=_blank links can open as new tabs.
    //   4. Video detector (always on, regardless of ad-block) so the Cast
    //      button can find playable streams.
    //
    // We deliberately do NOT inject any DOM-walking / event-intercepting JS:
    // overriding `window.open`, `addEventListener`, `setTimeout` strings, or
    // walking the DOM with `getComputedStyle` reliably breaks legitimate
    // video players (HLS.js, JW Player, video.js, custom HTML5 wrappers).
    final lightMode = AdBlocker.isPlaybackSensitiveUrl(pageUrl);
    final scripts = <UserScript>[
      UserScript(
        source: AdBlocker.videoDetectorScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
    ];

    if (adBlockEnabled) {
      scripts.insertAll(0, [
        UserScript(
          source: _bridgeScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        if (!lightMode)
          UserScript(
            source: _cssInjectionScript,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
      ]);
    }

    return scripts;
  }

  static const _bridgeScript = r'''
(function() {
  if (window.NewTab) return;
  window.NewTab = {
    postMessage: function(url) {
      try { window.flutter_inappwebview.callHandler('NewTab', url); } catch (_) {}
    }
  };
})();
''';

  String get _cssInjectionScript {
    final css = _escapeJsString(AdBlocker.cssRules);
    return '''
(function() {
  if (window.__rlCssInjected) return;
  window.__rlCssInjected = true;
  var style = document.createElement('style');
  style.setAttribute('data-rl-caster-adblock', '1');
  style.textContent = $css;
  (document.head || document.documentElement).appendChild(style);
})();
''';
  }

  Future<void> _injectAdBlockScripts(
    InAppWebViewController controller,
    String pageUrl,
  ) async {
    // Re-inject the lightweight layers (bridge + CSS) when ad-block is toggled
    // on at runtime. Heavy DOM/event-intercepting JS is intentionally NOT
    // injected — see `_initialScripts()` for rationale.
    await controller.evaluateJavascript(source: _bridgeScript);
    if (!AdBlocker.isPlaybackSensitiveUrl(pageUrl)) {
      await controller.evaluateJavascript(source: _cssInjectionScript);
    }
    await controller.evaluateJavascript(source: AdBlocker.videoDetectorScript);
  }

  Future<void> _applyBlockingModeForTab(
    InAppWebViewController controller,
    String pageUrl,
    bool enabled,
  ) async {
    await controller.setSettings(
      settings: InAppWebViewSettings(
        contentBlockers: _contentBlockersForPage(pageUrl, enabled),
      ),
    );
  }

  Future<void> _applyAdBlockSettingsToTabs(bool enabled) async {
    for (final tab in _tabs) {
      final controller = tab.controller;
      if (controller == null) continue;
      await _applyBlockingModeForTab(controller, tab.url, enabled);
      await controller.reload();
    }
  }

  bool _shouldBlockNavigation(_BrowserTab tab, String url) {
    final settings = ref.read(settingsProvider);
    if (!settings.adBlockEnabled) return false;
    final blocked = AdBlocker.shouldBlockNavigation(url);
    if (blocked) {
      _onAdBlocked(tab, url);
    }
    return blocked;
  }

  // ── Tab factory ───────────────────────────────────────────────────────────

  _BrowserTab _createTab({String? url}) {
    return _BrowserTab(
      id: 'tab_${DateTime.now().microsecondsSinceEpoch}',
      url: url ?? '',
      showBookmarks: url == null || url == 'https://www.google.com',
    );
  }

  /// Builds an InAppWebView widget for a given tab.
  Widget _buildWebView(_BrowserTab tab) {
    final initialUrl = tab.url.isNotEmpty ? tab.url : 'https://www.google.com';
    final adBlockEnabled = ref.read(settingsProvider).adBlockEnabled;

    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(initialUrl)),
      initialUserScripts:
          UnmodifiableListView(_initialScripts(adBlockEnabled, initialUrl)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        supportMultipleWindows: true,
        javaScriptCanOpenWindowsAutomatically: true,
        userAgent: _desktopMode ? _desktopUA : null,
        contentBlockers: _contentBlockersForPage(initialUrl, adBlockEnabled),
      ),
      onWebViewCreated: (controller) {
        tab.controller = controller;
        controller.addJavaScriptHandler(
          handlerName: 'VideoDetector',
          callback: (args) {
            if (args.isNotEmpty && args.first is String) {
              _onVideoDetectedForTab(tab, args.first as String);
            }
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'NewTab',
          callback: (args) {
            final url = args.isNotEmpty ? args.first?.toString() ?? '' : '';
            if (url.isEmpty) return;
            if (_shouldBlockNavigation(tab, url)) return;
            _onNewTabRequested(url);
          },
        );
        if (_tabs.indexOf(tab) == _activeTabIndex) {
          widget.onControllerCreated?.call(controller);
        }
      },
      shouldOverrideUrlLoading: (controller, action) async {
        final url = action.request.url?.toString() ?? '';
        if (url.isNotEmpty && _shouldBlockNavigation(tab, url)) {
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.ALLOW;
      },
      onCreateWindow: (controller, createWindowAction) async {
        final url = createWindowAction.request.url?.toString() ?? '';
        if (url.isNotEmpty) {
          if (_shouldBlockNavigation(tab, url)) {
            return false;
          }
          _onNewTabRequested(url);
        }
        return false; // we handle it ourselves
      },
      onLoadStart: (controller, url) async {
        if (!mounted) return;
        final pageUrl = url?.toString() ?? '';
        await _applyBlockingModeForTab(
          controller,
          pageUrl,
          ref.read(settingsProvider).adBlockEnabled,
        );
        setState(() {
          tab.url = pageUrl;
          tab.progress = 0;
          tab.detectedVideos.clear();
          tab.showBookmarks = false;
        });
        if (_tabs.indexOf(tab) == _activeTabIndex) {
          _urlController.text = pageUrl;
        }
      },
      onProgressChanged: (controller, p) {
        if (mounted) setState(() => tab.progress = p / 100);
      },
      onLoadStop: (controller, url) async {
        if (!mounted) return;
        final pageUrl = url?.toString() ?? '';
        final back = await controller.canGoBack();
        final fwd = await controller.canGoForward();
        final title = await controller.getTitle() ?? pageUrl;
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
        final settings = ref.read(settingsProvider);
        if (settings.adBlockEnabled) {
          await _injectAdBlockScripts(controller, pageUrl);
        } else {
          // Re-inject video detector even when ad blocking is disabled.
          await controller.evaluateJavascript(
              source: AdBlocker.videoDetectorScript);
        }
        // Extract page thumbnail (og:image) for video list
        await controller.evaluateJavascript(source: '''
          (function() {
            var meta = document.querySelector('meta[property="og:image"]');
            if (!meta) meta = document.querySelector('meta[name="twitter:image"]');
            if (!meta) meta = document.querySelector('meta[property="og:image:url"]');
            if (meta && meta.content) {
              window.flutter_inappwebview.callHandler('VideoDetector',
                JSON.stringify({url: meta.content, type: 'thumbnail'}));
            }
          })();
        ''');
        ref.read(historyProvider.notifier).add(pageUrl, title);
      },
      onConsoleMessage: (controller, consoleMessage) {
        // Silently ignore console messages
      },
    );
  }

  // ── Tab management ────────────────────────────────────────────────────────

  void _addNewTab({String? url, bool switchTo = true}) {
    if (_tabs.length >= _kMaxTabs) {
      // Close oldest non-active tab to make room
      final oldest =
          _tabs.indexWhere((t) => _tabs.indexOf(t) != _activeTabIndex);
      if (oldest >= 0) _closeTab(oldest);
    }

    final tab = _createTab(url: url);
    setState(() {
      _tabs.add(tab);
      if (switchTo) {
        _activeTabIndex = _tabs.length - 1;
        _urlController.text = tab.url;
      }
    });
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
    final c = _activeTab.controller;
    if (c != null) widget.onControllerCreated?.call(c);
  }

  void _switchToTab(int index) {
    if (index < 0 || index >= _tabs.length || index == _activeTabIndex) return;
    setState(() => _activeTabIndex = index);
    _urlController.text = _activeTab.url;
    final c = _activeTab.controller;
    if (c != null) widget.onControllerCreated?.call(c);
  }

  void _onNewTabRequested(String url) {
    if (url.isEmpty) return;
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

  void _onVideoDetectedForTab(_BrowserTab tab, String message) {
    try {
      final data = jsonDecode(message) as Map<String, dynamic>;
      final url = data['url'] as String? ?? '';
      final type = data['type'] as String? ?? '';
      if (url.isEmpty) return;
      // Handle thumbnail extraction
      if (type == 'thumbnail') {
        if (mounted) setState(() => tab.thumbnailUrl = url);
        return;
      }
      if (tab.detectedVideos.any((v) => v.url == url)) return;
      if (mounted) {
        setState(() {
          tab.detectedVideos.add(_DetectedVideo(url: url, type: type));
        });
      }
    } catch (_) {}
  }

  void _onAdBlocked(_BrowserTab tab, String url) {
    try {
      final host = Uri.tryParse(url)?.host ?? '';
      if (host.isEmpty) return;
      ref.read(telemetryProvider.notifier).log(
        'ad_navigation_blocked',
        payload: {
          'host': host,
          'url': url,
        },
      );
      if (mounted) {
        setState(() {
          tab.lastBlockedDomain = host;
          tab.lastBlockedTime = DateTime.now();
        });
        // Auto-dismiss after 4 seconds
        Future.delayed(const Duration(seconds: 4), () {
          if (mounted && tab.lastBlockedDomain == host) {
            setState(() {
              tab.lastBlockedDomain = null;
              tab.lastBlockedTime = null;
            });
          }
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
    _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    _urlFocus.unfocus();
  }

  void _toggleDesktopMode() {
    setState(() => _desktopMode = !_desktopMode);
    final ua = _desktopMode ? _desktopUA : '';
    for (final tab in _tabs) {
      tab.controller
          ?.setSettings(settings: InAppWebViewSettings(userAgent: ua));
    }
    _controller?.reload();
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
    if (host.contains('youtube.com') || host.contains('youtu.be')) {
      return 'YouTube video';
    }
    if (host.contains('vimeo.com')) return 'Vimeo video';
    if (host.contains('dailymotion.com') || host.contains('dai.ly')) {
      return 'Dailymotion video';
    }
    if (host.contains('twitch.tv')) return 'Twitch stream';
    if (host.contains('facebook.com')) return 'Facebook video';
    final last = uri.pathSegments.isNotEmpty
        ? Uri.decodeComponent(uri.pathSegments.last.split('?').first)
        : '';
    if (last.length > 4) {
      return last.length > 50 ? '${last.substring(0, 50)}…' : last;
    }
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
    // Store the current page URL so the proxy can use it as Referer.
    ref.read(browserPageUrlProvider.notifier).state = _currentUrl;
    if (_detectedVideos.isNotEmpty) {
      final sorted = List<_DetectedVideo>.from(_detectedVideos)
        ..sort((a, b) => a.priority.compareTo(b.priority));
      widget.onCastUrl(_normalizeForCast(sorted.first.url));
    } else if (_isPlatformUrl(_currentUrl)) {
      widget.onCastUrl(_normalizeForCast(_currentUrl));
    }
  }

  void _showVideoPicker() {
    final settings = ref.read(settingsProvider);
    final pageTitle = _activeTab.title;
    final thumbnail = _activeTab.thumbnailUrl;

    // Sort: direct streams first, embeds last
    final sorted = List<_DetectedVideo>.from(_detectedVideos)
      ..sort((a, b) => a.priority.compareTo(b.priority));

    // Also add current page URL if it's a platform URL and not already in list
    final items = <_DetectedVideo>[...sorted];
    if (_isPlatformUrl(_currentUrl) &&
        !items.any((v) =>
            _normalizeForCast(v.url) == _normalizeForCast(_currentUrl))) {
      items.insert(0, _DetectedVideo(url: _currentUrl, type: 'page'));
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => _VideoListScreen(
          items: items,
          pageTitle: pageTitle,
          thumbnailUrl: thumbnail,
          routeThroughPhone: settings.routeThroughPhone,
          onCast: (video) {
            ref.read(browserPageUrlProvider.notifier).state = _currentUrl;
            widget.onCastUrl(_normalizeForCast(video.url));
          },
          onToggleRoute: () {
            ref.read(settingsProvider.notifier).toggle();
          },
          onDownload: (video) {
            ref.read(downloadServiceProvider).download(
                  url: video.url,
                  filename: _filenameFromUrl(video.url),
                );
            ScaffoldMessenger.of(ctx).showSnackBar(
              const SnackBar(
                content: Text('Download started — check Files tab'),
                duration: Duration(seconds: 2),
              ),
            );
          },
        ),
      ),
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
    final settings = ref.watch(settingsProvider);
    final nativeCastState = ref.watch(nativeCastProvider);

    if (_adBlockAppliedValue != settings.adBlockEnabled) {
      _adBlockAppliedValue = settings.adBlockEnabled;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _applyAdBlockSettingsToTabs(settings.adBlockEnabled);
      });
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
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
            icon: Icon(
              nativeCastState.connected
                  ? Icons.cast_connected_rounded
                  : Icons.cast_outlined,
              size: 20,
            ),
            tooltip: nativeCastState.connected
                ? 'Connected to ${nativeCastState.deviceName ?? 'Chromecast'}'
                : 'Connect Chromecast',
            onPressed: () => ref.read(nativeCastProvider.notifier).showDialog(),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: 'Reload',
            onPressed: () => _controller?.reload(),
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
          _buildAdBlockedBar(cs),
          // ── Tab strip (visible when 2+ tabs) ──
          if (_tabs.length > 1) _buildTabStrip(cs),
          if (_showBookmarks) _buildBookmarksGrid(cs),
          Expanded(
            child: IndexedStack(
              index: _activeTabIndex,
              children: _tabs
                  .map((tab) => KeyedSubtree(
                        key: ValueKey(tab.id),
                        child: _buildWebView(tab),
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
        border:
            Border(bottom: BorderSide(color: cs.outlineVariant, width: 0.5)),
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
                    constraints:
                        const BoxConstraints(maxWidth: 160, minWidth: 60),
                    margin: const EdgeInsets.only(right: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: isActive
                          ? cs.primaryContainer
                          : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      border: isActive
                          ? Border.all(
                              color: cs.primary.withAlpha(80), width: 1)
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
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.normal,
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
                  onPressed: _showBookmarksSheet,
                  child: const Text('View all', style: TextStyle(fontSize: 10)),
                ),
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
                        ? (b.title.length > 15
                            ? '${b.title.substring(0, 15)}…'
                            : b.title)
                        : host,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onPressed: () => _controller?.loadUrl(
                      urlRequest: URLRequest(url: WebUri(b.url))),
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
                      label:
                          Text(b.label, style: const TextStyle(fontSize: 12)),
                      onPressed: () => _controller?.loadUrl(
                          urlRequest: URLRequest(url: WebUri(b.url))),
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
    final bookmarksNotifier = ref.read(bookmarksProvider.notifier);
    final settings = ref.watch(settingsProvider);
    final isBookmarked =
        _currentUrl.isNotEmpty && bookmarksNotifier.isBookmarked(_currentUrl);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_ios, size: 18),
              tooltip: 'Back',
              onPressed: _canGoBack ? () => _controller?.goBack() : null,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward_ios, size: 18),
              tooltip: 'Forward',
              onPressed: _canGoForward ? () => _controller?.goForward() : null,
            ),
            IconButton(
              icon: const Icon(Icons.home_outlined, size: 20),
              tooltip: 'Home',
              onPressed: () {
                setState(() => _showBookmarks = true);
                _controller?.loadUrl(
                    urlRequest:
                        URLRequest(url: WebUri('https://www.google.com')));
              },
            ),
            // ── Tab counter ──
            _TabCountButton(
              count: _tabs.length,
              onTap: _tabs.length > 1 ? _showTabOverview : () => _addNewTab(),
            ),
            IconButton(
              icon: Icon(
                settings.adBlockEnabled ? Icons.shield : Icons.shield_outlined,
                size: 20,
                color: settings.adBlockEnabled ? cs.primary : null,
              ),
              tooltip: settings.adBlockEnabled
                  ? 'Ad blocker: on'
                  : 'Ad blocker: off',
              onPressed: () {
                final enabled = !settings.adBlockEnabled;
                ref.read(settingsProvider.notifier).toggleAdBlock();
                ref.read(telemetryProvider.notifier).log(
                  'adblock_toggled',
                  payload: {'enabled': enabled},
                );
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
            IconButton(
              icon: const Icon(Icons.cleaning_services_outlined, size: 20),
              tooltip: 'Clear browsing data',
              onPressed: _confirmAndClearBrowsingData,
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

  void _showBookmarksSheet() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Consumer(
          builder: (_, ref, __) {
            final bookmarks = ref.watch(bookmarksProvider);
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
                          Icon(Icons.bookmark, color: cs.primary, size: 22),
                          const SizedBox(width: 8),
                          Text('Bookmarks',
                              style: Theme.of(ctx)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const Spacer(),
                          TextButton(
                            onPressed: () =>
                                ref.read(bookmarksProvider.notifier).clear(),
                            child: const Text('Clear all',
                                style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: bookmarks.isEmpty
                          ? Center(
                              child: Text('No bookmarks yet',
                                  style: TextStyle(color: cs.onSurfaceVariant)))
                          : ListView.builder(
                              controller: scrollCtrl,
                              itemCount: bookmarks.length,
                              itemBuilder: (_, i) {
                                final entry = bookmarks[i];
                                return ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.bookmark, size: 18),
                                  title: Text(
                                      entry.title.isNotEmpty
                                          ? entry.title
                                          : entry.url,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13)),
                                  subtitle: Text(entry.url,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: cs.onSurfaceVariant)),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    _controller?.loadUrl(
                                        urlRequest:
                                            URLRequest(url: WebUri(entry.url)));
                                  },
                                  trailing: IconButton(
                                    icon: const Icon(Icons.close, size: 16),
                                    onPressed: () {
                                      ref
                                          .read(bookmarksProvider.notifier)
                                          .remove(entry.url);
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
      },
    );
  }

  Future<void> _confirmAndClearBrowsingData() async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Clear browsing data?'),
            content: const Text(
              'This will clear browser cache, cookies, and web storage for all tabs.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Clear'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed) return;
    await _clearBrowsingData();
  }

  Future<void> _clearBrowsingData() async {
    try {
      await InAppWebViewController.clearAllCache();
      await CookieManager.instance().deleteAllCookies();
      await WebStorageManager.instance().deleteAllData();
      await ref.read(telemetryProvider.notifier).log(
            'privacy_clear_browsing_data',
          );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Browsing data cleared'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not clear all browsing data'),
          duration: Duration(seconds: 2),
        ),
      );
    }
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
                        style:
                            TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
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
                          style: Theme.of(ctx)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          ref.read(historyProvider.notifier).clear();
                          Navigator.pop(ctx);
                        },
                        child: const Text('Clear all',
                            style: TextStyle(fontSize: 12)),
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
                              title: Text(
                                  entry.title.isNotEmpty
                                      ? entry.title
                                      : entry.url,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: Text(entry.url,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: cs.onSurfaceVariant)),
                              onTap: () {
                                Navigator.pop(ctx);
                                _controller?.loadUrl(
                                    urlRequest:
                                        URLRequest(url: WebUri(entry.url)));
                              },
                              trailing: IconButton(
                                icon: const Icon(Icons.close, size: 16),
                                onPressed: () {
                                  ref
                                      .read(historyProvider.notifier)
                                      .removeEntry(entry.url);
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
                  Icon(Icons.download, color: cs.primary),
                  const SizedBox(width: 8),
                  Text('Download Video',
                      style: Theme.of(ctx)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 8),
              ...sorted.take(10).map((v) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading:
                        Icon(_typeIcon(v.type), color: cs.primary, size: 20),
                    title: Text(_videoLabel(v.url),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                    subtitle: Text(_typeLabel(v.type),
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant)),
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

  Widget _buildAdBlockedBar(ColorScheme cs) {
    final domain = _activeTab.lastBlockedDomain;
    if (domain == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: cs.errorContainer,
      child: Row(
        children: [
          Icon(Icons.shield, size: 16, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Ad redirect blocked  —  $domain',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: cs.onErrorContainer,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() {
              _activeTab.lastBlockedDomain = null;
              _activeTab.lastBlockedTime = null;
            }),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close, size: 14, color: cs.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }

  String _filenameFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final last =
          uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'video';
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
            tooltip:
                '${widget.count} video${widget.count == 1 ? '' : 's'} — tap to cast',
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
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: cs.primary),
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
                    child:
                        const Text('Dismiss', style: TextStyle(fontSize: 11)),
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
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: cs.primary),
                  ),
                  const SizedBox(width: 8),
                  Text('Extracting video…',
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
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
    final nativeCastState = ref.watch(nativeCastProvider);
    final selectedFormat = ref.watch(selectedFormatProvider);
    final settings = ref.watch(settingsProvider);
    final lastDeviceLocation = ref.watch(lastDeviceProvider);
    final effectiveCastDevice = selectedDevice ??
        (nativeCastState.connected
            ? DlnaDevice(
                protocol: CastProtocol.chromecast,
                name: nativeCastState.deviceName ?? 'Chromecast',
                manufacturer: 'Google Cast',
                location: 'cast://active-session',
                controlUrl: '',
              )
            : null);

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
    if (selectedDevice == null &&
        lastDeviceLocation != null &&
        devices.isNotEmpty) {
      final match =
          devices.where((d) => d.location == lastDeviceLocation).firstOrNull;
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
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 12),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                            effectiveCastDevice?.name ??
                              (isScanning
                                ? 'Scanning DLNA TVs…'
                                : 'Select TV or connect Cast'),
                            style: TextStyle(
                              fontSize: 12,
                              color: effectiveCastDevice != null
                                  ? cs.onSurface
                                  : cs.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isScanning)
                          SizedBox(
                            width: 12,
                            height: 12,
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  textStyle: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                onPressed: effectiveCastDevice != null && selectedFormat != null
                    ? () {
                        ref.read(castHistoryProvider.notifier).add(
                              videoState.sourceUrl,
                              videoState.info.title,
                              videoState.info.thumbnailUrl,
                            );
                    if (selectedDevice != null) {
                      ref
                        .read(lastDeviceProvider.notifier)
                        .save(selectedDevice.location);
                    }
                        ref.read(castProvider.notifier).cast(
                        device: effectiveCastDevice,
                              format: selectedFormat,
                              title: videoState.info.title,
                              routeThroughPhone: settings.routeThroughPhone,
                              durationSeconds: videoState.info.durationSeconds,
                              refererUrl: ref.read(browserPageUrlProvider),
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
                  Icon(Icons.tv, color: cs.primary, size: 20),
                  const SizedBox(width: 8),
                  Text('Select TV',
                      style: Theme.of(ctx)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  if (isScanning)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    TextButton.icon(
                      icon: const Icon(Icons.refresh, size: 14),
                      label:
                          const Text('Rescan', style: TextStyle(fontSize: 12)),
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
                          fontWeight:
                              sel ? FontWeight.w600 : FontWeight.normal)),
                  subtitle: d.manufacturer.isNotEmpty
                      ? Text(d.manufacturer,
                          style: const TextStyle(fontSize: 11))
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
            final v = await NativeCastService.getVolume();
            if (mounted) setState(() => _volume = (v ?? 0.5) * 100);
          } else {
            final v =
                await ref.read(dlnaServiceProvider).getVolume(castState.device);
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
                        style: TextStyle(
                            fontSize: 10, color: cs.onSurfaceVariant)),
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
                onChangeEnd: (v) => ref
                    .read(castProvider.notifier)
                    .seek(Duration(seconds: v.toInt())),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(progress.position),
                      style:
                          TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
                  Text(_fmt(progress.total),
                      style:
                          TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
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
                      seconds:
                          (progress.position.inSeconds - 10).clamp(0, total));
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
                      seconds:
                          (progress.position.inSeconds + 10).clamp(0, total));
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
                        if (castState.device.protocol ==
                            CastProtocol.chromecast) {
                          await NativeCastService.setVolume(v / 100);
                        } else {
                          await ref
                              .read(dlnaServiceProvider)
                              .setVolume(castState.device, v.round());
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

// ── Video List Screen (WVC-style) ───────────────────────────────────────────

class _VideoListScreen extends StatefulWidget {
  final List<_DetectedVideo> items;
  final String pageTitle;
  final String? thumbnailUrl;
  final bool routeThroughPhone;
  final void Function(_DetectedVideo) onCast;
  final VoidCallback onToggleRoute;
  final void Function(_DetectedVideo) onDownload;

  const _VideoListScreen({
    required this.items,
    required this.pageTitle,
    this.thumbnailUrl,
    required this.routeThroughPhone,
    required this.onCast,
    required this.onToggleRoute,
    required this.onDownload,
  });

  @override
  State<_VideoListScreen> createState() => _VideoListScreenState();
}

class _VideoListScreenState extends State<_VideoListScreen> {
  late bool _routeThroughPhone;

  @override
  void initState() {
    super.initState();
    _routeThroughPhone = widget.routeThroughPhone;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Video list'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.cast, size: 22),
            tooltip: 'Cast best',
            onPressed: widget.items.isNotEmpty
                ? () {
                    Navigator.pop(context);
                    widget.onCast(widget.items.first);
                  }
                : null,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (val) {
              // Future: add more menu actions
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'help', child: Text('Help')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Route through phone toggle ──
          Material(
            color: cs.surfaceContainerLow,
            child: InkWell(
              onTap: () {
                setState(() => _routeThroughPhone = !_routeThroughPhone);
                widget.onToggleRoute();
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.phone_android,
                        size: 20, color: cs.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Route video through phone',
                        style: tt.bodyMedium?.copyWith(color: cs.onSurface),
                      ),
                    ),
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: _routeThroughPhone,
                        onChanged: (_) {
                          setState(
                              () => _routeThroughPhone = !_routeThroughPhone);
                          widget.onToggleRoute();
                        },
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          // ── Video items list ──
          Expanded(
            child: widget.items.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.videocam_off,
                            size: 48,
                            color: cs.onSurfaceVariant.withAlpha(100)),
                        const SizedBox(height: 12),
                        Text('No videos detected',
                            style: tt.bodyLarge
                                ?.copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: widget.items.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 80),
                    itemBuilder: (ctx, i) {
                      final video = widget.items[i];
                      return _VideoListTile(
                        video: video,
                        pageTitle: widget.pageTitle,
                        thumbnailUrl: widget.thumbnailUrl,
                        onTap: () {
                          Navigator.pop(context);
                          widget.onCast(video);
                        },
                        onDownload: () {
                          widget.onDownload(video);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Video List Tile (WVC-style) ─────────────────────────────────────────────

class _VideoListTile extends StatelessWidget {
  final _DetectedVideo video;
  final String pageTitle;
  final String? thumbnailUrl;
  final VoidCallback onTap;
  final VoidCallback onDownload;

  const _VideoListTile({
    required this.video,
    required this.pageTitle,
    this.thumbnailUrl,
    required this.onTap,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Thumbnail ──
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 60,
                height: 44,
                child: thumbnailUrl != null && thumbnailUrl!.isNotEmpty
                    ? Image.network(
                        thumbnailUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: cs.surfaceContainerHighest,
                          child: Icon(Icons.play_circle_outline,
                              size: 24, color: cs.onSurfaceVariant),
                        ),
                      )
                    : Container(
                        color: cs.surfaceContainerHighest,
                        child: Icon(Icons.play_circle_outline,
                            size: 24, color: cs.onSurfaceVariant),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            // ── Info column ──
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Page title
                  Text(
                    pageTitle.isNotEmpty ? pageTitle : 'Untitled',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // Host domain
                  Text(
                    video.hostLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  // Stream label + format badge row
                  Row(
                    children: [
                      if (video.streamLabel.isNotEmpty)
                        Flexible(
                          child: Text(
                            video.streamLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      if (video.streamLabel.isNotEmpty)
                        const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2E7D32),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          video.formatBadge,
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // ── Three-dot menu ──
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, size: 20, color: cs.onSurfaceVariant),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onSelected: (val) {
                switch (val) {
                  case 'cast':
                    onTap();
                    break;
                  case 'download':
                    onDownload();
                    break;
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'cast',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.cast, size: 20),
                    title: Text('Cast', style: TextStyle(fontSize: 13)),
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const PopupMenuItem(
                  value: 'download',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.download, size: 20),
                    title: Text('Download', style: TextStyle(fontSize: 13)),
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
