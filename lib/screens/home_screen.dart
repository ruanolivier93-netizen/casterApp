import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/app_state.dart';
import '../models/video_info.dart';
import '../models/dlna_device.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _urlController = TextEditingController();
  final _scroll = ScrollController();
  bool _autoScanned = false;

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
    ref.read(selectedSubtitleProvider.notifier).state = null;
    ref.read(videoProvider.notifier).extract(url);
    _autoScanned = false;
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final videoState = ref.watch(videoProvider);
    final devicesState = ref.watch(devicesProvider);
    final selectedFormat = ref.watch(selectedFormatProvider);
    final selectedDevice = ref.watch(selectedDeviceProvider);
    final castState = ref.watch(castProvider);
    final isCasting = castState is CastPlaying;
    final cs = Theme.of(context).colorScheme;

    // Auto-scan for TVs when video loads (only once per extract).
    if (videoState is VideoLoaded && !_autoScanned) {
      _autoScanned = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ds = ref.read(devicesProvider);
        if (ds is! DevicesScanning) {
          ref.read(devicesProvider.notifier).scan();
        }
      });
    }

    // Auto-fill URL from browser cast button.
    final browserUrl = ref.watch(browserCastUrlProvider);
    if (browserUrl != null && browserUrl.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _urlController.text = browserUrl;
        ref.read(browserCastUrlProvider.notifier).state = null;
      });
    }

    return Scaffold(
      appBar: AppBar(
        leading: const Padding(
          padding: EdgeInsets.all(12.0),
          child: Icon(Icons.cast, size: 24),
        ),
        title: const Text('Ruan Lelanie Caster'),
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
          // ── URL input ────────────────────────────────────────────────────
          _buildUrlInput(videoState, cs),

          // ── Cast History (shown when idle) ────────────────────────────────
          if (videoState is VideoIdle) ...[
            const SizedBox(height: 12),
            const _CastHistory(),
          ],

          // ── Video info + format picker + device + cast button ─────────────
          if (videoState is VideoLoaded) ...[
            const SizedBox(height: 12),
            _VideoInfoCard(info: videoState.info),
            const SizedBox(height: 12),
            _FormatPicker(info: videoState.info),
          ],

          // ── Device selection (shown once we have a video) ────────────────
          if (videoState is VideoLoaded) ...[
            const SizedBox(height: 12),
            _DeviceSection(
              devicesState: devicesState,
              selectedDevice: selectedDevice,
            ),
          ],

          // ── BIG CAST BUTTON — the star of the show ───────────────────────
          if (videoState is VideoLoaded &&
              selectedFormat != null &&
              selectedDevice != null &&
              castState is! CastPlaying &&
              castState is! CastPreparing) ...[
            const SizedBox(height: 16),
            _CastNowButton(
              videoState: videoState,
              format: selectedFormat,
              device: selectedDevice,
            ),
          ],

          // ── Cast controls ────────────────────────────────────────────────
          if (isCasting || castState is CastPreparing || castState is CastError) ...[
            const SizedBox(height: 12),
            _CastControls(videoState: videoState),
          ],
        ],
      ),
      persistentFooterButtons: [const _RouteToggleBar()],
    );
  }

  Widget _buildUrlInput(VideoState videoState, ColorScheme cs) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _urlController,
              decoration: InputDecoration(
                hintText: 'Paste YouTube URL or direct video link…',
                prefixIcon: const Icon(Icons.link),
                suffixIcon: videoState is VideoLoading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20, height: 20,
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
              const SizedBox(height: 6),
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Retry'),
                onPressed: _extract,
              ),
            ],
          ],
        ),
      ),
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

// ── Video Info Card ──────────────────────────────────────────────────────────

class _VideoInfoCard extends StatelessWidget {
  final VideoInfo info;
  const _VideoInfoCard({required this.info});

