import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:colitu_vpn/colitu/config/app_environment.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/l10n/localizations/app_localizations.dart';
import 'package:colitu_vpn/pages/main/url.dart';
import 'package:colitu_vpn/service/event_bus/service.dart';
import 'package:colitu_vpn/service/event_bus/state.dart';

class GoRouteApp extends StatelessWidget {
  const GoRouteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => AppEventBus(),
      child: BlocBuilder<AppEventBus, AppEventBusState>(
        builder: (context, state) => ListenableBuilder(
          // Switching the app language rebuilds every page.
          listenable: ColituLoc.I,
          builder: (context, _) => _buildApp(context, state),
        ),
      ),
    );
  }

  Widget _buildApp(BuildContext context, AppEventBusState state) {
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: AppEnvironment.appName,
      themeMode: ThemeMode.dark,
      theme: ColituTheme.dark,
      darkTheme: ColituTheme.dark,
      scrollBehavior: const _ColituScrollBehavior(),
      routerConfig: RouterPath.router,
      // Material/Cupertino widgets follow the Colitu language; the legacy
      // generated strings only exist in English.
      locale: Locale(ColituLoc.I.language),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: const [Locale('en'), Locale('ru'), Locale('tr')],
      localeResolutionCallback: (_, _) => Locale(ColituLoc.I.language),
      builder: (_, child) => child ?? const SizedBox.shrink(),
    );
  }
}

class _ColituScrollBehavior extends MaterialScrollBehavior {
  const _ColituScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
