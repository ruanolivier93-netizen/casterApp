import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/video_info.dart';
import '../models/dlna_device.dart';
import '../services/video_extractor.dart';
import '../services/dlna_service.dart';
import '../services/stream_proxy.dart';
import '../services/chromecast_service.dart';
import '../services/subtitle_service.dart';
import '../services/download_service.dart';
import '../providers/queue_provider.dart';

// ── Singleton services ────────────────────────────────────────────────────────────────────

final videoExtractorProvider = Provider((_) => VideoExtractorService());
final dlnaServiceProvider = Provider((_) => DlnaService());
final chromecastServiceProvider = Provider((_) => ChromecastService());
final streamProxyProvider = Provider((_) => StreamProxyService());
final subtitleServiceProvider = Provider((_) => SubtitleService());
final downloadServiceProvider = Provider((_) => DownloadService());

// ── Settings ──────────────────────────────────────────────────────────────────

class AppSettings {
  final bool routeThroughPhone;
  final String openSubtitlesApiKey;
  const AppSettings({this.routeThroughPhone = true, this.openSubtitlesApiKey = ''});

  bool get hasSubtitleKey => openSubtitlesApiKey.isNotEmpty;

  AppSettings copyWith({bool? routeThroughPhone, String? openSubtitlesApiKey}) =>
      AppSettings(
        routeThroughPhone: routeThroughPhone ?? this.routeThroughPhone,
        openSubtitlesApiKey: openSubtitlesApiKey ?? this.openSubtitlesApiKey,
      );
}

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier() : super(const AppSettings()) {
    _load();
  }

  static const _keyRouteThrough = 'route_through_phone';
  static const _keySubtitleApiKey = 'opensubtitles_api_key';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = AppSettings(
      routeThroughPhone: prefs.getBool(_keyRouteThrough) ?? true,
      openSubtitlesApiKey: prefs.getString(_keySubtitleApiKey) ?? '',
    );
  }

  Future<void> toggle() async {
    final newValue = !state.routeThroughPhone;
    state = state.copyWith(routeThroughPhone: newValue);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyRouteThrough, newValue);
  }

  Future<void> setSubtitleApiKey(String key) async {
    state = state.copyWith(openSubtitlesApiKey: key.trim());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySubtitleApiKey, key.trim());
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

  /// Creates a VideoLoaded state directly for known video URLs
  /// (e.g., browser-detected direct streams) without network calls.
  void loadDirect(String url, {String? title}) {
    final uri = Uri.tryParse(url);
    final raw = uri != null && uri.pathSegments.isNotEmpty
        ? Uri.decodeComponent(uri.pathSegments.last.split('?').first)
        : '';
    final filename = raw.isNotEmpty ? raw : 'Direct Stream';

    state = VideoLoaded(
      VideoInfo(
        title: title ?? filename,
        formats: [
          StreamFormat(
            id: 'direct',
            label: 'Direct stream',
            url: url,
            height: 0,
            hasAudio: true,
          ),
        ],
      ),
      url,
    );
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
  /// Devices found so far — updated live during scan.
  final List<DlnaDevice> devicesFoundSoFar;
  const DevicesScanning({this.devicesFoundSoFar = const []});
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
  DevicesNotifier(this._dlna, this._chromecast) : super(const DevicesIdle());
  final DlnaService _dlna;
  final ChromecastService _chromecast;

  /// Stream-based scan: DLNA + Chromecast in parallel, devices appear live.
  Future<void> scan() async {
    state = const DevicesScanning();
    try {
      final found = <DlnaDevice>[];
      final seen = <String>{};

      void addDevice(DlnaDevice device) {
        if (seen.contains(device.location)) return;
        seen.add(device.location);
        found.add(device);
        if (mounted) {
          state = DevicesScanning(devicesFoundSoFar: List.unmodifiable(found));
        }
      }

      // Run DLNA and Chromecast discovery in parallel
      await Future.wait([
        (() async {
          await for (final device in _dlna.discoverStream()) {
            addDevice(device);
          }
        })(),
        (() async {
          try {
            await for (final device in _chromecast.discover()) {
              addDevice(device);
            }
          } catch (_) {
            // mDNS may fail on some networks — don't block DLNA results
          }
        })(),
      ]);

      state = DevicesResult(found);
    } catch (e) {
      state = DevicesError(_clean(e));
    }
  }
}

