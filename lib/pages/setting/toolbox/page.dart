import 'package:colitu_vpn/l10n/localizations/app_localizations.dart';
import 'package:colitu_vpn/pages/global/constants.dart';
import 'package:colitu_vpn/pages/setting/toolbox/controller.dart';
import 'package:colitu_vpn/pages/widget/section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class ToolboxPage extends StatelessWidget {
  const ToolboxPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => ToolboxController(),
      child: BlocBuilder<ToolboxController, ToolboxState>(
        builder: (context, state) {
          final controller = context.read<ToolboxController>();
          return Scaffold(
            appBar: AppBar(
              title: Text(AppLocalizations.of(context)!.toolboxPageTitle),
            ),
            body: SafeArea(child: _body(context, state, controller)),
          );
        },
      ),
    );
  }

  Widget _body(
    BuildContext context,
    ToolboxState state,
    ToolboxController controller,
  ) {
    return DefaultTextStyle.merge(
      style: const TextStyle(fontSize: GlobalConstants.bodyFontSize),
      child: SingleChildScrollView(
        child: Column(children: [_dockIconSection(context, state, controller)]),
      ),
    );
  }

  Widget _dockIconSection(
    BuildContext context,
    ToolboxState state,
    ToolboxController controller,
  ) {
    return SectionView(
      title: "",
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(AppLocalizations.of(context)!.toolboxPageHideDockIcon),
              Switch(
                value: state.hideDockIcon,
                onChanged: (value) => controller.updateHideDockIcon(value),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
