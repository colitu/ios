import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:colitu_vpn/core/tools/json.dart';
import 'package:colitu_vpn/l10n/localizations/app_localizations.dart';
import 'package:colitu_vpn/pages/home/xray/raw_edit/params.dart';
import 'package:colitu_vpn/pages/mixin/alert.dart';

class XrayRawEditController {
  final XrayRawEditParams params;
  XrayRawEditController(this.params) {
    _initParams();
  }

  final controller = TextEditingController();

  void dispose() {
    controller.dispose();
  }

  void _initParams() {
    controller.text = params.text;
  }

  Future<void> save(BuildContext context) async {
    final rawText = controller.text.trim();
    try {
      JsonTool.decoder.convert(rawText);
    } catch (_) {
      ContextAlert.showToast(
        context,
        AppLocalizations.of(context)!.validationJsonInvalid,
      );
      return;
    }
    if (context.mounted) {
      context.pop(rawText);
    }
  }
}