final devicesProvider = StateNotifierProvider<DevicesNotifier, DevicesState>(
  (ref) => DevicesNotifier(
    ref.watch(dlnaServiceProvider),
    ref.watch(chromecastServiceProvider),
  ),
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
  CastNotifier(this._dlna, this._chromecast, this._proxy, {this.onVideoFinished}) : super(const CastIdle());
  final DlnaService _dlna;
  final ChromecastService _chromecast;
  final StreamProxyService _proxy;

  /// Called when a video finishes naturally (not user-stopped).
  /// Used for auto-play-next-in-queue.
  final Future<void> Function()? onVideoFinished;

  Timer? _progressTimer;
  Timer? _sleepTimer;
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
    String? subtitleSrt,
    int? durationSeconds,
  }) async {
    state = const CastPreparing();
    try {
      String castUrl;
      String? subtitleUrl;
      String? contentType;

      if (routeThroughPhone) {
        final baseUrl = await _proxy.start(
          streamUrl: format.url,
          subtitleSrt: subtitleSrt,
        );
        if (baseUrl == null) {
          throw Exception('Could not start proxy. Make sure you\'re on WiFi.');
        }
        castUrl = '$baseUrl/stream';
        if (subtitleSrt != null) subtitleUrl = '$baseUrl/subtitle.srt';
        // Use the MIME type from the original URL, not the proxy URL.
        contentType = _proxy.originalMimeType;
      } else {
        castUrl = format.url;
      }

      if (device.protocol == CastProtocol.chromecast) {
        // ── Chromecast flow ──
        await _chromecast.connect(device);
        await _chromecast.loadMedia(
          url: castUrl,
          title: title,
          contentType: contentType ?? _guessChromecastMime(format.url),
          subtitleUrl: subtitleUrl,
        );
      } else {
        // ── DLNA flow ──
        await _dlna.setUri(device, castUrl, title,
            subtitleUrl: subtitleUrl, durationSeconds: durationSeconds,
            contentType: contentType);
        await _dlna.play(device);
      }

      state = CastPlaying(
        device: device,
        title: title,
        routedThroughPhone: routeThroughPhone,
      );
      await WakelockPlus.enable();
      _startProgressPolling(device);
    } catch (e) {
      await _proxy.stop();
      if (device.protocol == CastProtocol.chromecast) {
        await _chromecast.disconnect();
      }
      state = CastError(_clean(e));
    }
  }

  Future<void> pauseResume() async {
    final s = state;
    if (s is! CastPlaying) return;
    try {
      if (s.device.protocol == CastProtocol.chromecast) {
        if (s.isPaused) {
          await _chromecast.play();
        } else {
          await _chromecast.pause();
        }
      } else {
        if (s.isPaused) {
          await _dlna.play(s.device);
        } else {
          await _dlna.pause(s.device);
        }
      }
      state = s.copyWith(isPaused: !s.isPaused);
    } catch (_) {}
  }

  Future<void> seek(Duration position) async {
    final s = state;
    if (s is! CastPlaying) return;
    try {
      if (s.device.protocol == CastProtocol.chromecast) {
        await _chromecast.seek(position);
      } else {
        await _dlna.seek(s.device, position);
      }
      _position = position;
    } catch (_) {}
  }

  Future<void> stop() async {
    _progressTimer?.cancel();
    _pollFailures = 0;
    final s = state;
    if (s is CastPlaying) {
      try {
        if (s.device.protocol == CastProtocol.chromecast) {
          await _chromecast.stop();
          await _chromecast.disconnect();
        } else {
          await _dlna.stop(s.device);
        }
      } catch (_) {}
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
      if (!mounted || state is! CastPlaying) {
        _progressTimer?.cancel();
        return;
      }
      try {
        if (device.protocol == CastProtocol.chromecast) {
          final status = await _chromecast.getMediaStatus();
          if (status == null) return;
          _pollFailures = 0;
          _position = status.position;
          _totalDuration = status.duration;

          switch (status.state) {
            case 'IDLE':
              await _onNaturalStop();
            case 'PAUSED':
              final s = state;
              if (s is CastPlaying && !s.isPaused) state = s.copyWith(isPaused: true);
            case 'PLAYING':
            case 'BUFFERING':
              final s = state;
              if (s is CastPlaying && s.isPaused) state = s.copyWith(isPaused: false);
          }
        } else {
          final info = await _dlna.getPositionInfo(device);
          _pollFailures = 0;
          _position = info.position;
          _totalDuration = info.duration;

          switch (info.transportState) {
            case 'STOPPED':
            case 'NO_MEDIA_PRESENT':
              await _onNaturalStop();
            case 'PAUSED_PLAYBACK':
              final s = state;
              if (s is CastPlaying && !s.isPaused) state = s.copyWith(isPaused: true);
            case 'PLAYING':
              final s = state;
              if (s is CastPlaying && s.isPaused) state = s.copyWith(isPaused: false);
          }
        }
      } catch (_) {
        _pollFailures++;
        // Allow more failures before giving up — networks can be flaky.
        // After 15 consecutive failures (~30 seconds), stop polling.
        if (_pollFailures >= 15) {
          _progressTimer?.cancel();
          // Don't auto-stop — the stream might still be playing.
          // Just stop updating progress.
        }
      }
    });
  }

  /// Called when the video ends naturally. Tries auto-play-next, else stops.
  Future<void> _onNaturalStop() async {
    if (onVideoFinished != null) {
      await onVideoFinished!();
    } else {
      await stop();
    }
  }

  /// Set a sleep timer that auto-stops casting after [duration].
  void setSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    if (duration == Duration.zero) return;
    _sleepTimer = Timer(duration, () {
      stop();
    });
  }

  /// Cancel any active sleep timer.
  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
  }

  /// Whether a sleep timer is currently active.
  bool get hasSleepTimer => _sleepTimer?.isActive ?? false;

  /// MIME type helper for Chromecast (needs it in loadMedia).
  static String _guessChromecastMime(String url) {
    final lower = url.toLowerCase().split('?').first;
    if (lower.contains('.m3u8')) return 'application/x-mpegurl';
    if (lower.endsWith('.mpd')) return 'application/dash+xml';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.avi')) return 'video/x-msvideo';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.ts')) return 'video/mp2t';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.m4a') || lower.endsWith('.aac')) return 'audio/mp4';
    if (lower.endsWith('.flac')) return 'audio/flac';
    return 'video/mp4';
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _sleepTimer?.cancel();
    super.dispose();
  }
}

