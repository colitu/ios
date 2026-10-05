import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:colitu_vpn/service/subscription/service.dart';

class BackgroundTaskService with WidgetsBindingObserver {
  static final BackgroundTaskService _singleton =
      BackgroundTaskService._internal();

  factory BackgroundTaskService() => _singleton;

  BackgroundTaskService._internal();

  //==========================
  Timer? _subscriptionTimer;

  Future<void> asyncInit() async {
    WidgetsBinding.instance.addObserver(this);
    final interval = const Duration(hours: 1);
    _subscriptionTimer = Timer.periodic(
      interval,
      (_) => checkSubscriptionUpdate(),
    );
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscriptionTimer?.cancel();
    _subscriptionTimer = null;
  }

  Future<void> checkSubscriptionUpdate() async {
    await SubscriptionService().refreshOutdatedSubscription();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(checkSubscriptionUpdate());
    }
  }
}
