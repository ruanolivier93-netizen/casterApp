import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Bookmarks ─────────────────────────────────────────────────────────────────

class Bookmark {
  final String url;
  final String title;
  final String? favicon;
  final DateTime addedAt;

  Bookmark({required this.url, required this.title, this.favicon, DateTime? addedAt})
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
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
      );
}

class BookmarksNotifier extends StateNotifier<List<Bookmark>> {
  BookmarksNotifier() : super([]) {
    _load();
  }

  static const _key = 'browser_bookmarks';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      state = (jsonDecode(raw) as List)
          .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(state.map((b) => b.toJson()).toList()));
  }

  Future<void> add(String url, String title, {String? favicon}) async {
    // Don't add duplicates
    if (state.any((b) => b.url == url)) return;
    state = [Bookmark(url: url, title: title, favicon: favicon), ...state];
    await _save();
  }

  Future<void> remove(String url) async {
    state = state.where((b) => b.url != url).toList();
    await _save();
  }

  bool isBookmarked(String url) => state.any((b) => b.url == url);

  Future<void> clear() async {
    state = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
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
        visitedAt: DateTime.tryParse(json['visitedAt'] as String? ?? '') ?? DateTime.now(),
      );
}

class HistoryNotifier extends StateNotifier<List<HistoryEntry>> {
  HistoryNotifier() : super([]) {
    _load();
  }

  static const _key = 'browser_history';
  static const _maxEntries = 500;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      state = (jsonDecode(raw) as List)
          .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(state.map((h) => h.toJson()).toList()));
  }

  Future<void> add(String url, String title) async {
    // Skip internal pages
    if (url.startsWith('about:') || url.startsWith('data:')) return;
    // Remove existing entry for same URL (will be re-added at top)
    final updated = state.where((h) => h.url != url).toList();
    updated.insert(0, HistoryEntry(url: url, title: title));
    if (updated.length > _maxEntries) {
      updated.removeRange(_maxEntries, updated.length);
    }
    state = updated;
    await _save();
  }

  List<HistoryEntry> search(String query) {
    final q = query.toLowerCase();
    return state.where((h) =>
        h.title.toLowerCase().contains(q) ||
        h.url.toLowerCase().contains(q)).toList();
  }

  Future<void> removeEntry(String url) async {
    state = state.where((h) => h.url != url).toList();
    await _save();
  }

  Future<void> clear() async {
    state = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

final historyProvider =
    StateNotifierProvider<HistoryNotifier, List<HistoryEntry>>(
        (_) => HistoryNotifier());
