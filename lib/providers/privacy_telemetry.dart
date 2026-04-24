import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const kPrivacyBookmarksLimitKey = 'privacy_bookmarks_limit';
const kPrivacyHistoryLimitKey = 'privacy_history_limit';
const kPrivacyClearOnStartKey = 'privacy_clear_browsing_on_start';
const kTelemetryEnabledKey = 'telemetry_enabled';

class PrivacySettings {
  final int bookmarksLimit;
  final int historyLimit;
  final bool clearBrowsingDataOnStart;
  final bool telemetryEnabled;

  const PrivacySettings({
    this.bookmarksLimit = 500,
    this.historyLimit = 500,
    this.clearBrowsingDataOnStart = false,
    this.telemetryEnabled = true,
  });

  PrivacySettings copyWith({
    int? bookmarksLimit,
    int? historyLimit,
    bool? clearBrowsingDataOnStart,
    bool? telemetryEnabled,
  }) {
    return PrivacySettings(
      bookmarksLimit: bookmarksLimit ?? this.bookmarksLimit,
      historyLimit: historyLimit ?? this.historyLimit,
      clearBrowsingDataOnStart:
          clearBrowsingDataOnStart ?? this.clearBrowsingDataOnStart,
      telemetryEnabled: telemetryEnabled ?? this.telemetryEnabled,
    );
  }
}

class PrivacySettingsNotifier extends StateNotifier<PrivacySettings> {
  PrivacySettingsNotifier() : super(const PrivacySettings()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = PrivacySettings(
      bookmarksLimit: prefs.getInt(kPrivacyBookmarksLimitKey) ?? 500,
      historyLimit: prefs.getInt(kPrivacyHistoryLimitKey) ?? 500,
      clearBrowsingDataOnStart: prefs.getBool(kPrivacyClearOnStartKey) ?? false,
      telemetryEnabled: prefs.getBool(kTelemetryEnabledKey) ?? true,
    );
  }

  Future<void> setBookmarksLimit(int limit) async {
    state = state.copyWith(bookmarksLimit: limit);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kPrivacyBookmarksLimitKey, limit);
  }

  Future<void> setHistoryLimit(int limit) async {
    state = state.copyWith(historyLimit: limit);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kPrivacyHistoryLimitKey, limit);
  }

  Future<void> setClearBrowsingDataOnStart(bool enabled) async {
    state = state.copyWith(clearBrowsingDataOnStart: enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPrivacyClearOnStartKey, enabled);
  }

  Future<void> setTelemetryEnabled(bool enabled) async {
    state = state.copyWith(telemetryEnabled: enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kTelemetryEnabledKey, enabled);
  }
}

final privacySettingsProvider =
    StateNotifierProvider<PrivacySettingsNotifier, PrivacySettings>(
        (_) => PrivacySettingsNotifier());

class TelemetryEvent {
  final String name;
  final DateTime at;
  final Map<String, dynamic> payload;

  const TelemetryEvent({
    required this.name,
    required this.at,
    required this.payload,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'at': at.toIso8601String(),
        'payload': payload,
      };

  factory TelemetryEvent.fromJson(Map<String, dynamic> json) => TelemetryEvent(
        name: json['name'] as String? ?? 'unknown',
        at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
        payload: (json['payload'] as Map?)?.cast<String, dynamic>() ?? {},
      );
}

class TelemetryNotifier extends StateNotifier<List<TelemetryEvent>> {
  TelemetryNotifier() : super(const []) {
    _load();
  }

  static const _key = 'telemetry_events';
  static const _maxItems = 300;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => TelemetryEvent.fromJson(e as Map<String, dynamic>))
          .toList();
      state = list;
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(state.map((e) => e.toJson()).toList()));
  }

  Future<void> log(String name,
      {Map<String, dynamic> payload = const {}}) async {
    final prefs = await SharedPreferences.getInstance();
    final telemetryEnabled = prefs.getBool(kTelemetryEnabledKey) ?? true;
    if (!telemetryEnabled) return;

    final list = <TelemetryEvent>[
      TelemetryEvent(name: name, at: DateTime.now(), payload: payload),
      ...state,
    ];
    if (list.length > _maxItems) {
      list.removeRange(_maxItems, list.length);
    }
    state = list;
    await _save();
  }

  Future<void> clear() async {
    state = const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  List<Map<String, dynamic>> exportJson() =>
      state.map((e) => e.toJson()).toList(growable: false);

  Future<void> importJson(List<dynamic> raw) async {
    final parsed = raw
        .whereType<Map>()
        .map((e) => TelemetryEvent.fromJson(e.cast<String, dynamic>()))
        .toList();
    state = parsed.take(_maxItems).toList();
    await _save();
  }
}

final telemetryProvider =
    StateNotifierProvider<TelemetryNotifier, List<TelemetryEvent>>(
        (_) => TelemetryNotifier());
