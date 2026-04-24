import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import '../providers/app_state.dart';
import '../providers/bookmarks_history.dart';
import '../providers/privacy_telemetry.dart';
import '../providers/queue_provider.dart';
import '../services/subtitle_service.dart';
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

    // Auto-scan for TVs whenever a new video loads.
    ref.listen<VideoState>(videoProvider, (prev, next) {
      if (next is VideoLoaded && prev is! VideoLoaded) {
        final ds = ref.read(devicesProvider);
        if (ds is! DevicesScanning) {
          ref.read(devicesProvider.notifier).scan();
        }
      }
    });

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
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),        children: [
          // ── URL input (always visible) ───────────────────────────────────
          _buildUrlInput(videoState, cs),

          // ── Animated content area — no layout jumps ──────────────────────
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Cast History (idle only)
                if (videoState is VideoIdle) ...[
                  const SizedBox(height: 16),
                  const _CastHistory(),
                ],

                // Video info + format picker
                if (videoState is VideoLoaded) ...[
                  const SizedBox(height: 16),
                  _VideoInfoCard(info: videoState.info),
                  const SizedBox(height: 12),
                  _FormatPicker(info: videoState.info),
                ],

                // Device selection
                if (videoState is VideoLoaded) ...[
                  const SizedBox(height: 12),
                  _DeviceSection(
                    devicesState: devicesState,
                    selectedDevice: selectedDevice,
                  ),
                ],

                // Big cast button
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  child: videoState is VideoLoaded &&
                          selectedFormat != null &&
                          selectedDevice != null &&
                          castState is! CastPlaying &&
                          castState is! CastPreparing
                      ? Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: _CastNowButton(
                            videoState: videoState,
                            format: selectedFormat,
                            device: selectedDevice,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),

                // Cast controls — AnimatedSwitcher for smooth state changes
                AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  child: (isCasting ||
                          castState is CastPreparing ||
                          castState is CastError)
                      ? Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 350),
                            switchInCurve: Curves.easeOut,
                            switchOutCurve: Curves.easeIn,
                            transitionBuilder: (child, anim) => FadeTransition(
                              opacity: anim,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, 0.04),
                                  end: Offset.zero,
                                ).animate(anim),
                                child: child,
                              ),
                            ),
                            child: _CastControls(
                              key: ValueKey(castState.runtimeType),
                              videoState: videoState,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),

                // Queue
                const SizedBox(height: 12),
                const _QueueSection(),

                // Route toggle — inline card, no footer jumps
                const SizedBox(height: 12),
                const _RouteToggleBar(),

                // Subtitle search
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  child: videoState is VideoLoaded
                      ? Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: _SubtitleSearchSection(
                              title: videoState.info.title),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUrlInput(VideoState videoState, ColorScheme cs) {
    return Card(
      color: cs.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _urlController,
              decoration: InputDecoration(
                hintText: 'Paste YouTube URL or direct video link…',
                prefixIcon: Icon(Icons.link_rounded,
                    color: cs.onSurfaceVariant, size: 20),
                suffixIcon: videoState is VideoLoading
                    ? Padding(
                        padding: const EdgeInsets.all(13),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: cs.primary),
                        ),
                      )
                    : IconButton(
                        icon: Icon(Icons.search_rounded, color: cs.primary),
                        onPressed: _extract,
                        tooltip: 'Extract video',
                      ),
              ),
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _extract(),
            ),
            // Error state — inline, no layout jump
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: videoState is VideoError
                  ? Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              size: 16, color: cs.error),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              videoState.message,
                              style: TextStyle(
                                  fontSize: 12, color: cs.error),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          TextButton(
                            onPressed: _extract,
                            child: const Text('Retry',
                                style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
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
                width: 110,
                height: 66,
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
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Text(
                [
                  if (info.uploader != null) info.uploader!,
                  if (info.durationSeconds != null)
                    _fmtDuration(info.durationSeconds),
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
    return mb >= 1024
        ? '${(mb / 1024).toStringAsFixed(1)} GB'
        : '${mb.toStringAsFixed(0)} MB';
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
        Text('Quality',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: cs.onSurfaceVariant)),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      f.hasAudio
                          ? Icons.hd_rounded
                          : Icons.videocam_off_outlined,
                      size: 20,
                      color: isSelected ? cs.primary : cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(f.label,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ))),
                    if (f.filesize != null)
                      Text(_fmtSize(f.filesize),
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant)),
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
          Text('Subtitles',
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: cs.onSurfaceVariant)),
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
      spacing: 6,
      runSpacing: 4,
      children: [
        ChoiceChip(
          label: const Text('None', style: TextStyle(fontSize: 12)),
          selected: selected == null,
          onSelected: (_) =>
              ref.read(selectedSubtitleProvider.notifier).state = null,
          visualDensity: VisualDensity.compact,
        ),
        ...subtitles.map((s) => ChoiceChip(
              label: Text(s.label, style: const TextStyle(fontSize: 12)),
              selected: selected?.language == s.language,
              onSelected: (_) =>
                  ref.read(selectedSubtitleProvider.notifier).state = s,
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
  const _DeviceSection(
      {required this.devicesState, required this.selectedDevice});

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
            Text('Cast to',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: cs.onSurfaceVariant)),
            const Spacer(),
            if (isScanning) ...[
              SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: cs.primary)),
              const SizedBox(width: 6),
              Text('Scanning…',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
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
              leading: Icon(Icons.tv,
                  color: isSelected ? cs.primary : cs.onSurfaceVariant,
                  size: 22),
              title: Text(d.name,
                  style: TextStyle(
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.normal,
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
        FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 18),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
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
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cast_rounded, size: 22),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  'Cast to ${device.name}',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.hd_rounded, size: 13, color: cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Flexible(
              child: Text(format.label,
                  style: TextStyle(
                      fontSize: 12, color: cs.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Cast Controls ───────────────────────────────────────────────────────────

class _CastControls extends ConsumerStatefulWidget {
  final VideoState? videoState;
  const _CastControls({super.key, this.videoState});

  @override
  ConsumerState<_CastControls> createState() => _CastControlsState();
}

class _CastControlsState extends ConsumerState<_CastControls> {
  double? _volume;
  bool _volumeLoading = false;
  bool _volumeFetched = false;
  double? _dragSeekValue;

  Future<void> _fetchVolume(DlnaDevice device) async {
    if (_volumeLoading || _volumeFetched) return;
    setState(() => _volumeLoading = true);
    try {
      if (device.protocol == CastProtocol.chromecast) {
        _volumeFetched = true;
        if (mounted) setState(() => _volume ??= 50);
      } else {
        final v = await ref.read(dlnaServiceProvider).getVolume(device);
        _volumeFetched = true;
        if (mounted && v != null) setState(() => _volume = v.toDouble());
      }
    } finally {
      if (mounted) setState(() => _volumeLoading = false);
    }
  }

  Future<void> _setVolume(DlnaDevice device, double v) async {
    setState(() => _volume = v);
    if (device.protocol == CastProtocol.chromecast) {
      await ref.read(chromecastServiceProvider).setVolume(v / 100);
    } else {
      await ref.read(dlnaServiceProvider).setVolume(device, v.round());
    }
  }

  @override
  Widget build(BuildContext context) {
    final castState = ref.watch(castProvider);
    final progress = ref.watch(castPositionProvider);
    final seekInFlight = ref.watch(castSeekInFlightProvider);
    final cs = Theme.of(context).colorScheme;

    if (castState is CastError) {
      return Card(
        color: cs.errorContainer.withAlpha(80),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: cs.error, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  castState.message,
                  style: TextStyle(
                      fontSize: 13, color: cs.onErrorContainer),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
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
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: cs.primary),
              ),
              const SizedBox(width: 16),
              Text('Starting stream…',
                  style: TextStyle(
                      fontSize: 14, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      );
    }

    if (castState is CastPlaying) {
      if (!_volumeFetched) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _fetchVolume(castState.device),
        );
      }

      final total = progress.total.inSeconds;
      final pos = progress.position.inSeconds.clamp(0, total > 0 ? total : 1);

      return Card(
        color: cs.primaryContainer.withAlpha(30),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Now playing header ────────────────────────────────────
              Row(children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.cast_connected,
                      color: cs.onPrimary, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(castState.title,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      Row(children: [
                        Icon(Icons.tv_rounded,
                            size: 11, color: cs.onSurfaceVariant),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(castState.device.name,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurfaceVariant),
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (castState.routedThroughPhone) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.phone_android,
                              size: 11, color: cs.tertiary),
                        ],
                      ]),
                    ],
                  ),
                ),
              ]),

              // ── Seek indicator ────────────────────────────────────────
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                child: seekInFlight
                    ? Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            minHeight: 2,
                            color: cs.primary,
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),

              // ── Progress bar ──────────────────────────────────────────
              if (total > 0) ...[
                const SizedBox(height: 8),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3.5,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 7),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 14),
                  ),
                  child: Slider(
                    value: (_dragSeekValue ?? pos.toDouble())
                        .clamp(0.0, total.toDouble()),
                    min: 0,
                    max: total.toDouble(),
                    onChangeStart: (v) =>
                        setState(() => _dragSeekValue = v),
                    onChanged: (v) => setState(() => _dragSeekValue = v),
                    onChangeEnd: (v) async {
                      setState(() => _dragSeekValue = null);
                      final ok = await ref
                          .read(castProvider.notifier)
                          .seek(Duration(seconds: v.toInt()));
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content:
                                  Text('Seek failed. Please try again.')),
                        );
                      }
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmt(progress.position),
                          style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ])),
                      Text(_fmt(progress.total),
                          style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ])),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 6),

              // ── Playback controls ─────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Rewind
                  _ControlButton(
                    icon: Icons.replay_10_rounded,
                    tooltip: 'Rewind 10s',
                    onTap: () async {
                      final ok = await ref
                          .read(castProvider.notifier)
                          .seekRelative(const Duration(seconds: -10));
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Rewind failed.')),
                        );
                      }
                    },
                  ),
                  // Play / Pause (big)
                  _PlayPauseButton(isPaused: castState.isPaused),
                  // Forward
                  _ControlButton(
                    icon: Icons.forward_10_rounded,
                    tooltip: 'Forward 10s',
                    onTap: () async {
                      final ok = await ref
                          .read(castProvider.notifier)
                          .seekRelative(const Duration(seconds: 10));
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Forward seek failed.')),
                        );
                      }
                    },
                  ),
                  // Stop
                  _ControlButton(
                    icon: Icons.stop_rounded,
                    tooltip: 'Stop casting',
                    color: cs.error,
                    onTap: () {
                      setState(() {
                        _volume = null;
                        _volumeFetched = false;
                      });
                      ref.read(castProvider.notifier).stop();
                    },
                  ),
                ],
              ),

              // ── Volume ────────────────────────────────────────────────
              Row(
                children: [
                  Icon(Icons.volume_down_rounded,
                      size: 17, color: cs.onSurfaceVariant),
                  Expanded(
                    child: Slider(
                      value: (_volume ?? 50).clamp(0, 100).toDouble(),
                      min: 0,
                      max: 100,
                      divisions: 20,
                      onChanged: (v) => setState(() => _volume = v),
                      onChangeEnd: (v) => _setVolume(castState.device, v),
                    ),
                  ),
                  Icon(Icons.volume_up_rounded,
                      size: 17, color: cs.onSurfaceVariant),
                ],
              ),

              // ── Sleep timer ───────────────────────────────────────────
              _SleepTimerButton(),
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

