import 'package:flutter/material.dart';
import 'package:colitu_vpn/core/db/database/constants.dart';
import 'package:colitu_vpn/core/db/database/database.dart';
import 'package:colitu_vpn/core/db/database/enum.dart';
import 'package:colitu_vpn/l10n/localizations/app_localizations.dart';

extension ConfigReader on CoreConfigData {
  List<String> readTags(BuildContext context) {
    final tags = <String>[];
    final type = CoreConfigType.fromString(this.type);
    if (type != null) {
      switch (type) {
        case CoreConfigType.outbound:
          tags.add(_readOutboundTags());
          break;
        default:
          break;
      }
    }
    final delay = _readDelayTag(context);
    if (delay.isNotEmpty) {
      tags.add(delay);
    }

    return tags;
  }

  String _readOutboundTags() {
    return tags.replaceAll(",", " | ");
  }

  String _readDelayTag(BuildContext context) {
    switch (delay) {
      case PingDelayConstants.unknown:
        return "";
      case PingDelayConstants.error:
        return AppLocalizations.of(context)!.pingError;
      case PingDelayConstants.timeout:
        return AppLocalizations.of(context)!.pingTimeout;
      default:
        return "${delay}ms";
    }
  }
}
