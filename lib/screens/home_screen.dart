import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/app_state.dart';
import '../models/video_info.dart';
import '../models/dlna_device.dart';
import '../services/dlna_service.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _urlController = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _urlController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _extract() {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a URL starting with http:// or https://'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    ref.read(selectedFormatProvider.notifier).state = null;
    ref.read(selectedDeviceProvider.notifier).state = null;
    ref.read(videoProvider.notifier).extract(url);
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final videoState = ref.watch(videoProvider);
    final formatSelected = ref.watch(selectedFormatProvider) != null;
    final castState = ref.watch(castProvider);
    final isCasting = castState is CastPlaying;

    return Scaffold(
      appBar: AppBar(
        leading: const Padding(
          padding: EdgeInsets.all(12.0),
          child: Icon(Icons.cast, size: 24),
        ),
        title: const Text('Video Caster'),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => _showSettings(context),
          ),
        ],
      ),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          // ── Step 1: URL input ────────────────────────────────────────────────
          _StepCard(
            step: 1,
            title: 'Paste a video URL',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _urlController,
                  decoration: InputDecoration(
                    hintText: 'YouTube URL, or direct .mp4 / .m3u8…',
                    prefixIcon: const Icon(Icons.link),
                    suffixIcon: videoState is VideoLoading
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            icon: const Icon(Icons.search),
                            onPressed: _extract,
                          ),
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _extract(),
                ),
                if (videoState is VideoError) ...[
                  const SizedBox(height: 8),
                  _ErrorBanner(videoState.message),
                ],
              ],
            ),
          ),

          // ── Step 2: Video info + format picker ───────────────────────────────
          if (videoState is VideoLoaded) ...[
            const SizedBox(height: 12),
            _StepCard(
              step: 2,
              title: 'Choose quality',
              child: _FormatPicker(info: videoState.info),
            ),
          ],

          // ── Step 3: Device discovery ─────────────────────────────────────────
          if (videoState is VideoLoaded && formatSelected) ...[
            const SizedBox(height: 12),
            _StepCard(
              step: 3,
              title: 'Find your TV',
              child: const _DeviceList(),
            ),
          ],

          // ── Step 4: Cast controls ────────────────────────────────────────────
          if (isCasting || castState is CastPreparing || castState is CastError) ...[
            const SizedBox(height: 12),
            _StepCard(
              step: 4,
              title: 'Now casting',
              child: const _CastControls(),
            ),
          ],
        ],
      ),
      // ── Bottom: Route-through-phone toggle ──────────────────────────────────
      bottomNavigationBar: const _RouteToggleBar(),
    );
  }

  void _showSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _SettingsSheet(),
    );
  }
}

// ── _StepCard ─────────────────────────────────────────────────────────────────

class _StepCard extends StatelessWidget {
  final int step;
  final String title;
  final Widget child;

  const _StepCard({required this.step, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: cs.primary,
                  child: Text(
                    '$step',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: cs.onPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

// ── _ErrorBanner ──────────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner(this.message);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Icon(Icons.error_outline, size: 18, color: cs.onErrorContainer),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message,
              style: TextStyle(color: cs.onErrorContainer, fontSize: 13)),
        ),
      ]),
    );
  }
}

// ── _FormatPicker ─────────────────────────────────────────────────────────────

class _FormatPicker extends ConsumerWidget {
  final VideoInfo info;
  const _FormatPicker({required this.info});

  String _fmtSize(int? bytes) {
    if (bytes == null) return '';
    final mb = bytes / (1024 * 1024);
    return mb >= 1024 ? '${(mb / 1024).toStringAsFixed(1)} GB' : '${mb.toStringAsFixed(0)} MB';
  }

  String _fmtDuration(int? secs) {
    if (secs == null) return '';
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    String pad(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${pad(m)}:${pad(s)}' : '${pad(m)}:${pad(s)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedFormatProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Video info row
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (info.thumbnailUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: info.thumbnailUrl!,
                  width: 100,
                  height: 60,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => Container(
                    width: 100,
                    height: 60,
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.video_file),
                  ),
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(info.title,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (info.uploader != null) info.uploader!,
                      if (info.durationSeconds != null) _fmtDuration(info.durationSeconds),
                    ].join(' · '),
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 14),

        // Format list
        ...info.formats.map((f) {
          final isSelected = selected?.id == f.id;
          final cs = Theme.of(context).colorScheme;
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => ref.read(selectedFormatProvider.notifier).state = f,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isSelected ? cs.primary : cs.outlineVariant,
                    width: isSelected ? 2 : 1,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  color: isSelected ? cs.primaryContainer.withAlpha(80) : null,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Icon(
                      f.hasAudio ? Icons.hd_rounded : Icons.videocam_off_outlined,
                      size: 20,
                      color: isSelected ? cs.primary : cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        f.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                    if (f.filesize != null)
                      Text(
                        _fmtSize(f.filesize),
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                    if (isSelected) ...[
                      const SizedBox(width: 8),
                      Icon(Icons.check_circle, size: 18, color: cs.primary),
                    ],
                  ],
                ),
              ),
            ),
          );
        }),
      ],
    );
  }
}

