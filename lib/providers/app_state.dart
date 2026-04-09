import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/video_info.dart';
import '../models/dlna_device.dart';
import '../services/video_extractor.dart';
import '../services/dlna_service.dart';
import '../services/stream_proxy.dart';

// ── Singleton services ────────────────────────────────────────────────────────

final videoExtractorProvider = Provider((_) => VideoExtractorService());
final dlnaServiceProvider = Provider((_) => DlnaService());
final streamProxyProvider = Provider((_) => StreamProxyService());

// ── Settings ──────────────────────────────────────────────────────────────────

class AppSettings {
  final bool routeThroughPhone;
  const AppSettings({this.routeThroughPhone = true});

  AppSettings copyWith({bool? routeThroughPhone}) =>
      AppSettings(routeThroughPhone: routeThroughPhone ?? this.routeThroughPhone);
}

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier() : super(const AppSettings()) {
    _load();
  }

  static const _keyRouteThrough = 'route_through_phone';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = AppSettings(
      routeThroughPhone: prefs.getBool(_keyRouteThrough) ?? true,
    );
  }

  Future<void> toggle() async {
    final newValue = !state.routeThroughPhone;
    state = state.copyWith(routeThroughPhone: newValue);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyRouteThrough, newValue);
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((_) => SettingsNotifier());

// ── Video extraction ──────────────────────────────────────────────────────────

sealed class VideoState {
  const VideoState();
}

class VideoIdle extends VideoState {
  const VideoIdle();
}

class VideoLoading extends VideoState {
  const VideoLoading();
}

class VideoLoaded extends VideoState {
  final VideoInfo info;
  final String sourceUrl;
  const VideoLoaded(this.info, this.sourceUrl);
}

class VideoError extends VideoState {
  final String message;
  const VideoError(this.message);
}

class VideoNotifier extends StateNotifier<VideoState> {
  VideoNotifier(this._extractor) : super(const VideoIdle());
  final VideoExtractorService _extractor;

  Future<void> extract(String url) async {
    state = const VideoLoading();
    try {
      final info = await _extractor.extract(url);
      state = VideoLoaded(info, url);
    } catch (e) {
      state = VideoError(_clean(e));
    }
  }

  void reset() => state = const VideoIdle();
}

final videoProvider = StateNotifierProvider<VideoNotifier, VideoState>(
  (ref) => VideoNotifier(ref.watch(videoExtractorProvider)),
);

// ── DLNA device discovery ─────────────────────────────────────────────────────

sealed class DevicesState {
  const DevicesState();
}

class DevicesIdle extends DevicesState {
  const DevicesIdle();
}

class DevicesScanning extends DevicesState {
  const DevicesScanning();
}

class DevicesResult extends DevicesState {
  final List<DlnaDevice> devices;
  const DevicesResult(this.devices);
}

class DevicesError extends DevicesState {
  final String message;
  const DevicesError(this.message);
}

class DevicesNotifier extends StateNotifier<DevicesState> {
  DevicesNotifier(this._dlna) : super(const DevicesIdle());
  final DlnaService _dlna;

  Future<void> scan() async {
    state = const DevicesScanning();
    try {
      final devices = await _dlna.discover();
      state = DevicesResult(devices);
    } catch (e) {
      state = DevicesError(_clean(e));
    }
  }
}

final devicesProvider = StateNotifierProvider<DevicesNotifier, DevicesState>(
  (ref) => DevicesNotifier(ref.watch(dlnaServiceProvider)),
);

// ── Cast state ────────────────────────────────────────────────────────────────

sealed class CastState {
  const CastState();
}

class CastIdle extends CastState {
  const CastIdle();
}

class CastPreparing extends CastState {
  const CastPreparing();
}

class CastPlaying extends CastState {
  final DlnaDevice device;
  final String title;
  final bool routedThroughPhone;
  final bool isPaused;

  const CastPlaying({
    required this.device,
    required this.title,
    required this.routedThroughPhone,
    this.isPaused = false,
  });

  CastPlaying copyWith({bool? isPaused}) => CastPlaying(
        device: device,
        title: title,
        routedThroughPhone: routedThroughPhone,
        isPaused: isPaused ?? this.isPaused,
      );
}

class CastError extends CastState {
  final String message;
  const CastError(this.message);
}

