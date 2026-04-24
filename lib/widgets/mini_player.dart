import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state.dart';

/// A persistent mini player bar shown above bottom navigation when casting.
/// Visible on all tabs — lets users control playback from anywhere.
/// Includes skip ±10s, play/pause, stop, and a slim draggable seekbar.
class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key});

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer>
    with SingleTickerProviderStateMixin {
  double? _dragValue;
  late final AnimationController _entryAnim;
  late final Animation<double> _fadeSlide;

  @override
  void initState() {
    super.initState();
    _entryAnim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _fadeSlide = CurvedAnimation(parent: _entryAnim, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _entryAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final castState = ref.watch(castProvider);
    final isCasting = castState is CastPlaying;

    // Drive entrance / exit animation
    if (isCasting && _entryAnim.status == AnimationStatus.dismissed) {
      _entryAnim.forward();
    } else if (!isCasting && _entryAnim.status == AnimationStatus.completed) {
      _entryAnim.reverse();
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOut,
      child: isCasting
          ? FadeTransition(
              opacity: _fadeSlide,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.15),
                  end: Offset.zero,
                ).animate(_fadeSlide),
                child: _buildContent(context, castState),
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildContent(BuildContext context, CastPlaying castState) {
    final progress = ref.watch(castPositionProvider);
    final seekInFlight = ref.watch(castSeekInFlightProvider);
    final cs = Theme.of(context).colorScheme;
    final notifier = ref.read(castProvider.notifier);

    final total = progress.total.inMilliseconds;
    final pos =
        progress.position.inMilliseconds.clamp(0, total > 0 ? total : 1);
    final fraction = total > 0 ? pos / total : 0.0;

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        border: Border(
          top: BorderSide(color: cs.outlineVariant.withAlpha(80), width: 0.8),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // -- Slim seek bar at the very top
          SizedBox(
            height: 3,
            child: seekInFlight
                ? LinearProgressIndicator(
                    minHeight: 3,
                    color: cs.primary,
                    backgroundColor: cs.surfaceContainerHighest,
                  )
                : SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 0),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 0),
                      activeTrackColor: cs.primary,
                      inactiveTrackColor: cs.surfaceContainerHighest,
                      thumbColor: cs.primary,
                    ),
                    child: Slider(
                      value: (_dragValue ?? fraction).clamp(0.0, 1.0),
                      onChangeStart: (v) => setState(() => _dragValue = v),
                      onChanged: (v) => setState(() => _dragValue = v),
                      onChangeEnd: (v) async {
                        setState(() => _dragValue = null);
                        if (total > 0) {
                          final target =
                              Duration(milliseconds: (v * total).round());
                          final ok = await notifier.seek(target);
                          if (!context.mounted) return;
                          if (!ok) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content:
                                      Text('Seek failed. Please try again.')),
                            );
                          }
                        }
                      },
                    ),
                  ),
          ),

          // -- Controls row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                // Cast icon + title + device + time
                Expanded(
                  child: Row(
                    children: [
                      Icon(Icons.cast_connected,
                          color: cs.primary, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              castState.title,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${castState.device.name}  ${_fmt(progress.position)} / ${_fmt(progress.total)}',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: cs.onSurfaceVariant,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ]),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Rewind 10s
                IconButton(
                  icon: const Icon(Icons.replay_10_rounded, size: 22),
                  onPressed: () async {
                    final ok = await notifier
                        .seekRelative(const Duration(seconds: -10));
                    if (!ok && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Rewind failed.')),
                      );
                    }
                  },
                  tooltip: 'Rewind 10s',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),

                // Play / Pause with animated icon swap
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: IconButton(
                    key: ValueKey(castState.isPaused),
                    icon: Icon(
                      castState.isPaused
                          ? Icons.play_arrow_rounded
                          : Icons.pause_rounded,
                      size: 26,
                    ),
                    onPressed: () => notifier.pauseResume(),
                    tooltip: castState.isPaused ? 'Resume' : 'Pause',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                  ),
                ),

                // Forward 10s
                IconButton(
                  icon: const Icon(Icons.forward_10_rounded, size: 22),
                  onPressed: () async {
                    final ok = await notifier
                        .seekRelative(const Duration(seconds: 10));
                    if (!ok && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Forward seek failed.')),
                      );
                    }
                  },
                  tooltip: 'Forward 10s',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),

                // Stop
                IconButton(
                  icon: Icon(Icons.stop_rounded,
                      size: 22, color: cs.error),
                  onPressed: () => notifier.stop(),
                  tooltip: 'Stop',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
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