// ── Playback control helper widgets ─────────────────────────────────────────

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;
  const _ControlButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(40),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: 26, color: color ?? cs.onSurface),
        ),
      ),
    );
  }
}

class _PlayPauseButton extends ConsumerWidget {
  final bool isPaused;
  const _PlayPauseButton({required this.isPaused});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: isPaused ? 'Resume' : 'Pause',
      child: InkWell(
        onTap: () => ref.read(castProvider.notifier).pauseResume(),
        borderRadius: BorderRadius.circular(40),
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: cs.primary,
            shape: BoxShape.circle,
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Icon(
              isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              key: ValueKey(isPaused),
              color: cs.onPrimary,
              size: 30,
            ),
          ),
        ),
      ),
    );
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
            Text('Recently Cast',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: cs.onSurfaceVariant)),
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
                        width: 48,
                        height: 28,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 48,
                          height: 28,
                          color: cs.surfaceContainerHighest,
                          child: const Icon(Icons.video_file, size: 16),
                        ),
                      ),
                    )
                  : Icon(Icons.play_circle_outline, color: cs.primary),
              title: Text(item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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

    return Card(
      color: active
          ? cs.secondaryContainer.withAlpha(180)
          : cs.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.phone_android,
                size: 20,
                color: active ? cs.secondary : cs.onSurfaceVariant),
            const SizedBox(width: 12),
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
                      color:
                          active ? cs.onSecondaryContainer : cs.onSurface,
                    ),
                  ),
                  Text(
                    active
                        ? 'Phone proxies the stream to your TV'
                        : 'TV fetches stream directly from internet',
                    style:
                        TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
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

// ── Queue Section ───────────────────────────────────────────────────────────

class _QueueSection extends ConsumerWidget {
  const _QueueSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(queueProvider);
    if (queue.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final notifier = ref.read(queueProvider.notifier);
    final currentIdx = notifier.currentIndex;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.queue_music, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Text('Queue (${queue.length})',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: cs.onSurfaceVariant)),
            const Spacer(),
            TextButton(
              onPressed: () => ref.read(queueProvider.notifier).clear(),
              child: const Text('Clear', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ...List.generate(queue.length, (i) {
          final item = queue[i];
          final isCurrent = i == currentIdx;
          return Dismissible(
            key: ValueKey('${item.url}_$i'),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 16),
              color: cs.error,
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            onDismissed: (_) => notifier.removeAt(i),
            child: ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: isCurrent
                  ? Icon(Icons.play_arrow, color: cs.primary, size: 20)
                  : Text('${i + 1}',
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              title: Text(item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          isCurrent ? FontWeight.w600 : FontWeight.normal)),
              trailing: IconButton(
                icon: const Icon(Icons.cast, size: 16),
                tooltip: 'Cast this',
                onPressed: () {
                  notifier.setCurrent(i);
                  ref.read(videoProvider.notifier).extract(item.url);
                },
              ),
            ),
          );
        }),
      ],
    );
  }
}

