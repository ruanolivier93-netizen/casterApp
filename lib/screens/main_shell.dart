import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';
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
  WebViewController? _webController;

  /// Called from BrowserScreen when the user taps "Cast this page".
  void _onCastUrlFromBrowser(String url) {
    ref.read(browserCastUrlProvider.notifier).state = url;
    ref.read(selectedFormatProvider.notifier).state = null;
    ref.read(selectedDeviceProvider.notifier).state = null;

    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';
    final path = uri?.path.toLowerCase() ?? '';
    const videoExts = [
      '.mp4', '.m4v', '.webm', '.mkv', '.avi', '.mov', '.flv',
      '.ts', '.3gp', '.wmv', '.ogv', '.m3u8', '.mpd',
    ];

    if (host.contains('youtube.com') || host.contains('youtu.be') ||
        host.contains('m.youtube.com')) {
      // YouTube — use full extractor for quality picker
      ref.read(videoProvider.notifier).extract(url);
    } else if (videoExts.any((e) => path.contains(e))) {
      // Direct video URL — skip HEAD check, load immediately
      ref.read(videoProvider.notifier).loadDirect(url);
    } else {
      // Unknown — try extraction
      ref.read(videoProvider.notifier).extract(url);
    }
    setState(() => _tabIndex = 0);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
            : Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Mini player — visible on all tabs when casting
            const MiniPlayer(),
            NavigationBar(
              selectedIndex: _tabIndex,
              onDestinationSelected: (i) {
                if (i == 1 && !_browserInitialised) {
                  setState(() {
                    _browserInitialised = true;
                    _tabIndex = i;
                  });
                } else {
                  setState(() => _tabIndex = i);
                }
              },
              height: 64,
              indicatorColor: cs.primaryContainer,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.cast_outlined),
                  selectedIcon: Icon(Icons.cast),
                  label: 'Cast',
                ),
                NavigationDestination(
                  icon: Icon(Icons.language_outlined),
                  selectedIcon: Icon(Icons.language),
                  label: 'Browse',
                ),
                NavigationDestination(
                  icon: Icon(Icons.folder_outlined),
                  selectedIcon: Icon(Icons.folder),
                  label: 'Files',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
