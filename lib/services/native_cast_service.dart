import 'dart:async';

import 'package:flutter/services.dart';

class NativeCastState {
  final bool connected;
  final String? deviceName;
  final String? playerState;
  final String? idleReason;
  final int positionMs;
  final int durationMs;
  final String? title;
  final String? subtitle;
  final bool isPlayingAd;
  final bool isLive;

  const NativeCastState({
    required this.connected,
    this.deviceName,
    this.playerState,
    this.idleReason,
    this.positionMs = 0,
    this.durationMs = 0,
    this.title,
    this.subtitle,
    this.isPlayingAd = false,
    this.isLive = false,
  });

  bool get isPlaying => playerState == 'playing' || playerState == 'buffering';
  bool get isPaused => playerState == 'paused';

  factory NativeCastState.fromMap(Map<Object?, Object?> map) {
    return NativeCastState(
      connected: map['connected'] == true,
      deviceName: map['deviceName'] as String?,
      playerState: map['playerState'] as String?,
      idleReason: map['idleReason'] as String?,
      positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      title: map['title'] as String?,
      subtitle: map['subtitle'] as String?,
      isPlayingAd: map['isPlayingAd'] == true,
      isLive: map['isLive'] == true,
    );
  }

  static const empty = NativeCastState(connected: false);
}

class NativeCastService {
  NativeCastService._();

  static const MethodChannel _methodChannel =
      MethodChannel('com.videocaster/cast_native');
  static const EventChannel _eventChannel =
      EventChannel('com.videocaster/cast_events');

  static Stream<NativeCastState>? _stateStream;

  static Stream<NativeCastState> get stateStream {
    return _stateStream ??= _eventChannel
        .receiveBroadcastStream()
        .map((event) {
          if (event is Map<Object?, Object?> && event['type'] == 'state') {
            return NativeCastState.fromMap(event);
          }
          return null;
        })
        .where((event) => event != null)
        .cast<NativeCastState>()
        .asBroadcastStream();
  }

  static Future<NativeCastState> getState() async {
    final raw = await _methodChannel.invokeMethod<Map<Object?, Object?>>('getState');
    if (raw == null) return NativeCastState.empty;
    return NativeCastState.fromMap(raw);
  }

  static Future<void> showCastDialog() async {
    await _methodChannel.invokeMethod('showCastDialog');
  }

  static Future<void> loadMedia({
    required String url,
    required String title,
    String? subtitle,
    String? subtitleLanguage,
    String? subtitleLabel,
    String? contentType,
    int? durationMs,
    String? imageUrl,
    String? subtitleUrl,
  }) async {
    await _methodChannel.invokeMethod('loadMedia', {
      'url': url,
      'title': title,
      if (subtitle != null) 'subtitle': subtitle,
      if (subtitleLanguage != null) 'subtitleLanguage': subtitleLanguage,
      if (subtitleLabel != null) 'subtitleLabel': subtitleLabel,
      if (contentType != null) 'contentType': contentType,
      if (durationMs != null) 'durationMs': durationMs,
      if (imageUrl != null) 'imageUrl': imageUrl,
      if (subtitleUrl != null) 'subtitleUrl': subtitleUrl,
    });
  }

  static Future<void> play() => _methodChannel.invokeMethod('play');
  static Future<void> pause() => _methodChannel.invokeMethod('pause');
  static Future<void> togglePlayback() => _methodChannel.invokeMethod('togglePlayback');
  static Future<void> seekTo(int positionMs) =>
      _methodChannel.invokeMethod('seekTo', {'positionMs': positionMs});

  static Future<double?> getVolume() async {
    final raw = await _methodChannel.invokeMethod<num>('getVolume');
    return raw?.toDouble();
  }

  static Future<void> setVolume(double level) =>
      _methodChannel.invokeMethod('setVolume', {'level': level});

  static Future<void> stop() => _methodChannel.invokeMethod('stop');
}