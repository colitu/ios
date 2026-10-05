import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:colitu_vpn/colitu/config/app_environment.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/colitu/theme/particles.dart';
import 'package:colitu_vpn/pages/colitu/shell/home_tab.dart';
import 'package:colitu_vpn/pages/colitu/shell/page.dart';

/// Plan page. Nothing is bought in the app: the subscription is managed in
/// the customer account on app.colitu.com. The page shows the current plan,
/// says where it is managed, opens the account and refreshes the status.
class PlanTab extends StatefulWidget {
  const PlanTab({super.key, required this.controller});

  final ColituConnectionController controller;

  @override
  State<PlanTab> createState() => _PlanTabState();
}

class _PlanTabState extends State<PlanTab> {
  var _refreshing = false;

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.controller.load(showLoading: false);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _openAccount() async {
    final uri = Uri.parse(AppEnvironment.accountUrl);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Open url failed: $uri $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final user = widget.controller.user;
    final status = planStatusOf(user);
    final active = status == 'active' || status == 'trialing';
    final expires = user?.expiresAt;

    return ShellScroll(
      onRefresh: _refresh,
      children: [
        const _Hero(),
        const SizedBox(height: 16),
        ColituPanel(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          radius: ColituRadius.md,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ColituKicker(loc['pricing.current']),
                    const SizedBox(height: 6),
                    Text(planNameOf(user), style: ColituText.h2),
                    const SizedBox(height: 3),
                    Text(
                      isFreePlan(user)
                          ? loc['plan.freeHint']
                          : active && expires != null
                          ? planDetailOf(expires)
                          : loc['plan.noneHint'],
                      style: ColituText.small,
                    ),
                  ],
                ),
              ),
              if (!active) ...[
                const SizedBox(width: 8),
                ColituBadge(loc['plan.status.$status'], tone: ColituBadgeTone.danger),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        ColituPanel(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          radius: ColituRadius.md,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const ColituRoundIcon(CupertinoIcons.globe, size: 40, accent: true),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(loc['plan.manageTitle'], style: ColituText.label),
                        const SizedBox(height: 4),
                        Text(loc['plan.manageBody'], style: ColituText.small),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ColituButton(
                label: loc['plan.manageButton'],
                icon: CupertinoIcons.arrow_up_right_square,
                onPressed: _openAccount,
              ),
              const SizedBox(height: 10),
              ColituButton.secondary(
                label: loc['plan.refresh'],
                loading: _refreshing,
                onPressed: _refresh,
              ),
              const SizedBox(height: 10),
              Text(loc['plan.refreshHint'], textAlign: TextAlign.center, style: ColituText.small),
            ],
          ),
        ),
      ],
    );
  }
}

/// Rotating gem with the headline.
class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    return Column(
      children: [
        const ColituParticles(mode: ColituParticleMode.gem, size: 120, energy: 0.6),
        Text(
          loc['plan.heroTitle'],
          textAlign: TextAlign.center,
          style: ColituText.display.copyWith(fontSize: 28),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(loc['plan.heroSub'], textAlign: TextAlign.center, style: ColituText.muted),
        ),
      ],
    );
  }
}
