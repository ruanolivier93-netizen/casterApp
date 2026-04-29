import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../providers/app_state.dart';
import '../widgets/mini_player.dart';
import 'home_screen.dart';
import 'browser_screen.dart';
import 'local_files_screen.dart';

/// Root shell that hosts the two tabs: Cast and Browse.
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  int _tabIndex = 0;
  bool _browserInitialised = false;
  InAppWebViewController? _webController;
  StreamSubscription? _shareSub;

  static const _shareChannel = MethodChannel('com.videocaster/share');
  static const _shareStream = EventChannel('com.videocaster/share_stream');

  bool _isMissingPlugin(Object error) =>
      error is MissingPluginException ||
      error is PlatformException && error.code == 'channel-error';

  @override
  void initState() {
    super.initState();
    // Handle URL shared while app was closed
    _shareChannel.invokeMethod<String>('getInitialSharedUrl').then((url) {
      if (url != null) _handleSharedUrl(url);
    }).catchError((error, stackTrace) {
      if (_isMissingPlugin(error)) {
        return;
      }
      throw error;
    });
    // Handle URL shared while app is running
    _shareSub = _shareStream.receiveBroadcastStream().listen(
      (url) {
        if (url is String) _handleSharedUrl(url);
      },
      onError: (error, stackTrace) {
        if (_isMissingPlugin(error)) {
          return;
        }
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'main_shell',
            context: ErrorDescription('while listening for shared URLs'),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    super.dispose();
  }

  void _handleSharedUrl(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      setState(() => _tabIndex = 0);
      ref.read(browserCastUrlProvider.notifier).state = url;
      ref.read(videoProvider.notifier).extract(url);
    }
  }

  /// Called from BrowserScreen when the user taps "Cast this page".
  void _onCastUrlFromBrowser(String url) {
    // Put the URL in the provider so the Cast tab also picks it up,
    // but do NOT switch tabs — the browser has its own cast controls.
    ref.read(browserCastUrlProvider.notifier).state = url;
    ref.read(selectedFormatProvider.notifier).state = null;

    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';
    final path = uri?.path.toLowerCase() ?? '';
    const videoExts = [
      '.mp4', '.m4v', '.webm', '.mkv', '.avi', '.mov', '.flv',
      '.ts', '.3gp', '.wmv', '.ogv', '.m3u8', '.mpd',
    ];

    if (host.contains('youtube.com') || host.contains('youtu.be') ||
        host.contains('m.youtube.com')) {
      ref.read(videoProvider.notifier).extract(url);
    } else if (videoExts.any((e) => path.contains(e))) {
      ref.read(videoProvider.notifier).loadDirect(url);
    } else {
      ref.read(videoProvider.notifier).extract(url);
    }
    // Stay on the browser tab — cast panel shows inline.
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_tabIndex == 1 && _webController != null) {
          if (await _webController!.canGoBack()) {
            await _webController!.goBack();
            return;
          }
          setState(() => _tabIndex = 0);
          return;
        }
        if (_tabIndex != 0) {
          setState(() => _tabIndex = 0);
          return;
        }
        SystemNavigator.pop();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: IndexedStack(
          index: _tabIndex,
          children: [
            const HomeScreen(),
            if (_browserInitialised)
              BrowserScreen(
                onCastUrl: _onCastUrlFromBrowser,
                onControllerCreated: (c) => _webController = c,
              )
            else
              const SizedBox.shrink(),
            const LocalFilesScreen(),
          ],
        ),
        bottomNavigationBar: isLandscape
            ? null
            : _SimpleBottomBar(
                selectedIndex: _tabIndex,
                onSelected: (i) {
                  if (i == 1 && !_browserInitialised) {
                    setState(() {
                      _browserInitialised = true;
                      _tabIndex = i;
                    });
                  } else {
                    setState(() => _tabIndex = i);
                  }
                },
              ),
      ),
    );
  }
}

class _SimpleBottomBar extends StatelessWidget {
  const _SimpleBottomBar({
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MiniPlayer(),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardTheme.color,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: cs.outlineVariant),
              ),
              padding: const EdgeInsets.all(6),
              child: Row(
                children: [
                  _SimpleNavItem(
                    label: 'Cast',
                    icon: Icons.cast_outlined,
                    selectedIcon: Icons.cast,
                    selected: selectedIndex == 0,
                    onTap: () => onSelected(0),
                  ),
                  _SimpleNavItem(
                    label: 'Browse',
                    icon: Icons.language_outlined,
                    selectedIcon: Icons.language,
                    selected: selectedIndex == 1,
                    onTap: () => onSelected(1),
                  ),
                  _SimpleNavItem(
                    label: 'Files',
                    icon: Icons.folder_outlined,
                    selectedIcon: Icons.folder,
                    selected: selectedIndex == 2,
                    onTap: () => onSelected(2),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SimpleNavItem extends StatelessWidget {
  const _SimpleNavItem({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: selected ? (Theme.of(context).brightness == Brightness.dark ? const Color(0xFF23272B) : const Color(0xFFE7E0D6)) : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(selected ? selectedIcon : icon, color: selected ? cs.primary : cs.onSurfaceVariant, size: 21),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    color: selected ? cs.onSurface : cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
