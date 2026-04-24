import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:video_caster_app/providers/bookmarks_history.dart';
import 'package:video_caster_app/providers/privacy_telemetry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BookmarksNotifier', () {
    test('normalizes and deduplicates URLs', () async {
      SharedPreferences.setMockInitialValues({
        kPrivacyBookmarksLimitKey: 500,
      });

      final notifier = BookmarksNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 1));

      await notifier.add('https://example.com/path/', 'A');
      await notifier.add('https://example.com/path#fragment', 'B');

      expect(notifier.state, hasLength(1));
      expect(notifier.state.first.title, 'B');
    });
  });

  group('HistoryNotifier', () {
    test('respects retention limit', () async {
      SharedPreferences.setMockInitialValues({
        kPrivacyHistoryLimitKey: 2,
      });

      final notifier = HistoryNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 1));

      await notifier.add('https://a.com', 'A');
      await notifier.add('https://b.com', 'B');
      await notifier.add('https://c.com', 'C');

      expect(notifier.state, hasLength(2));
      expect(notifier.state.first.url, 'https://c.com');
      expect(notifier.state.last.url, 'https://b.com');
    });
  });
}