  String _fmtDuration(int? secs) {
    if (secs == null) return '';
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    String pad(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${pad(m)}:${pad(s)}' : '${pad(m)}:${pad(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (info.thumbnailUrl != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CachedNetworkImage(
              imageUrl: info.thumbnailUrl!,
              width: 110,
              height: 66,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => Container(
                width: 110, height: 66,
                color: cs.surfaceContainerHighest,
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
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Text(
                [
                  if (info.uploader != null) info.uploader!,
                  if (info.durationSeconds != null) _fmtDuration(info.durationSeconds),
                  '${info.formats.length} format${info.formats.length == 1 ? '' : 's'}',
                ].join(' · '),
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Format Picker ────────────────────────────────────────────────────────────

class _FormatPicker extends ConsumerWidget {
  final VideoInfo info;
  const _FormatPicker({required this.info});

  String _fmtSize(int? bytes) {
    if (bytes == null) return '';
    final mb = bytes / (1024 * 1024);
    return mb >= 1024 ? '${(mb / 1024).toStringAsFixed(1)} GB' : '${mb.toStringAsFixed(0)} MB';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedFormatProvider);
    final cs = Theme.of(context).colorScheme;

    // Auto-select highest quality muxed stream
    if (selected == null && info.formats.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(selectedFormatProvider.notifier).state = info.formats.first;
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Quality', style: TextStyle(
          fontWeight: FontWeight.w600, fontSize: 13, color: cs.onSurfaceVariant)),
        const SizedBox(height: 6),
        ...info.formats.map((f) {
          final isSelected = selected?.id == f.id;
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      f.hasAudio ? Icons.hd_rounded : Icons.videocam_off_outlined,
                      size: 20,
                      color: isSelected ? cs.primary : cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(f.label, style: TextStyle(
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    ))),
                    if (f.filesize != null)
                      Text(_fmtSize(f.filesize),
                          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
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

        // Subtitles
        if (info.subtitles.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('Subtitles', style: TextStyle(
            fontWeight: FontWeight.w600, fontSize: 13, color: cs.onSurfaceVariant)),
          const SizedBox(height: 6),
          _SubtitlePicker(subtitles: info.subtitles),
        ],
      ],
    );
  }
}

// ── Subtitle Picker ─────────────────────────────────────────────────────────

class _SubtitlePicker extends ConsumerWidget {
  final List<SubtitleTrack> subtitles;
  const _SubtitlePicker({required this.subtitles});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedSubtitleProvider);
    return Wrap(
      spacing: 6, runSpacing: 4,
      children: [
        ChoiceChip(
          label: const Text('None', style: TextStyle(fontSize: 12)),
          selected: selected == null,
          onSelected: (_) => ref.read(selectedSubtitleProvider.notifier).state = null,
          visualDensity: VisualDensity.compact,
        ),
        ...subtitles.map((s) => ChoiceChip(
              label: Text(s.label, style: const TextStyle(fontSize: 12)),
              selected: selected?.language == s.language,
              onSelected: (_) => ref.read(selectedSubtitleProvider.notifier).state = s,
              visualDensity: VisualDensity.compact,
            )),
      ],
    );
  }
}

// ── Device Section ──────────────────────────────────────────────────────────

class _DeviceSection extends ConsumerWidget {
  final DevicesState devicesState;
  final DlnaDevice? selectedDevice;
  const _DeviceSection({required this.devicesState, required this.selectedDevice});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final lastDeviceLocation = ref.watch(lastDeviceProvider);

    // Collect available devices from both scanning and result states.
    final List<DlnaDevice> devices;
    final bool isScanning;
    if (devicesState is DevicesScanning) {
      devices = (devicesState as DevicesScanning).devicesFoundSoFar;
      isScanning = true;
    } else if (devicesState is DevicesResult) {
      devices = (devicesState as DevicesResult).devices;
      isScanning = false;
    } else {
      devices = [];
      isScanning = devicesState is DevicesScanning;
    }

    // Auto-select last used device as soon as it appears
    if (selectedDevice == null && lastDeviceLocation != null && devices.isNotEmpty) {
      final match = devices.where((d) => d.location == lastDeviceLocation).firstOrNull;
      if (match != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ref.read(selectedDeviceProvider.notifier).state = match;
        });
      }
    }

    // Auto-select if only one device found and scan is complete
    if (selectedDevice == null && !isScanning && devices.length == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(selectedDeviceProvider.notifier).state = devices.first;
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.tv, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Text('Cast to', style: TextStyle(
              fontWeight: FontWeight.w600, fontSize: 13, color: cs.onSurfaceVariant)),
            const Spacer(),
            if (isScanning) ...[
              SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary)),
              const SizedBox(width: 6),
              Text('Scanning…', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ] else
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('Rescan', style: TextStyle(fontSize: 12)),
                onPressed: () => ref.read(devicesProvider.notifier).scan(),
              ),
          ],
        ),
        const SizedBox(height: 6),