// ── Subtitle Search Section ─────────────────────────────────────────────────

class _SubtitleSearchSection extends ConsumerStatefulWidget {
  final String title;
  const _SubtitleSearchSection({required this.title});

  @override
  ConsumerState<_SubtitleSearchSection> createState() =>
      _SubtitleSearchSectionState();
}

class _SubtitleSearchSectionState
    extends ConsumerState<_SubtitleSearchSection> {
  List<SubtitleResult>? _results;
  bool _loading = false;
  String? _error;
  bool _isKeyError = false;

  Future<void> _search() async {
    final settings = ref.read(settingsProvider);
    final service = ref.read(subtitleServiceProvider);
    // Apply the API key from settings before each search
    service.setApiKey(settings.openSubtitlesApiKey);

    setState(() {
      _loading = true;
      _error = null;
      _isKeyError = false;
    });
    try {
      final results = await service.search(query: widget.title);
      if (mounted) {
        setState(() => _results = results);
      }
    } on SubtitleApiKeyMissing catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isKeyError = true;
        });
      }
    } on SubtitleApiKeyInvalid catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isKeyError = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _downloadAndApply(SubtitleResult sub) async {
    try {
      final service = ref.read(subtitleServiceProvider);
      final srt = await service.download(sub.fileId);
      if (srt != null && mounted) {
        ref.read(selectedSubtitleProvider.notifier).state = SubtitleTrack(
          language: sub.language,
          label: '${sub.language} (OpenSubtitles)',
          srtContent: srt,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Subtitles loaded: ${sub.language}'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to download subtitle: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasKey = ref.watch(settingsProvider).hasSubtitleKey;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.subtitles, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Text('Search Subtitles',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: cs.onSurfaceVariant)),
            const Spacer(),
            if (_loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              TextButton.icon(
                icon: const Icon(Icons.search, size: 14),
                label: const Text('Search', style: TextStyle(fontSize: 12)),
                onPressed: _search,
              ),
          ],
        ),
        if (!hasKey && _error == null && _results == null) ...[
          const SizedBox(height: 4),
          Text(
            'Add your free OpenSubtitles API key in Settings to search subtitles.',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
        if (_error != null) ...[
          if (_isKeyError) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cs.tertiaryContainer.withAlpha(80),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_error!,
                      style: TextStyle(fontSize: 12, color: cs.onSurface)),
                  const SizedBox(height: 6),
                  Text(
                    '1. Go to opensubtitles.com/en/consumers\n'
                    '2. Create a free account & register a consumer\n'
                    '3. Paste your API key in Settings \u2192 OpenSubtitles API Key',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ] else ...[
            const SizedBox(height: 4),
            Text(_error!, style: TextStyle(fontSize: 12, color: cs.error)),
          ],
        ],
        if (_results != null && _results!.isEmpty) ...[
          const SizedBox(height: 4),
          Text('No subtitles found',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ],
        if (_results != null && _results!.isNotEmpty) ...[
          const SizedBox(height: 4),
          ...(_results!.take(8).map((sub) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.subtitles_outlined,
                    size: 18, color: cs.onSurfaceVariant),
                title: Text(sub.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12)),
                subtitle: Text(
                    '${sub.language} · ${sub.downloadCount} downloads',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                trailing: IconButton(
                  icon: Icon(Icons.download, size: 16, color: cs.primary),
                  onPressed: () => _downloadAndApply(sub),
                ),
              ))),
        ],
      ],
    );
  }
}