// ── _DeviceList ───────────────────────────────────────────────────────────────

class _DeviceList extends ConsumerWidget {
  const _DeviceList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devicesState = ref.watch(devicesProvider);
    final selectedDevice = ref.watch(selectedDeviceProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              icon: devicesState is DevicesScanning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.search),
              label: Text(devicesState is DevicesScanning ? 'Scanning…' : 'Scan for TVs'),
              onPressed: devicesState is DevicesScanning
                  ? null
                  : () => ref.read(devicesProvider.notifier).scan(),
            ),
          ),
        ]),

        if (devicesState is DevicesResult) ...[
          const SizedBox(height: 10),
          if (devicesState.devices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No DLNA/UPnP devices found.\nMake sure your TV is on and on the same WiFi network.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
              ),
            )
          else
            ...devicesState.devices.map((d) => _DeviceTile(
                  device: d,
                  isSelected: selectedDevice == d,
                  onTap: () => ref.read(selectedDeviceProvider.notifier).state = d,
                )),
        ],

        if (devicesState is DevicesError) ...[
          const SizedBox(height: 8),
          _ErrorBanner(devicesState.message),
        ],
      ],
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final DlnaDevice device;
  final bool isSelected;
  final VoidCallback onTap;

  const _DeviceTile({
    required this.device,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: isSelected ? cs.primary : cs.outlineVariant,
            width: isSelected ? 2 : 1,
          ),
        ),
        tileColor: isSelected ? cs.primaryContainer.withAlpha(80) : null,
        leading: Icon(Icons.tv, color: isSelected ? cs.primary : cs.onSurfaceVariant),
        title: Text(device.name,
            style: TextStyle(
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal, fontSize: 14)),
        subtitle: device.manufacturer.isNotEmpty
            ? Text(device.manufacturer, style: const TextStyle(fontSize: 12))
            : null,
        trailing: isSelected ? Icon(Icons.check_circle, color: cs.primary) : null,
        onTap: onTap,
      ),
    );
  }
}

// ── _CastControls ─────────────────────────────────────────────────────────────

class _CastControls extends ConsumerStatefulWidget {
  const _CastControls();

  @override
  ConsumerState<_CastControls> createState() => _CastControlsState();
}

class _CastControlsState extends ConsumerState<_CastControls> {
  // Volume is kept as local UI state; 0–100, null = not yet known.
  double? _volume;
  bool _volumeLoading = false;

  Future<void> _fetchVolume(DlnaDevice device) async {
    if (_volumeLoading) return;
    setState(() => _volumeLoading = true);
    try {
      final v = await ref.read(dlnaServiceProvider).getVolume(device);
      if (mounted && v != null) setState(() => _volume = v.toDouble());
    } finally {
      if (mounted) setState(() => _volumeLoading = false);
    }
  }

