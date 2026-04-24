import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'privacy_telemetry.dart';

// ── Bookmarks ─────────────────────────────────────────────────────────────────

class Bookmark {
  final String url;
  final String title;
  final String? favicon;
  final DateTime addedAt;

  Bookmark(
      {required this.url, required this.title, this.favicon, DateTime? addedAt})
      : addedAt = addedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'favicon': favicon,
        'addedAt': addedAt.toIso8601String(),
      };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        url: json['url'] as String,
        title: json['title'] as String,
        favicon: json['favicon'] as String?,
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ??
            DateTime.now(),
      );
}

class BookmarksNotifier extends StateNotifier<List<Bookmark>> {
  BookmarksNotifier() : super([]) {
    _load();
  }

  static const _key = 'browser_bookmarks';

  Future<int> _maxEntries() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(kPrivacyBookmarksLimitKey) ?? 500;
  }

  static String _normalizeBookmarkUrl(String url) {
    final raw = url.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null) return raw;

    var path = uri.path;
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }

    final normalized = uri.replace(
      path: path,
      fragment: '',
    );
    return normalized.toString();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final decoded = (jsonDecode(raw) as List)
          .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
          .toList();

      // De-duplicate legacy entries and keep newest first.
      final byUrl = <String, Bookmark>{};
      for (final b in decoded) {
        byUrl[_normalizeBookmarkUrl(b.url)] = b;
      }
      final compact = byUrl.values.toList()
        ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
      state = compact.take(await _maxEntries()).toList();
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(state.map((b) => b.toJson()).toList()));
  }

  Future<void> add(String url, String title, {String? favicon}) async {
    final maxEntries = await _maxEntries();
    final normalized = _normalizeBookmarkUrl(url);
    final filtered =
        state.where((b) => _normalizeBookmarkUrl(b.url) != normalized).toList();
    filtered.insert(0, Bookmark(url: url, title: title, favicon: favicon));
    if (filtered.length > maxEntries) {
      filtered.removeRange(maxEntries, filtered.length);
    }
    state = filtered;
    await _save();
  }

  Future<void> remove(String url) async {
    final normalized = _normalizeBookmarkUrl(url);
    state =
        state.where((b) => _normalizeBookmarkUrl(b.url) != normalized).toList();
    await _save();
  }

  bool isBookmarked(String url) {
    final normalized = _normalizeBookmarkUrl(url);
    return state.any((b) => _normalizeBookmarkUrl(b.url) == normalized);
  }

  Future<void> clear() async {
    state = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  List<Map<String, dynamic>> exportJson() =>
      state.map((b) => b.toJson()).toList(growable: false);

  Future<void> importJson(List<dynamic> raw) async {
    final entries = raw
        .whereType<Map>()
        .map((e) => Bookmark.fromJson(e.cast<String, dynamic>()))
        .toList();
    final maxEntries = await _maxEntries();
    final byUrl = <String, Bookmark>{};
    for (final b in entries) {
      byUrl[_normalizeBookmarkUrl(b.url)] = b;
    }
    final compact = byUrl.values.toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    state = compact.take(maxEntries).toList();
    await _save();
  }

  Future<void> applyLimit() async {
    final maxEntries = await _maxEntries();
    if (state.length <= maxEntries) return;
    state = state.take(maxEntries).toList();
    await _save();
  }
}

final bookmarksProvider =
    StateNotifierProvider<BookmarksNotifier, List<Bookmark>>(
        (_) => BookmarksNotifier());

// ── Browsing History ──────────────────────────────────────────────────────────

class HistoryEntry {
  final String url;
  final String title;
  final DateTime visitedAt;

  HistoryEntry({required this.url, required this.title, DateTime? visitedAt})
      : visitedAt = visitedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'visitedAt': visitedAt.toIso8601String(),
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        url: json['url'] as String,
        title: json['title'] as String,
        visitedAt: DateTime.tryParse(json['visitedAt'] as String? ?? '') ??
            DateTime.now(),
      );
}

class HistoryNotifier extends StateNotifier<List<HistoryEntry>> {
  HistoryNotifier() : super([]) {
    _load();
  }

  static const _key = 'browser_history';

  Future<int> _maxEntries() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(kPrivacyHistoryLimitKey) ?? 500;
  }

  static String _normalizeHistoryUrl(String url) {
    final raw = url.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null) return raw;

    var path = uri.path;
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }

    return uri.replace(path: path, fragment: '').toString();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      state = list.take(await _maxEntries()).toList();
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(state.map((h) => h.toJson()).toList()));
  }

  Future<void> add(String url, String title) async {
    final maxEntries = await _maxEntries();
    // Skip internal pages
    if (url.startsWith('about:') || url.startsWith('data:')) return;
    final normalized = _normalizeHistoryUrl(url);
    // Remove existing entry for same URL (will be re-added at top)
    final updated =
        state.where((h) => _normalizeHistoryUrl(h.url) != normalized).toList();
    updated.insert(0, HistoryEntry(url: url, title: title));
    if (updated.length > maxEntries) {
      updated.removeRange(maxEntries, updated.length);
    }
    state = updated;
    await _save();
  }

  List<HistoryEntry> search(String query) {
    final q = query.toLowerCase();
    return state
        .where((h) =>
            h.title.toLowerCase().contains(q) ||
            h.url.toLowerCase().contains(q))
        .toList();
  }

  Future<void> removeEntry(String url) async {
    final normalized = _normalizeHistoryUrl(url);
    state =
        state.where((h) => _normalizeHistoryUrl(h.url) != normalized).toList();
    await _save();
  }

  Future<void> clear() async {
    state = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  List<Map<String, dynamic>> exportJson() =>
      state.map((h) => h.toJson()).toList(growable: false);

  Future<void> importJson(List<dynamic> raw) async {
    final entries = raw
        .whereType<Map>()
        .map((e) => HistoryEntry.fromJson(e.cast<String, dynamic>()))
        .toList();
    final maxEntries = await _maxEntries();
    state = entries.take(maxEntries).toList();
    await _save();
  }

  Future<void> applyLimit() async {
    final maxEntries = await _maxEntries();
    if (state.length <= maxEntries) return;
    state = state.take(maxEntries).toList();
    await _save();
  }
}

final historyProvider =
    StateNotifierProvider<HistoryNotifier, List<HistoryEntry>>(
        (_) => HistoryNotifier());