// ── Sleep Timer Button ──────────────────────────────────────────────────────

class _SleepTimerButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final castNotifier = ref.read(castProvider.notifier);
    final isActive = castNotifier.hasSleepTimer;

    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        icon: Icon(
          isActive ? Icons.timer : Icons.timer_outlined,
          size: 16,
          color: isActive ? cs.primary : cs.onSurfaceVariant,
        ),
        label: Text(
          isActive ? 'Sleep timer on' : 'Sleep timer',
          style: TextStyle(
            fontSize: 12,
            color: isActive ? cs.primary : cs.onSurfaceVariant,
          ),
        ),
        onPressed: () {
          if (isActive) {
            castNotifier.cancelSleepTimer();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('Sleep timer cancelled'),
                  duration: Duration(seconds: 2)),
            );
          } else {
            _showTimerPicker(context, castNotifier);
          }
        },
      ),
    );
  }

  void _showTimerPicker(BuildContext context, CastNotifier notifier) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Sleep Timer',
                    style:
                        TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                const SizedBox(height: 12),
                ...[15, 30, 45, 60, 90, 120].map((m) => ListTile(
                      dense: true,
                      leading: const Icon(Icons.timer, size: 20),
                      title: Text(m >= 60
                          ? '${m ~/ 60} hour${m > 60 ? 's' : ''}${m % 60 > 0 ? ' ${m % 60} min' : ''}'
                          : '$m minutes'),
                      onTap: () {
                        notifier.setSleepTimer(Duration(minutes: m));
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Casting will stop in $m minutes'),
                            duration: const Duration(seconds: 3),
                          ),
                        );
                      },
                    )),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── Settings Sheet ──────────────────────────────────────────────────────────