  Future<void> _setVolume(DlnaDevice device, double v) async {
    setState(() => _volume = v);
    await ref.read(dlnaServiceProvider).setVolume(device, v.round());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final castState = ref.watch(castProvider);
    final progress = ref.watch(castPositionProvider);
    final videoState = ref.watch(videoProvider);
    final selectedDevice = ref.watch(selectedDeviceProvider);
    final selectedFormat = ref.watch(selectedFormatProvider);
    final settings = ref.watch(settingsProvider);
    final cs = Theme.of(context).colorScheme;

    if (castState is CastError) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ErrorBanner(castState.message),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: () => ref.read(castProvider.notifier).stop(),
            child: const Text('Dismiss'),
          ),
        ],
      );
    }

    if (castState is CastPreparing) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('Starting stream…'),
            ],
          ),
        ),
      );
    }

    if (castState is CastPlaying) {
      // Fetch current volume from TV once when we first see a device.
      if (_volume == null && castState.device.renderingControlUrl != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _fetchVolume(castState.device),
        );
      }

      final total = progress.total.inSeconds;
      final pos = progress.position.inSeconds.clamp(0, total > 0 ? total : 1);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Now playing info
          Row(children: [
            Icon(Icons.cast_connected, color: cs.primary, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(castState.title,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text(castState.device.name,
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                ],
              ),
            ),
            if (castState.routedThroughPhone)
              Tooltip(
                message: 'Routing through phone',
                child: Icon(Icons.phone_android, size: 16, color: cs.tertiary),
              ),
          ]),

          // Progress bar
          if (total > 0) ...[
            const SizedBox(height: 12),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(trackHeight: 3),
              child: Slider(
                value: pos.toDouble(),
                min: 0,
                max: total.toDouble(),
                onChanged: (v) {}, // visual only while dragging
                onChangeEnd: (v) =>
                    ref.read(castProvider.notifier).seek(Duration(seconds: v.toInt())),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(progress.position), style: const TextStyle(fontSize: 11)),
                  Text(_fmt(progress.total), style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),

          // Controls row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton.filled(
                icon: Icon(castState.isPaused ? Icons.play_arrow : Icons.pause),
                onPressed: () => ref.read(castProvider.notifier).pauseResume(),
                tooltip: castState.isPaused ? 'Resume' : 'Pause',
              ),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
                onPressed: () {
                  setState(() => _volume = null);
                  ref.read(castProvider.notifier).stop();
                },
              ),
            ],
          ),

          // Volume row — only shown when the TV supports RenderingControl.
          if (castState.device.renderingControlUrl != null) ...[  
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.volume_down, size: 18),
                Expanded(
                  child: Slider(
                    value: (_volume ?? 50).clamp(0, 100).toDouble(),
                    min: 0,
                    max: 100,
                    divisions: 20,
                    label: '${(_volume ?? 50).round()}',
                    onChanged: (v) => setState(() => _volume = v),
                    onChangeEnd: (v) => _setVolume(castState.device, v),
                  ),
                ),
                const Icon(Icons.volume_up, size: 18),
              ],
            ),
          ],
        ],
      );
    }

    // Idle but step 4 visible means ready to cast
    if (selectedDevice != null && selectedFormat != null && videoState is VideoLoaded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            icon: const Icon(Icons.cast),
            label: const Text('Cast to TV'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            onPressed: () => ref.read(castProvider.notifier).cast(
                  device: selectedDevice,
                  format: selectedFormat,
                  title: videoState.info.title,
                  routeThroughPhone: settings.routeThroughPhone,
                ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.tv, size: 14, color: cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(selectedDevice.name,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            const SizedBox(width: 12),
            Icon(Icons.hd_rounded, size: 14, color: cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Expanded(
              child: Text(selectedFormat.label,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
        ],
      );
    }

    return const SizedBox.shrink();
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

// ── _RouteToggleBar ───────────────────────────────────────────────────────────

class _RouteToggleBar extends ConsumerWidget {
  const _RouteToggleBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final cs = Theme.of(context).colorScheme;
    final active = settings.routeThroughPhone;

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: active
              ? cs.secondaryContainer.withAlpha(200)
              : cs.surfaceContainerHighest.withAlpha(160),
          border: Border(top: BorderSide(color: cs.outlineVariant)),
        ),
        child: Row(
          children: [
            Icon(
              Icons.phone_android,
              size: 20,
              color: active ? cs.secondary : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Route through phone',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: active ? cs.onSecondaryContainer : cs.onSurface,
                    ),
                  ),
                  Text(
                    active
                        ? 'Phone proxies the stream to your TV'
                        : 'TV fetches stream directly from internet',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Switch(
              value: active,
              onChanged: (_) => ref.read(settingsProvider.notifier).toggle(),
            ),
          ],
        ),
      ),
    );
  }
}

// ── _SettingsSheet ────────────────────────────────────────────────────────────

class _SettingsSheet extends ConsumerWidget {
  const _SettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Settings', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),

          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Route through phone'),
            subtitle: const Text(
              'When ON, the phone proxies the video stream to the TV. '
              'Recommended for YouTube and sites that restrict direct TV access.',
            ),
            value: settings.routeThroughPhone,
            onChanged: (_) => ref.read(settingsProvider.notifier).toggle(),
          ),

          const Divider(),

          const _SupportedSitesTile(),
        ],
      ),
    );
  }
}

class _SupportedSitesTile extends StatelessWidget {
  const _SupportedSitesTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.info_outline),
      title: const Text('Supported sources'),
      subtitle: const Text(
        'YouTube (full quality picker)\n'
        'Direct video URLs (.mp4, .m3u8, .webm, .mkv)\n'
        'Any DLNA/UPnP-compatible TV or renderer',
      ),
      isThreeLine: true,
    );
  }
}
