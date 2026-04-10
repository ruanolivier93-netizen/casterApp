import 'dart:io';
import 'package:flutter/services.dart';

/// Starts / stops an Android foreground service that keeps the Dart isolate,
/// proxy server, and WiFi alive while the phone screen is off or the user
/// switches to another app.
///
/// On iOS the OS already allows background audio / network activity when
/// properly configured, so this is Android-only for now.
class CastBackgroundService {
  static const _channel = MethodChannel('com.videocaster/foreground');

  /// Begin the foreground service.  Shows a persistent notification with
  /// [title] (e.g. "Casting to Living Room TV").
  static Future<void> start(String title) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('start', {'title': title});
    } catch (_) {}
  }

  /// Stop the foreground service and release all wake / WiFi locks.
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
