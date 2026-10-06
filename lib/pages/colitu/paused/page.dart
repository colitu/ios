import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_errors.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/shell/page.dart';

/// Shown in place of the home screen while this device is paused: the plan
/// allows fewer devices than are active (`DEVICE_OVER_LIMIT`). Nothing
/// connects from here; the user makes this device the active one or opens
/// the pricing page.
class ColituPausedView extends StatefulWidget {
  const ColituPausedView({super.key, required this.controller});

  final ColituConnectionController controller;

  static final pricingUrl = Uri.parse('https://colitu.com/pricing');

  @override
  State<ColituPausedView> createState() => _ColituPausedViewState();
}

class _ColituPausedViewState extends State<ColituPausedView> {
  var _activating = false;

  Future<void> _useThisDevice() async {
    if (_activating) return;
    setState(() => _activating = true);
    try {
      await widget.controller.activateThisDevice();
      if (mounted && widget.controller.paused == null) {
        showColituToast(context, ColituLoc.I['paused.activated']);
      }
    } catch (e) {
      if (mounted) showColituToast(context, colituErrorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _activating = false);
    }
  }

  Future<void> _premium() async {
    try {
      await launchUrl(ColituPausedView.pricingUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Open pricing failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final pause = widget.controller.paused ?? const DevicePause(deviceLimit: 1);
    return ShellScroll(
      onRefresh: widget.controller.recheckPause,
      children: [
        const SizedBox(height: 24),
        const Center(
          child: ColituRoundIcon(CupertinoIcons.pause_circle, size: 72, accent: true),
        ),
        const SizedBox(height: 18),
        Center(child: ColituKicker(loc['paused.kicker'], color: ColituColors.warning)),
        const SizedBox(height: 10),
        Text(
          loc['paused.title'],
          textAlign: TextAlign.center,
          style: ColituText.display.copyWith(fontSize: 28),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            loc.format('paused.body', {
              'devices': loc.count('device', pause.deviceLimit),
            }),
            textAlign: TextAlign.center,
            style: ColituText.muted,
          ),
        ),
        if (pause.activeDevices.isNotEmpty) ...[
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              loc['paused.active'],
              style: ColituText.label.copyWith(color: ColituColors.muted),
            ),
          ),
          for (final device in pause.activeDevices) ...[
            ColituTile(
              padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
              child: Row(
                children: [
                  const ColituRoundIcon(CupertinoIcons.device_phone_portrait),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          device.name.isEmpty ? loc['paused.device'] : device.name,
                          style: ColituText.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (device.lastSeenAt != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            loc.format('paused.lastSeen', {
                              'date': loc.date(device.lastSeenAt!),
                            }),
                            style: ColituText.small,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
        const SizedBox(height: 18),
        ColituButton(
          key: const ValueKey('pausedUseThis'),
          label: loc['paused.useThis'],
          loading: _activating,
          onPressed: _useThisDevice,
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            loc['paused.useThisHint'],
            textAlign: TextAlign.center,
            style: ColituText.small,
          ),
        ),
        const SizedBox(height: 16),
        ColituButton.secondary(
          key: const ValueKey('pausedPremium'),
          label: loc['paused.premium'],
          icon: CupertinoIcons.arrow_up_right_square,
          onPressed: _premium,
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            loc['paused.premiumHint'],
            textAlign: TextAlign.center,
            style: ColituText.small,
          ),
        ),
      ],
    );
  }
}
