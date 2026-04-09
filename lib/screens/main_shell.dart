import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state.dart';
import '../widgets/mini_player.dart';
import 'home_screen.dart';
import 'browser_screen.dart';

/// Root shell that hosts the two tabs: Cast and Browse.
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  int _tabIndex = 0;
  bool _browserInitialised = false;

  /// Called from BrowserScreen when the user taps "Cast this page".
  void _onCastUrlFromBrowser(String url) {
    // Pre-fill the URL, trigger extraction, and switch to the Cast tab.
    ref.read(browserCastUrlProvider.notifier).state = url;
    ref.read(selectedFormatProvider.notifier).state = null;
    ref.read(selectedDeviceProvider.notifier).state = null;
    ref.read(videoProvider.notifier).extract(url);
    setState(() => _tabIndex = 0);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: IndexedStack(
        index: _tabIndex,
        children: [
          const HomeScreen(),
          if (_browserInitialised)
            BrowserScreen(onCastUrl: _onCastUrlFromBrowser)
          else
            const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: Column(
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
            ],
          ),
        ],
      ),
    );
  }
}
