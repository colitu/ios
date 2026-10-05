import 'package:flutter/material.dart';
import 'package:colitu_vpn/l10n/localizations/app_localizations.dart';
import 'package:colitu_vpn/pages/global/constants.dart';
import 'package:colitu_vpn/pages/home/xray/setting/outbound_black_hole/controller.dart';
import 'package:colitu_vpn/pages/widget/section.dart';
import 'package:colitu_vpn/pages/widget/text_row.dart';

class OutboundBlackHolePage extends StatelessWidget {
  const OutboundBlackHolePage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = OutboundBlackHoleController();
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.outboundBlackHolePageTitle),
      ),
      body: SafeArea(child: _body(context, controller)),
    );
  }

  Widget _body(BuildContext context, OutboundBlackHoleController controller) {
    return DefaultTextStyle.merge(
      style: const TextStyle(fontSize: GlobalConstants.bodyFontSize),
      child: SingleChildScrollView(child: _section(context, controller)),
    );
  }

  Widget _section(
    BuildContext context,
    OutboundBlackHoleController controller,
  ) {
    return SectionView(
      title: "",
      child: Column(
        children: [
          TextRow(
            title: AppLocalizations.of(context)!.outboundBlackHolePageProtocol,
            detail: controller.blackHoleState.protocol.name,
          ),
          TextRow(
            title: AppLocalizations.of(context)!.outboundBlackHolePageTag,
            detail: controller.blackHoleState.tag.name,
          ),
        ],
      ),
    );
  }
}