        if (devices.isEmpty && !isScanning && devicesState is! DevicesIdle)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              children: [
                Text(
                  'No TVs found. Make sure your TV is on and connected to the same WiFi.',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Scan again'),
                  onPressed: () => ref.read(devicesProvider.notifier).scan(),
                ),
              ],
            ),
          ),

        if (devices.isEmpty && (isScanning || devicesState is DevicesIdle))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('Looking for TVs on your network…',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
          ),

        ...devices.map((d) {
          final isSelected = selectedDevice == d;
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: ListTile(
              dense: true,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(
                  color: isSelected ? cs.primary : cs.outlineVariant,
                  width: isSelected ? 2 : 1,
                ),
              ),
              tileColor: isSelected ? cs.primaryContainer.withAlpha(80) : null,
              leading: Icon(Icons.tv, color: isSelected ? cs.primary : cs.onSurfaceVariant, size: 22),
              title: Text(d.name,
                  style: TextStyle(
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    fontSize: 14,
                  )),
              subtitle: d.manufacturer.isNotEmpty
                  ? Text(d.manufacturer, style: const TextStyle(fontSize: 11))
                  : null,
              trailing: isSelected
                  ? Icon(Icons.check_circle, color: cs.primary, size: 20)
                  : null,
              onTap: () => ref.read(selectedDeviceProvider.notifier).state = d,
            ),
          );
        }),

        if (devicesState is DevicesError) ...[
          const SizedBox(height: 8),
          _ErrorBanner((devicesState as DevicesError).message),
          const SizedBox(height: 6),
          TextButton.icon(
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Retry scan'),
            onPressed: () => ref.read(devicesProvider.notifier).scan(),
          ),
        ],
      ],
    );
  }
}

// ── Cast Now Button ─────────────────────────────────────────────────────────

class _CastNowButton extends ConsumerWidget {
  final VideoLoaded videoState;
  final StreamFormat format;
  final DlnaDevice device;
  const _CastNowButton({
    required this.videoState,
    required this.format,
    required this.device,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          icon: const Icon(Icons.cast, size: 22),
          label: Text('Cast to ${device.name}'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            backgroundColor: cs.primary,
            foregroundColor: cs.onPrimary,
          ),
          onPressed: () {
            final selectedSub = ref.read(selectedSubtitleProvider);
            final subs = videoState.info.subtitles;
            final sub = selectedSub ?? (subs.isNotEmpty ? subs.first : null);

            ref.read(castHistoryProvider.notifier).add(
              videoState.sourceUrl,
              videoState.info.title,
              videoState.info.thumbnailUrl,
            );
            ref.read(lastDeviceProvider.notifier).save(device.location);

            ref.read(castProvider.notifier).cast(
              device: device,
              format: format,
              title: videoState.info.title,
              routeThroughPhone: settings.routeThroughPhone,
              subtitleSrt: sub?.srtContent,
              durationSeconds: videoState.info.durationSeconds,
            );
          },
        ),
        const SizedBox(height: 6),
        Row(children: [
          Icon(Icons.tv, size: 12, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(device.name,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          const SizedBox(width: 12),
          Icon(Icons.hd_rounded, size: 12, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Expanded(
            child: Text(format.label,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                overflow: TextOverflow.ellipsis),
          ),
        ]),
      ],
    );
  }
}

// ── Cast Controls ───────────────────────────────────────────────────────────

class _CastControls extends ConsumerStatefulWidget {
  final VideoState? videoState;
  const _CastControls({this.videoState});

  @override
  ConsumerState<_CastControls> createState() => _CastControlsState();
}

class _CastControlsState extends ConsumerState<_CastControls> {
  double? _volume;
  bool _volumeLoading = false;
  bool _volumeFetched = false;