class _SettingsSheet extends ConsumerStatefulWidget {
  const _SettingsSheet();

  @override
  ConsumerState<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends ConsumerState<_SettingsSheet> {
  late TextEditingController _apiKeyController;

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController(
      text: ref.read(settingsProvider).openSubtitlesApiKey,
    );
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final cs = Theme.of(context).colorScheme;
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
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ad blocker in browser'),
            subtitle: const Text(
              'Blocks ad/tracker requests and popup redirects in the in-app browser.',
            ),
            value: settings.adBlockEnabled,
            onChanged: (_) =>
                ref.read(settingsProvider.notifier).toggleAdBlock(),
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.subtitles_outlined),
            title: const Text('OpenSubtitles API Key'),
            subtitle: settings.hasSubtitleKey
                ? Text(
                    'Key configured (${settings.openSubtitlesApiKey.substring(0, 4)}…)',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))
                : Text('Not configured — subtitles won\u2019t work',
                    style: TextStyle(fontSize: 12, color: cs.error)),
          ),
          TextField(
            controller: _apiKeyController,
            decoration: InputDecoration(
              hintText: 'Paste your API key here',
              hintStyle: const TextStyle(fontSize: 13),
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(Icons.check_circle,
                    color: _apiKeyController.text.trim().isNotEmpty
                        ? cs.primary
                        : cs.outlineVariant),
                onPressed: () {
                  ref
                      .read(settingsProvider.notifier)
                      .setSubtitleApiKey(_apiKeyController.text);
                  FocusScope.of(context).unfocus();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('API key saved'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
            ),
            style: const TextStyle(fontSize: 13),
            onSubmitted: (v) {
              ref.read(settingsProvider.notifier).setSubtitleApiKey(v);
              FocusScope.of(context).unfocus();
            },
          ),
          const SizedBox(height: 4),
          Text(
            'Free key: opensubtitles.com/en/consumers',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Data and privacy controls'),
            subtitle: const Text(
              'Retention limits, startup clearing, backup and restore',
            ),
            onTap: () {
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                builder: (_) => const _PrivacySheet(),
              );
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.analytics_outlined),
            title: const Text('Telemetry events'),
            subtitle: const Text('View local reliability diagnostics'),
            onTap: () {
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                builder: (_) => const _TelemetrySheet(),
              );
            },
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline),
            title: const Text('Supported sources'),
            subtitle: const Text(
              'YouTube (full quality picker)\n'
              'Direct video URLs (.mp4, .m3u8, .webm, .mkv)\n'
              'DLNA/UPnP TVs & Chromecast devices',
            ),
            isThreeLine: true,
          ),
        ],
      ),
    );
  }
}

