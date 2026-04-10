import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state.dart';

/// A persistent mini player bar shown above bottom navigation when casting.
/// Visible on all tabs — lets users control playback from anywhere.
/// Includes skip ±10s, play/pause, stop, and a draggable seekbar.
class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key});

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer> {
  /// Non-null while the user is dragging the seekbar.
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final castState = ref.watch(castProvider);
    if (castState is! CastPlaying) return const SizedBox.shrink();

    final progress = ref.watch(castPositionProvider);
    final cs = Theme.of(context).colorScheme;
    final total = progress.total.inMilliseconds;
    final pos = progress.position.inMilliseconds.clamp(0, total > 0 ? total : 1);
    final fraction = total > 0 ? pos / total : 0.0;
    final notifier = ref.read(castProvider.notifier);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Seekbar (draggable) ────────────────────────────────────────
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            activeTrackColor: cs.primary,
            inactiveTrackColor: cs.surfaceContainerHighest,
            thumbColor: cs.primary,
          ),
          child: Slider(
            value: (_dragValue ?? fraction).clamp(0.0, 1.0),
            onChangeStart: (v) => setState(() => _dragValue = v),
            onChanged: (v) => setState(() => _dragValue = v),
            onChangeEnd: (v) {
              setState(() => _dragValue = null);
              if (total > 0) {
                final target = Duration(milliseconds: (v * total).round());
                notifier.seek(target);
              }
            },
          ),
        ),
        Container(
          color: cs.surfaceContainerHigh,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Title + device info ──────────────────────────────────
              Row(
                children: [
                  Icon(Icons.cast_connected, color: cs.primary, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          castState.title,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${castState.device.name} · ${_fmt(progress.position)} / ${_fmt(progress.total)}',
                          style: TextStyle(
                              fontSize: 11, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              // ── Playback controls ────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Rewind 10s
                  IconButton(
                    icon: const Icon(Icons.replay_10, size: 24),
                    onPressed: () =>
                        notifier.seekRelative(const Duration(seconds: -10)),
                    tooltip: 'Rewind 10s',
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 8),
                  // Play / Pause
                  IconButton(
                    icon: Icon(
                      castState.isPaused ? Icons.play_arrow : Icons.pause,
                      size: 28,
                    ),
                    onPressed: () => notifier.pauseResume(),
                    tooltip: castState.isPaused ? 'Resume' : 'Pause',
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 8),
                  // Forward 10s
                  IconButton(
                    icon: const Icon(Icons.forward_10, size: 24),
                    onPressed: () =>
                        notifier.seekRelative(const Duration(seconds: 10)),
                    tooltip: 'Forward 10s',
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 16),
                  // Stop
                  IconButton(
                    icon: const Icon(Icons.stop, size: 24),
                    onPressed: () => notifier.stop(),
                    tooltip: 'Stop',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