  Future<void> _fetchVolume(DlnaDevice device) async {
    if (_volumeLoading || _volumeFetched) return;
    setState(() => _volumeLoading = true);
    try {
      final v = await ref.read(dlnaServiceProvider).getVolume(device);
      _volumeFetched = true;
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
  Widget build(BuildContext context) {
    final castState = ref.watch(castProvider);
    final progress = ref.watch(castPositionProvider);
    final cs = Theme.of(context).colorScheme;

    if (castState is CastError) {
      return Card(
        elevation: 0,
        color: cs.errorContainer.withAlpha(60),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ErrorBanner(castState.message),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: () => ref.read(castProvider.notifier).stop(),
                child: const Text('Dismiss'),
              ),
            ],
          ),
        ),
      );
    }

    if (castState is CastPreparing) {
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: const Padding(
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
      if (!_volumeFetched && castState.device.renderingControlUrl != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _fetchVolume(castState.device),
        );
      }

      final total = progress.total.inSeconds;
      final pos = progress.position.inSeconds.clamp(0, total > 0 ? total : 1);

      return Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: cs.primaryContainer.withAlpha(40),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Now playing
              Row(children: [
                Icon(Icons.cast_connected, color: cs.primary, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(castState.title,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text('on ${castState.device.name}',
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

              // Progress
              if (total > 0) ...[
                const SizedBox(height: 12),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 3),
                  child: Slider(
                    value: pos.toDouble(),
                    min: 0,
                    max: total.toDouble(),
                    onChanged: (v) {},
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

              // Controls
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton.filled(
                    icon: Icon(castState.isPaused ? Icons.play_arrow : Icons.pause, size: 28),
                    iconSize: 28,
                    onPressed: () => ref.read(castProvider.notifier).pauseResume(),
                    tooltip: castState.isPaused ? 'Resume' : 'Pause',
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
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

              // Volume
              if (castState.device.renderingControlUrl != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.volume_down, size: 18),
                    Expanded(
                      child: Slider(
                        value: (_volume ?? 50).clamp(0, 100).toDouble(),
                        min: 0, max: 100, divisions: 20,
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
          ),
        ),
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

// ── Cast History ────────────────────────────────────────────────────────────

class _CastHistory extends ConsumerWidget {
  const _CastHistory();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(castHistoryProvider);
    if (history.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.history, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Text('Recently Cast', style: TextStyle(
              fontWeight: FontWeight.w600, fontSize: 14, color: cs.onSurfaceVariant)),
            const Spacer(),
            TextButton(
              onPressed: () => ref.read(castHistoryProvider.notifier).clear(),
              child: const Text('Clear', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ...history.take(5).map((item) => ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: item.thumbnailUrl != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.network(
                        item.thumbnailUrl!,
                        width: 48, height: 28, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 48, height: 28,
                          color: cs.surfaceContainerHighest,
                          child: const Icon(Icons.video_file, size: 16),
                        ),
                      ),
                    )
                  : Icon(Icons.play_circle_outline, color: cs.primary),
              title: Text(item.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)),
              subtitle: Text(_timeAgo(item.castAt),
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              trailing: IconButton(
                icon: Icon(Icons.replay, size: 18, color: cs.primary),
                tooltip: 'Cast again',
                onPressed: () {
                  ref.read(selectedFormatProvider.notifier).state = null;
                  ref.read(selectedDeviceProvider.notifier).state = null;
                  ref.read(videoProvider.notifier).extract(item.url);
                },
              ),
            )),
      ],
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

// ── Error Banner ────────────────────────────────────────────────────────────

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

// ── Route Toggle Bar ────────────────────────────────────────────────────────

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
            Icon(Icons.phone_android, size: 20,
                color: active ? cs.secondary : cs.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Route through phone', style: TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13,
                    color: active ? cs.onSecondaryContainer : cs.onSurface,
                  )),
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

// ── Settings Sheet ──────────────────────────────────────────────────────────

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
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline),
            title: const Text('Supported sources'),
            subtitle: const Text(
              'YouTube (full quality picker)\n'
              'Direct video URLs (.mp4, .m3u8, .webm, .mkv)\n'
              'Any DLNA/UPnP-compatible TV or renderer',
            ),
            isThreeLine: true,
          ),
        ],
      ),
    );
  }
}
