import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state.dart';

/// A persistent mini player bar shown above bottom navigation when casting.
/// Visible on all tabs — lets users control playback from anywhere.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final castState = ref.watch(castProvider);
    if (castState is! CastPlaying) return const SizedBox.shrink();

    final progress = ref.watch(castPositionProvider);
    final cs = Theme.of(context).colorScheme;
    final total = progress.total.inMilliseconds;
    final pos = progress.position.inMilliseconds.clamp(0, total > 0 ? total : 1);
    final fraction = total > 0 ? pos / total : 0.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Thin progress line
        LinearProgressIndicator(
          value: fraction,
          minHeight: 2,
          backgroundColor: cs.surfaceContainerHighest,
          color: cs.primary,
        ),
        Container(
          color: cs.surfaceContainerHigh,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.cast_connected, color: cs.primary, size: 20),
              const SizedBox(width: 10),
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
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(
                  castState.isPaused ? Icons.play_arrow : Icons.pause,
                  size: 22,
                ),
                onPressed: () =>
                    ref.read(castProvider.notifier).pauseResume(),
                tooltip: castState.isPaused ? 'Resume' : 'Pause',
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                icon: const Icon(Icons.stop, size: 22),
                onPressed: () => ref.read(castProvider.notifier).stop(),
                tooltip: 'Stop',
                visualDensity: VisualDensity.compact,
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
