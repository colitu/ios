import 'dart:async';

import 'package:flutter/material.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/launch/init.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  @override
  Widget build(BuildContext context) {
    return const ColituScaffold(
      child: Center(child: ColituWordmark(height: 22)),
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(initRouter(context));
  }
}
