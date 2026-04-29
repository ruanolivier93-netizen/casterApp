import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/native_cast_service.dart';

class NativeCastNotifier extends StateNotifier<NativeCastState> {
  NativeCastNotifier() : super(NativeCastState.empty) {
    _init();
  }

  StreamSubscription<NativeCastState>? _subscription;

  Future<void> _init() async {
    state = await NativeCastService.getState();
    _subscription = NativeCastService.stateStream.listen((next) {
      state = next;
    });
  }

  Future<void> showDialog() => NativeCastService.showCastDialog();

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

final nativeCastProvider =
    StateNotifierProvider<NativeCastNotifier, NativeCastState>(
  (_) => NativeCastNotifier(),
);