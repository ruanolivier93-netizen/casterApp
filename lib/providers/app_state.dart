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
import '../services/cast_background_service.dart';
import '../services/subtitle_service.dart';
import '../services/download_service.dart';
import '../providers/queue_provider.dart';
import 'privacy_telemetry.dart';

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
  final bool adBlockEnabled;
  final String openSubtitlesApiKey;
  const AppSettings(
      {this.routeThroughPhone = true,
      this.adBlockEnabled = true,
      this.openSubtitlesApiKey = ''});

  bool get hasSubtitleKey => openSubtitlesApiKey.isNotEmpty;

  AppSettings copyWith(
          {bool? routeThroughPhone,
          bool? adBlockEnabled,
          String? openSubtitlesApiKey}) =>
      AppSettings(
        routeThroughPhone: routeThroughPhone ?? this.routeThroughPhone,
        adBlockEnabled: adBlockEnabled ?? this.adBlockEnabled,
        openSubtitlesApiKey: openSubtitlesApiKey ?? this.openSubtitlesApiKey,
      );
}

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier() : super(const AppSettings()) {
    _load();
  }

  static const _keyRouteThrough = 'route_through_phone';
  static const _keyAdBlockEnabled = 'ad_block_enabled';
  static const _keySubtitleApiKey = 'opensubtitles_api_key';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = AppSettings(
      routeThroughPhone: prefs.getBool(_keyRouteThrough) ?? true,
      adBlockEnabled: prefs.getBool(_keyAdBlockEnabled) ?? true,
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

  Future<void> toggleAdBlock() async {
    final newValue = !state.adBlockEnabled;
    state = state.copyWith(adBlockEnabled: newValue);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAdBlockEnabled, newValue);
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>(
    (_) => SettingsNotifier());

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
  CastNotifier(this._dlna, this._chromecast, this._proxy, this._telemetry,
      {this.onVideoFinished})
      : super(const CastIdle());
  final DlnaService _dlna;
  final ChromecastService _chromecast;
  final StreamProxyService _proxy;
  final TelemetryNotifier _telemetry;

  /// Called when a video finishes naturally (not user-stopped).
  /// Used for auto-play-next-in-queue.
  final Future<void> Function()? onVideoFinished;

  Timer? _progressTimer;
  Timer? _sleepTimer;
  Duration _position = Duration.zero;
  Duration _totalDuration = Duration.zero;
  int _pollFailures = 0;
  int _consecutiveStoppedPolls = 0;
  DateTime? _castStartTime;
  DateTime? _lastSeekAt;
  bool _hasEverPlayed = false;
  bool _seekInFlight = false;
  Duration? _pendingSeekTarget;

  static const Duration _seekStabilizationWindow = Duration(seconds: 12);

  Duration get position => _position;
  Duration get totalDuration => _totalDuration;
  bool get isSeekInFlight => _seekInFlight;

  Future<void> cast({
    required DlnaDevice device,
    required StreamFormat format,
    required String title,
    required bool routeThroughPhone,
    String? subtitleSrt,
    int? durationSeconds,
    String? refererUrl,
  }) async {
    state = const CastPreparing();
    _position = Duration.zero;
    _totalDuration = Duration.zero;

    var usePhoneProxy = routeThroughPhone ||
        _mustRouteThroughPhone(
          format.url,
          subtitleSrt: subtitleSrt,
          refererUrl: refererUrl,
        );
    String? directCastError;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        String castUrl;
        String? subtitleUrl;
        String? contentType;

        if (usePhoneProxy) {
          final baseUrl = await _proxy.start(
            streamUrl: format.url,
            subtitleSrt: subtitleSrt,
            refererUrl: refererUrl,
          );
          if (baseUrl == null) {
            throw Exception(
                'Could not start proxy. Make sure you\'re on WiFi.');
          }
          castUrl = '$baseUrl/stream';
          if (subtitleSrt != null) subtitleUrl = '$baseUrl/subtitle.srt';
          // Use the MIME type from the original URL, not the proxy URL.
          contentType = _proxy.originalMimeType;
        } else {
          castUrl = format.url;
        }

        // Use probed duration/size from the proxy if the caller didn't provide them.
        final effectiveDuration = durationSeconds ??
            (usePhoneProxy ? _proxy.probedDurationSeconds : null);
        final fileSize = usePhoneProxy ? _proxy.probedContentLength : null;

        // Pre-set total duration so the app's seekbar works from the start.
        if (effectiveDuration != null && effectiveDuration > 0) {
          _totalDuration = Duration(seconds: effectiveDuration);
        }

        if (device.protocol == CastProtocol.chromecast) {
          // ── Chromecast flow ──
          await _chromecast.connect(device);
          await _chromecast.loadMedia(
            url: castUrl,
            title: title,
            contentType: contentType ?? _guessChromecastMime(format.url),
            subtitleUrl: subtitleUrl,
            durationSeconds: effectiveDuration,
          );
        } else {
          // ── DLNA flow ──
          await _dlna.setUri(device, castUrl, title,
              subtitleUrl: subtitleUrl,
              durationSeconds: effectiveDuration,
              contentType: contentType,
              fileSize: fileSize);
          await _dlna.play(device);
        }

        state = CastPlaying(
          device: device,
          title: title,
          routedThroughPhone: usePhoneProxy,
        );
        await _telemetry.log(
          'cast_started',
          payload: {
            'protocol': device.protocol.name,
            'routedThroughPhone': usePhoneProxy,
            'title': title,
          },
        );
        await WakelockPlus.enable();
        await CastBackgroundService.start('Casting to ${device.name}');
        _castStartTime = DateTime.now();
        _lastSeekAt = null;
        _hasEverPlayed = false;
        _consecutiveStoppedPolls = 0;
        _startProgressPolling(device);
        return;
      } catch (e) {
        await _proxy.stop();
        if (device.protocol == CastProtocol.chromecast) {
          await _chromecast.disconnect();
        }

        // If direct cast fails, retry once through the phone proxy automatically.
        if (!usePhoneProxy && attempt == 0) {
          directCastError = _clean(e);
          await _telemetry.log(
            'cast_direct_fallback',
            payload: {
              'protocol': device.protocol.name,
              'error': directCastError,
            },
          );
          usePhoneProxy = true;
          continue;
        }

        final baseError = _clean(e);
        if (directCastError != null && !routeThroughPhone) {
          state =
              CastError('$baseError (Direct mode failed: $directCastError)');
        } else {
          state = CastError(baseError);
        }
        await _telemetry.log(
          'cast_error',
          payload: {
            'protocol': device.protocol.name,
            'routedThroughPhone': usePhoneProxy,
            'error': baseError,
          },
        );
        return;
      }
    }
  }

  bool _mustRouteThroughPhone(
    String streamUrl, {
    String? subtitleSrt,
    String? refererUrl,
  }) {
    final uri = Uri.tryParse(streamUrl);
    if (uri == null) return true;

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return true;
    }

    // Subtitles are served by the local proxy, so route through phone.
    if (subtitleSrt != null && subtitleSrt.isNotEmpty) {
      return true;
    }

    final lower = streamUrl.toLowerCase();

    // Adaptive streams and signed URLs are frequently denied when fetched
    // directly by TVs (missing cookies/referer/header constraints).
    if (lower.contains('.m3u8') || lower.endsWith('.mpd')) {
      return true;
    }

    const authHints = [
      'signature=',
      'sig=',
      'token=',
      'expires=',
      'exp=',
      'auth=',
      'policy=',
      'hdnea=',
    ];
    if (authHints.any(lower.contains)) {
      return true;
    }

    if (refererUrl != null && refererUrl.isNotEmpty) {
      final referer = Uri.tryParse(refererUrl);
      if (referer != null &&
          referer.host.isNotEmpty &&
          referer.host != uri.host) {
        return true;
      }
    }

    return false;
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

  void _touchState() {
    final s = state;
    if (s is CastPlaying) {
      state = s.copyWith();
    }
  }

  Future<bool> seek(Duration position) async {
    final s = state;
    if (s is! CastPlaying) return false;
    // Clamp to valid range. Always enforce >= 0; cap by total only when known.
    final maxMs = _totalDuration.inMilliseconds > 0
        ? _totalDuration.inMilliseconds
        : 1 << 31;
    final ms = position.inMilliseconds.clamp(0, maxMs);
    final clamped = Duration(milliseconds: ms);
    _pendingSeekTarget = clamped;

    // Coalesce rapid seek requests and process only one in-flight command.
    if (_seekInFlight) return true;

    _seekInFlight = true;
    _touchState();

    var success = false;
    try {
      while (_pendingSeekTarget != null) {
        final target = _pendingSeekTarget!;
        _pendingSeekTarget = null;
        try {
          if (s.device.protocol == CastProtocol.chromecast) {
            await _chromecast.seek(target);
          } else {
            await _dlna.seek(s.device, target);
          }
          _position = target;
          _lastSeekAt = DateTime.now();
          _consecutiveStoppedPolls = 0;
          _pollFailures = 0;
          success = true;
          _touchState();
        } catch (_) {
          if (_pendingSeekTarget == null) {
            return false;
          }
        }
      }
      return success;
    } finally {
      _seekInFlight = false;
      _touchState();
    }
  }

  /// Skip forward or backward by [delta] from the current position.
  /// When another seek is already in flight or queued, accumulate from the
  /// queued target instead of the (stale) polled position so rapid taps
  /// of ±10s actually compound (e.g. tapping +10s twice goes +20s).
  Future<bool> seekRelative(Duration delta) async {
    final base = _pendingSeekTarget ?? _position;
    final target = base + delta;
    return seek(target);
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
    await CastBackgroundService.stop();
    await WakelockPlus.disable();
    _position = Duration.zero;
    _totalDuration = Duration.zero;
    _castStartTime = null;
    _lastSeekAt = null;
    _hasEverPlayed = false;
    _seekInFlight = false;
    _pendingSeekTarget = null;
    _consecutiveStoppedPolls = 0;
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

      // Grace period: ignore STOPPED/IDLE states for the first 10 seconds
      // after a cast starts.  Many TVs briefly report NO_MEDIA_PRESENT or
      // STOPPED while they buffer the first few seconds.
      final inGracePeriod = _castStartTime != null &&
          DateTime.now().difference(_castStartTime!).inSeconds < 10;
      final inSeekStabilizationWindow = _lastSeekAt != null &&
          DateTime.now().difference(_lastSeekAt!) < _seekStabilizationWindow;

      try {
        if (device.protocol == CastProtocol.chromecast) {
          final status = await _chromecast.getMediaStatus();
          if (status == null) return;
          _pollFailures = 0;
          _position = status.position;
          // Only update duration if the TV/Chromecast reports a positive value.
          // Otherwise keep the probed duration we pre-set.
          if (status.duration > Duration.zero) {
            _totalDuration = status.duration;
          }

          switch (status.state) {
            case 'IDLE':
              if (!inGracePeriod &&
                  !inSeekStabilizationWindow &&
                  _hasEverPlayed) {
                _consecutiveStoppedPolls++;
                // Require 3 consecutive STOPPED/IDLE polls (~6 seconds)
                // before treating it as a natural end.  TVs often briefly
                // report IDLE/STOPPED during rebuffering or segment gaps.
                if (_consecutiveStoppedPolls >= 3) {
                  await _onNaturalStop();
                }
              }
            case 'PAUSED':
              _hasEverPlayed = true;
              _consecutiveStoppedPolls = 0;
              final s = state;
              if (s is CastPlaying && !s.isPaused) {
                state = s.copyWith(isPaused: true);
              }
            case 'PLAYING':
            case 'BUFFERING':
              _hasEverPlayed = true;
              _consecutiveStoppedPolls = 0;
              final s = state;
              if (s is CastPlaying && s.isPaused) {
                state = s.copyWith(isPaused: false);
              }
          }
          _touchState();
        } else {
          final info = await _dlna.getPositionInfo(device);
          _pollFailures = 0;
          _position = info.position;
          // Only use the TV's reported duration if it's > 0.
          // Many TVs report 0:00:00 for streams where the DIDL
          // metadata wasn't parsed.  Keep the probed duration.
          if (info.duration > Duration.zero) {
            _totalDuration = info.duration;
          }

          switch (info.transportState) {
            case 'STOPPED':
            case 'NO_MEDIA_PRESENT':
              if (!inGracePeriod &&
                  !inSeekStabilizationWindow &&
                  _hasEverPlayed) {
                _consecutiveStoppedPolls++;
                // Require 3 consecutive STOPPED/NO_MEDIA polls (~6 seconds)
                // before treating it as a natural end.  TVs often briefly
                // report these states during rebuffering or segment gaps.
                if (_consecutiveStoppedPolls >= 3) {
                  await _onNaturalStop();
                }
              }
            case 'PAUSED_PLAYBACK':
              _hasEverPlayed = true;
              _consecutiveStoppedPolls = 0;
              final s = state;
              if (s is CastPlaying && !s.isPaused) {
                state = s.copyWith(isPaused: true);
              }
            case 'PLAYING':
            case 'TRANSITIONING':
              _hasEverPlayed = true;
              _consecutiveStoppedPolls = 0;
              final s = state;
              if (s is CastPlaying && s.isPaused) {
                state = s.copyWith(isPaused: false);
              }
          }
          _touchState();
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
      ref.watch(telemetryProvider.notifier),
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
final castPositionProvider =
    Provider<({Duration position, Duration total})>((ref) {
  ref.watch(castProvider); // re-evaluate when cast state changes
  final notifier = ref.read(castProvider.notifier);
  return (position: notifier.position, total: notifier.totalDuration);
});

final castSeekInFlightProvider = Provider<bool>((ref) {
  ref.watch(castProvider);
  final notifier = ref.read(castProvider.notifier);
  return notifier.isSeekInFlight;
});

// ── Selected device / format ──────────────────────────────────────────────────

final selectedDeviceProvider = StateProvider<DlnaDevice?>((ref) => null);
final selectedFormatProvider = StateProvider<StreamFormat?>((ref) => null);
final selectedSubtitleProvider = StateProvider<SubtitleTrack?>((ref) => null);

// URL injected from the in-app browser's "Cast" button.
final browserCastUrlProvider = StateProvider<String?>((ref) => null);

// The page URL the user was on when they tapped "Cast" — used as the
// Referer when the proxy fetches from the CDN.
final browserPageUrlProvider = StateProvider<String?>((ref) => null);

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

  factory CastHistoryItem.fromJson(Map<String, dynamic> json) =>
      CastHistoryItem(
        url: json['url'] as String,
        title: json['title'] as String,
        thumbnailUrl: json['thumbnailUrl'] as String?,
        castAt: DateTime.tryParse(json['castAt'] as String? ?? '') ??
            DateTime.now(),
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
    items.insert(
        0, CastHistoryItem(url: url, title: title, thumbnailUrl: thumbnailUrl));
    if (items.length > _maxItems) items.removeRange(_maxItems, items.length);
    state = items;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(items.map((i) => i.toJson()).toList()));
  }

  Future<void> clear() async {
    state = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  List<Map<String, dynamic>> exportJson() =>
      state.map((i) => i.toJson()).toList(growable: false);

  Future<void> importJson(List<dynamic> raw) async {
    final parsed = raw
        .whereType<Map>()
        .map((e) => CastHistoryItem.fromJson(e.cast<String, dynamic>()))
        .toList();
    state = parsed.take(_maxItems).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(state.map((i) => i.toJson()).toList()));
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

final lastDeviceProvider = StateNotifierProvider<LastDeviceNotifier, String?>(
    (_) => LastDeviceNotifier());

// ── Helpers ───────────────────────────────────────────────────────────────────

String _clean(Object e) => e
    .toString()
    .replaceFirst('Exception: ', '')
    .replaceFirst('FormatException: ', '');
