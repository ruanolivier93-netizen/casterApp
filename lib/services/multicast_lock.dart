import 'dart:io';
import 'package:flutter/services.dart';

/// Acquires/releases Android's WifiManager.MulticastLock so the OS
/// doesn't filter out SSDP/UPnP multicast packets on WiFi.
/// Without this, DLNA device discovery silently fails on Android 10+.
class MulticastLock {
  static const _channel = MethodChannel('com.videocaster/multicast');

  static Future<void> acquire() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('acquire');
    } catch (_) {}
  }

  static Future<void> release() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('release');
    } catch (_) {}
  }
}