class CastNotifier extends StateNotifier<CastState> {
  CastNotifier(this._dlna, this._proxy) : super(const CastIdle());
  final DlnaService _dlna;
  final StreamProxyService _proxy;

  Timer? _progressTimer;
  Duration _position = Duration.zero;
  Duration _totalDuration = Duration.zero;
  int _pollFailures = 0;

  Duration get position => _position;
  Duration get totalDuration => _totalDuration;

  Future<void> cast({
    required DlnaDevice device,
    required StreamFormat format,
    required String title,
    required bool routeThroughPhone,
  }) async {
    state = const CastPreparing();
    try {
      final String castUrl;
      if (routeThroughPhone) {
        final proxyUrl = await _proxy.start(streamUrl: format.url);
        if (proxyUrl == null) {
          throw Exception('Could not start proxy. Make sure you\'re on WiFi.');
        }
        castUrl = proxyUrl;
      } else {
        castUrl = format.url;
      }

      await _dlna.setUri(device, castUrl, title);
      await _dlna.play(device);

      state = CastPlaying(
        device: device,
        title: title,
        routedThroughPhone: routeThroughPhone,
      );
      // Keep the screen on while casting.
      await WakelockPlus.enable();
      _startProgressPolling(device);
    } catch (e) {
      await _proxy.stop();
      state = CastError(_clean(e));
    }
  }

  Future<void> pauseResume() async {
    final s = state;
    if (s is! CastPlaying) return;
    try {
      if (s.isPaused) {
        await _dlna.play(s.device);
      } else {
        await _dlna.pause(s.device);
      }
      // Create a new immutable state — Riverpod detects the change correctly.
      state = s.copyWith(isPaused: !s.isPaused);
    } catch (_) {}
  }

  Future<void> seek(Duration position) async {
    final s = state;
    if (s is! CastPlaying) return;
    try {
      await _dlna.seek(s.device, position);
      _position = position;
    } catch (_) {}
  }

  Future<void> stop() async {
    _progressTimer?.cancel();
    _pollFailures = 0;
    final s = state;
    if (s is CastPlaying) {
      try { await _dlna.stop(s.device); } catch (_) {}
    }
    await _proxy.stop();
    await WakelockPlus.disable();
    _position = Duration.zero;
    _totalDuration = Duration.zero;
    state = const CastIdle();
  }

  void _startProgressPolling(DlnaDevice device) {
    _progressTimer?.cancel();
    _pollFailures = 0;
    _progressTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (state is! CastPlaying) {
        _progressTimer?.cancel();
        return;
      }
      try {
        final info = await _dlna.getPositionInfo(device);
        _pollFailures = 0;
        _position = info.position;
        _totalDuration = info.duration;

        switch (info.transportState) {
          case 'STOPPED':
          case 'NO_MEDIA_PRESENT':
            await stop();
          case 'PAUSED_PLAYBACK':
            // Sync pause state if TV was paused externally (e.g., TV remote).
            final s = state;
            if (s is CastPlaying && !s.isPaused) state = s.copyWith(isPaused: true);
          case 'PLAYING':
            // Sync play state if TV was resumed externally.
            final s = state;
            if (s is CastPlaying && s.isPaused) state = s.copyWith(isPaused: false);
        }
      } catch (_) {
        _pollFailures++;
        // After 5 consecutive failures stop polling — avoids log spam.
        // The cast session stays alive; TV may still be playing fine.
        if (_pollFailures >= 5) _progressTimer?.cancel();
      }
    });
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }
}

final castProvider = StateNotifierProvider<CastNotifier, CastState>(
  (ref) => CastNotifier(ref.watch(dlnaServiceProvider), ref.watch(streamProxyProvider)),
);

// Progress is kept in the notifier; expose via a simple provider
final castPositionProvider = Provider<({Duration position, Duration total})>((ref) {
  ref.watch(castProvider); // re-evaluate when cast state changes
  final notifier = ref.read(castProvider.notifier);
  return (position: notifier.position, total: notifier.totalDuration);
});

// ── Selected device / format ──────────────────────────────────────────────────

final selectedDeviceProvider = StateProvider<DlnaDevice?>((ref) => null);
final selectedFormatProvider = StateProvider<StreamFormat?>((ref) => null);

// ── Helpers ───────────────────────────────────────────────────────────────────

String _clean(Object e) =>
    e.toString().replaceFirst('Exception: ', '').replaceFirst('FormatException: ', '');