class _PrivacySheet extends ConsumerStatefulWidget {
  const _PrivacySheet();

  @override
  ConsumerState<_PrivacySheet> createState() => _PrivacySheetState();
}

class _PrivacySheetState extends ConsumerState<_PrivacySheet> {
  static const _limitOptions = [50, 100, 250, 500, 1000];

  Future<void> _exportData() async {
    final bookmarks = ref.read(bookmarksProvider.notifier).exportJson();
    final history = ref.read(historyProvider.notifier).exportJson();
    final castHistory = ref.read(castHistoryProvider.notifier).exportJson();
    final telemetry = ref.read(telemetryProvider.notifier).exportJson();
    final privacy = ref.read(privacySettingsProvider);

    final payload = {
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'privacy': {
        'bookmarksLimit': privacy.bookmarksLimit,
        'historyLimit': privacy.historyLimit,
        'clearBrowsingDataOnStart': privacy.clearBrowsingDataOnStart,
        'telemetryEnabled': privacy.telemetryEnabled,
      },
      'bookmarks': bookmarks,
      'history': history,
      'castHistory': castHistory,
      'telemetry': telemetry,
    };

    final dir = await getApplicationDocumentsDirectory();
    final file = File(
      '${dir.path}${Platform.pathSeparator}video_caster_backup_${DateTime.now().millisecondsSinceEpoch}.json',
    );
    await file
        .writeAsString(const JsonEncoder.withIndent('  ').convert(payload));

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Backup saved to ${file.path}')),
    );
  }

  Future<void> _importData() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: false,
    );
    final path = picked?.files.single.path;
    if (path == null) return;

    final raw = await File(path).readAsString();
    final decoded = jsonDecode(raw) as Map<String, dynamic>;

    final bookmarksRaw = decoded['bookmarks'] as List? ?? const [];
    final historyRaw = decoded['history'] as List? ?? const [];
    final castRaw = decoded['castHistory'] as List? ?? const [];
    final telemetryRaw = decoded['telemetry'] as List? ?? const [];
    final privacyRaw = decoded['privacy'] as Map<String, dynamic>?;

    await ref.read(bookmarksProvider.notifier).importJson(bookmarksRaw);
    await ref.read(historyProvider.notifier).importJson(historyRaw);
    await ref.read(castHistoryProvider.notifier).importJson(castRaw);
    await ref.read(telemetryProvider.notifier).importJson(telemetryRaw);

    if (privacyRaw != null) {
      final privacyNotifier = ref.read(privacySettingsProvider.notifier);
      final bLimit = privacyRaw['bookmarksLimit'];
      final hLimit = privacyRaw['historyLimit'];
      final clearOnStart = privacyRaw['clearBrowsingDataOnStart'];
      final telemetryEnabled = privacyRaw['telemetryEnabled'];
      if (bLimit is int) await privacyNotifier.setBookmarksLimit(bLimit);
      if (hLimit is int) await privacyNotifier.setHistoryLimit(hLimit);
      if (clearOnStart is bool) {
        await privacyNotifier.setClearBrowsingDataOnStart(clearOnStart);
      }
      if (telemetryEnabled is bool) {
        await privacyNotifier.setTelemetryEnabled(telemetryEnabled);
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Backup imported successfully')),
    );
  }

  Future<void> _resetAllLocalData() async {
    await ref.read(bookmarksProvider.notifier).clear();
    await ref.read(historyProvider.notifier).clear();
    await ref.read(castHistoryProvider.notifier).clear();
    await ref.read(telemetryProvider.notifier).clear();
    await ref.read(privacySettingsProvider.notifier).setBookmarksLimit(500);
    await ref.read(privacySettingsProvider.notifier).setHistoryLimit(500);
    await ref
        .read(privacySettingsProvider.notifier)
        .setClearBrowsingDataOnStart(false);
    await ref.read(privacySettingsProvider.notifier).setTelemetryEnabled(true);
    await InAppWebViewController.clearAllCache();
    await CookieManager.instance().deleteAllCookies();
    await WebStorageManager.instance().deleteAllData();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All local app data reset')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final privacy = ref.watch(privacySettingsProvider);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Data and Privacy',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Clear browsing data on app start'),
              subtitle:
                  const Text('Clears history, cookies, cache and web storage'),
              value: privacy.clearBrowsingDataOnStart,
              onChanged: (v) => ref
                  .read(privacySettingsProvider.notifier)
                  .setClearBrowsingDataOnStart(v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enable telemetry diagnostics'),
              subtitle: const Text(
                  'Stores local reliability events for troubleshooting'),
              value: privacy.telemetryEnabled,
              onChanged: (v) => ref
                  .read(privacySettingsProvider.notifier)
                  .setTelemetryEnabled(v),
            ),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: privacy.bookmarksLimit,
                    decoration: const InputDecoration(
                      labelText: 'Bookmark retention',
                      isDense: true,
                    ),
                    items: _limitOptions
                        .map((v) => DropdownMenuItem(
                              value: v,
                              child: Text('$v items'),
                            ))
                        .toList(growable: false),
                    onChanged: (v) async {
                      if (v == null) return;
                      await ref
                          .read(privacySettingsProvider.notifier)
                          .setBookmarksLimit(v);
                      await ref.read(bookmarksProvider.notifier).applyLimit();
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: privacy.historyLimit,
                    decoration: const InputDecoration(
                      labelText: 'History retention',
                      isDense: true,
                    ),
                    items: _limitOptions
                        .map((v) => DropdownMenuItem(
                              value: v,
                              child: Text('$v items'),
                            ))
                        .toList(growable: false),
                    onChanged: (v) async {
                      if (v == null) return;
                      await ref
                          .read(privacySettingsProvider.notifier)
                          .setHistoryLimit(v);
                      await ref.read(historyProvider.notifier).applyLimit();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _exportData,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Export backup'),
                ),
                OutlinedButton.icon(
                  onPressed: _importData,
                  icon: const Icon(Icons.download),
                  label: const Text('Import backup'),
                ),
                OutlinedButton.icon(
                  onPressed: _resetAllLocalData,
                  style: OutlinedButton.styleFrom(foregroundColor: cs.error),
                  icon: const Icon(Icons.delete_forever),
                  label: const Text('Reset all local data'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TelemetrySheet extends ConsumerWidget {
  const _TelemetrySheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(telemetryProvider);
    final cs = Theme.of(context).colorScheme;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.analytics, color: cs.primary),
                  const SizedBox(width: 8),
                  Text('Telemetry',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  TextButton(
                    onPressed: () =>
                        ref.read(telemetryProvider.notifier).clear(),
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: events.isEmpty
                  ? Center(
                      child: Text('No telemetry events yet',
                          style: TextStyle(color: cs.onSurfaceVariant)),
                    )
                  : ListView.builder(
                      controller: scrollCtrl,
                      itemCount: events.length,
                      itemBuilder: (_, i) {
                        final e = events[i];
                        return ListTile(
                          dense: true,
                          title: Text(e.name,
                              style: const TextStyle(fontSize: 13),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${e.at.toIso8601String()}\n${jsonEncode(e.payload)}',
                            style: TextStyle(
                                fontSize: 11, color: cs.onSurfaceVariant),
                          ),
                          isThreeLine: true,
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
