import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A single video in the cast queue.
class QueueItem {
  final String url;
  final String title;
  final String? thumbnailUrl;

  const QueueItem({required this.url, required this.title, this.thumbnailUrl});
}

/// Manages a queue of videos to cast sequentially.
class QueueNotifier extends StateNotifier<List<QueueItem>> {
  QueueNotifier() : super([]);

  int _currentIndex = -1;
  int get currentIndex => _currentIndex;

  /// Add a video to the end of the queue.
  void add(QueueItem item) {
    state = [...state, item];
  }

  /// Add a video next in queue (after current).
  void addNext(QueueItem item) {
    final list = [...state];
    final insertAt = (_currentIndex + 1).clamp(0, list.length);
    list.insert(insertAt, item);
    state = list;
  }

  /// Remove a video from the queue by index.
  void removeAt(int index) {
    final list = [...state];
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    if (_currentIndex >= list.length) _currentIndex = list.length - 1;
    if (index < _currentIndex) _currentIndex--;
    state = list;
  }

  /// Reorder items (for drag-and-drop).
  void reorder(int oldIndex, int newIndex) {
    final list = [...state];
    if (oldIndex < newIndex) newIndex--;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    // Update current index tracking
    if (_currentIndex == oldIndex) {
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _currentIndex--;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _currentIndex++;
    }
    state = list;
  }

  /// Mark the current playing item.
  void setCurrent(int index) {
    _currentIndex = index.clamp(-1, state.length - 1);
    // Trigger rebuild
    state = [...state];
  }

  /// Get next item in queue (null if at end).
  QueueItem? get next {
    final nextIdx = _currentIndex + 1;
    if (nextIdx >= state.length) return null;
    return state[nextIdx];
  }

  /// Advance to next and return it.
  QueueItem? advance() {
    final n = next;
    if (n != null) _currentIndex++;
    state = [...state]; // trigger rebuild
    return n;
  }

  /// Clear entire queue.
  void clear() {
    _currentIndex = -1;
    state = [];
  }

  bool get hasNext => _currentIndex + 1 < state.length;
  bool get isEmpty => state.isEmpty;
  int get length => state.length;
}

final queueProvider =
    StateNotifierProvider<QueueNotifier, List<QueueItem>>(
        (_) => QueueNotifier());
