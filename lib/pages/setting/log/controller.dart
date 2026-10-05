import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:colitu_vpn/core/tools/file.dart';
import 'package:colitu_vpn/l10n/localizations/app_localizations.dart';
import 'package:colitu_vpn/pages/main/url.dart';
import 'package:colitu_vpn/pages/setting/long_text/params.dart';
import 'package:colitu_vpn/pages/widget/menu_picker.dart';
import 'package:colitu_vpn/service/xray/constants.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

class LogController {
  static final instance = LogController();

  void moreAction(BuildContext context, String path, String menuId) {
    final id = IconMenuId.fromString(menuId);
    if (id == null) {
      return;
    }
    switch (id) {
      case IconMenuId.share:
        _shareFile(context, path);
        break;
      case IconMenuId.save:
        _saveFile(context, path);
        break;
      default:
        break;
    }
  }

  Future<void> _shareFile(BuildContext context, String path) async {
    Rect? sharePositionOrigin;
    if (context.mounted) {
      final box = context.findRenderObject() as RenderBox?;
      if (box != null) {
        sharePositionOrigin = box.localToGlobal(Offset.zero) & box.size;
      }
    }
    final params = ShareParams(
      files: [XFile(path)],
      fileNameOverrides: [p.basename(path)],
      sharePositionOrigin: sharePositionOrigin,
    );
    await SharePlus.instance.share(params);
  }

  Future<void> _saveFile(BuildContext context, String path) async {
    await FileTool.saveFile(path, p.basename(path), ".txt");
  }

  void gotoXrayConfigFile(BuildContext context) {
    final params = LongTextParams(
      AppLocalizations.of(context)!.logPageXrayConfig,
      XrayStateConstants.configFilePath,
    );
    context.push(RouterPath.longText, extra: params);
  }
}
