import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:video_caster_app/providers/privacy_telemetry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TelemetryNotifier', () {
    test('logs events when telemetry is enabled', () async {
      SharedPreferences.setMockInitialValues({
        kTelemetryEnabledKey: true,
      });

      final notifier = TelemetryNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 1));

      await notifier.log('event_a', payload: {'k': 'v'});

      expect(notifier.state, hasLength(1));
      expect(notifier.state.first.name, 'event_a');
      expect(notifier.state.first.payload['k'], 'v');
    });

    test('does not log events when telemetry is disabled', () async {
      SharedPreferences.setMockInitialValues({
        kTelemetryEnabledKey: false,
      });

      final notifier = TelemetryNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 1));

      await notifier.log('event_b');

      expect(notifier.state, isEmpty);
    });
  });
}