final castProvider = StateNotifierProvider<CastNotifier, CastState>(
  (ref) {
    late final CastNotifier notifier;
    notifier = CastNotifier(
      ref.watch(dlnaServiceProvider),
      ref.watch(chromecastServiceProvider),
      ref.watch(streamProxyProvider),
      onVideoFinished: () async {
        final queue = ref.read(queueProvider.notifier);
        final next = queue.advance();
        if (next != null) {
          // Auto-extract and cast the next queue item
          final extractor = ref.read(videoExtractorProvider);
          try {
            final info = await extractor.extract(next.url);
            if (info.formats.isNotEmpty) {
              final device = ref.read(selectedDeviceProvider);
              final settings = ref.read(settingsProvider);
              if (device != null) {
                await notifier.cast(
                  device: device,
                  format: info.formats.first,
                  title: info.title,
                  routeThroughPhone: settings.routeThroughPhone,
                );
                return;
              }
            }
          } catch (_) {}
        }
        // No next item or failed — just stop
        await notifier.stop();
      },
    );
    return notifier;
  },
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
final selectedSubtitleProvider = StateProvider<SubtitleTrack?>((ref) => null);

// URL injected from the in-app browser's "Cast" button.
final browserCastUrlProvider = StateProvider<String?>((ref) => null);

// ── Cast History ──────────────────────────────────────────────────────────────

class CastHistoryItem {
  final String url;
  final String title;
  final String? thumbnailUrl;
  final DateTime castAt;

  CastHistoryItem({
    required this.url,
    required this.title,
    this.thumbnailUrl,
    DateTime? castAt,
  }) : castAt = castAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'thumbnailUrl': thumbnailUrl,
        'castAt': castAt.toIso8601String(),
      };

  factory CastHistoryItem.fromJson(Map<String, dynamic> json) => CastHistoryItem(
        url: json['url'] as String,
        title: json['title'] as String,
        thumbnailUrl: json['thumbnailUrl'] as String?,
        castAt: DateTime.tryParse(json['castAt'] as String? ?? '') ?? DateTime.now(),
      );
}

class CastHistoryNotifier extends StateNotifier<List<CastHistoryItem>> {
  CastHistoryNotifier() : super([]) {
    _load();
  }

  static const _key = 'cast_history';
  static const _maxItems = 20;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => CastHistoryItem.fromJson(e as Map<String, dynamic>))
          .toList();
      state = list;
    } catch (_) {}
  }

  Future<void> add(String url, String title, String? thumbnailUrl) async {
    // Remove duplicate if exists, then prepend
    final items = state.where((i) => i.url != url).toList();
    items.insert(0, CastHistoryItem(url: url, title: title, thumbnailUrl: thumbnailUrl));
    if (items.length > _maxItems) items.removeRange(_maxItems, items.length);
    state = items;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(items.map((i) => i.toJson()).toList()));
  }

  Future<void> clear() async {
    state = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

final castHistoryProvider =
    StateNotifierProvider<CastHistoryNotifier, List<CastHistoryItem>>(
        (_) => CastHistoryNotifier());

// ── Last Used Device ──────────────────────────────────────────────────────────

class LastDeviceNotifier extends StateNotifier<String?> {
  LastDeviceNotifier() : super(null) {
    _load();
  }

  static const _key = 'last_device_location';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getString(_key);
  }

  Future<void> save(String deviceLocation) async {
    state = deviceLocation;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, deviceLocation);
  }
}

final lastDeviceProvider =
    StateNotifierProvider<LastDeviceNotifier, String?>((_) => LastDeviceNotifier());

// ── Helpers ───────────────────────────────────────────────────────────────────

String _clean(Object e) =>
    e.toString().replaceFirst('Exception: ', '').replaceFirst('FormatException: ', '');
