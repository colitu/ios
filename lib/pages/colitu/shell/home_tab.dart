import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:colitu_vpn/colitu/api/models/multihop_models.dart';
import 'package:colitu_vpn/colitu/api/models/user_models.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/config/colitu_clock.dart';
import 'package:colitu_vpn/colitu/services/colitu_split_tunnel.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/colitu/theme/particles.dart';
import 'package:colitu_vpn/pages/colitu/shell/notice_banner.dart';
import 'package:colitu_vpn/pages/colitu/shell/page.dart';

/// Connection screen, kept to one screen above the tab bar: the particle
/// power button (its state says connected or not), live speed tiles, the
/// location card and a one-row plan card.
class HomeTab extends StatelessWidget {
  const HomeTab({
    super.key,
    required this.controller,
    required this.onToggle,
    required this.onChangeLocation,
    required this.onOpenPlan,
    this.onOpenPrivacy,
    this.onOpenSplitTunnel,
    this.onOpenSettings,
  });

  final ColituConnectionController controller;
  final Future<void> Function() onToggle;
  final VoidCallback onChangeLocation;
  final VoidCallback onOpenPlan;

  /// Opens the privacy mode setting (the "Russian sites outside VPN" chip).
  final VoidCallback? onOpenPrivacy;

  /// Opens the split-tunneling setting (the "Split tunneling on" chip).
  final VoidCallback? onOpenSplitTunnel;

  /// Opens the settings (Simple mode's "Advanced settings on" line).
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final c = controller;
    if (c.loading && c.servers.isEmpty) {
      return const Center(child: ColituSpinner());
    }
    final on = c.connected;
    final connecting = c.status == ColituVpnStatus.connecting;
    final disconnecting = c.status == ColituVpnStatus.disconnecting;
    final planRequired = c.planRequired && !on;

    final hint = on
        ? loc['home.tapOff']
        : connecting
        ? _phaseText(loc, c.phase)
        : disconnecting
        ? loc['status.disconnecting']
        : planRequired
        ? loc['home.sub.noplan']
        : loc['home.tap'];

    return ShellScroll(
      onRefresh: () => c.load(showLoading: false),
      children: [
        const NoticeBanner(),
        const SizedBox(height: 4),
        Center(
          child: ColituPowerButton(
            state: on
                ? ColituPowerState.on
                : c.busy
                ? ColituPowerState.busy
                : ColituPowerState.off,
            size: 280,
            onTap: disconnecting ? null : onToggle,
            semanticsLabel: on ? loc['home.disconnect'] : loc['home.connect'],
            child: on ? _Clock(seconds: c.connectedSeconds) : null,
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: Padding(
            key: ValueKey(hint),
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              hint,
              textAlign: TextAlign.center,
              style: ColituText.muted.copyWith(
                color: connecting ? ColituColors.lilac : ColituColors.muted,
              ),
            ),
          ),
        ),
        // Simple mode: button, status, location, plan and notices only.
        if (on && c.transport != null && c.advancedMode) ...[
          const SizedBox(height: 8),
          Center(
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                ColituBadge(
                  '${loc['home.protocol']} · ${c.transportName}',
                  tone: ColituBadgeTone.neutral,
                ),
                if (c.verifiedPublicIp != null)
                  ColituBadge('IP · ${c.verifiedPublicIp}', tone: ColituBadgeTone.neutral),
              ],
            ),
          ),
        ],
        if (on && routeChipText(c) != null && c.advancedMode) ...[
          const SizedBox(height: 8),
          Center(
            child: ColituStatusChip(
              key: const ValueKey('routeChip'),
              text: routeChipText(c)!,
              color: ColituColors.lilac,
            ),
          ),
        ],
        if (c.ruDirectActive && c.advancedMode) ...[
          const SizedBox(height: 8),
          Center(
            child: Semantics(
              button: true,
              child: ColituPressable(
                key: const ValueKey('ruDirectChip'),
                onTap: onOpenPrivacy,
                child: ColituStatusChip(
                  text: loc['privacy.chip'],
                  color: ColituColors.warning,
                ),
              ),
            ),
          ),
        ],
        if (c.splitTunnelActive && c.advancedMode) ...[
          const SizedBox(height: 8),
          Center(
            child: Semantics(
              button: true,
              child: ColituPressable(
                key: const ValueKey('splitTunnelChip'),
                onTap: onOpenSplitTunnel,
                child: ColituStatusChip(
                  text: splitTunnelChipText(c.splitTunnel),
                  color: ColituColors.lilac,
                ),
              ),
            ),
          ),
        ],
        if (c.hiddenSettingsActive) ...[
          const SizedBox(height: 8),
          Center(
            child: Semantics(
              button: true,
              child: ColituPressable(
                key: const ValueKey('hiddenSettingsChip'),
                onTap: () {
                  unawaited(c.setAdvancedMode(true));
                  onOpenSettings?.call();
                },
                child: ColituStatusChip(
                  text: loc['mode.hiddenActive'],
                  color: ColituColors.lilac,
                ),
              ),
            ),
          ),
        ],
        if (c.advancedMode) ...[
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                icon: CupertinoIcons.arrow_up,
                label: loc['home.upload'],
                value: _speed(on ? c.uploadBps : 0),
                active: on,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatTile(
                icon: CupertinoIcons.arrow_down,
                label: loc['home.download'],
                value: _speed(on ? c.downloadBps : 0),
                active: on,
              ),
            ),
          ],
        ),
        ],
        if (c.trialBanner != null) ...[
          const SizedBox(height: 12),
          ColituNotice(
            key: const ValueKey('trialBanner'),
            trialBannerText(c.trialBanner!),
            error: false,
            action: Wrap(
              spacing: 16,
              children: [
                ColituLinkButton(label: loc['plan.upgrade'], onPressed: onOpenPlan),
                ColituLinkButton(
                  label: loc['trial.dismiss'],
                  onPressed: () => unawaited(c.dismissTrialBanner()),
                  color: ColituColors.muted,
                ),
              ],
            ),
          ),
        ],
        if (c.error != null) ...[
          const SizedBox(height: 12),
          ColituNotice(
            c.error!,
            action: c.offerFastest
                ? ColituLinkButton(
                    key: const ValueKey('tryFastest'),
                    label: loc['err.tryFastest'],
                    onPressed: () => unawaited(c.tryFastest()),
                  )
                : null,
          ),
        ],
        if (c.dropReport != null) ...[
          const SizedBox(height: 12),
          ColituNotice(
            c.dropReport!,
            error: false,
            action: ColituLinkButton(
              label: loc['drop.dismiss'],
              onPressed: c.clearDropReport,
            ),
          ),
        ],
        if (c.suggestedServer != null) ...[
          const SizedBox(height: 12),
          ColituNotice(
            loc.format('server.problem', {
              'server': c.serverLabel(c.suggestedServer),
            }),
            action: ColituLinkButton(
              label: loc['server.switch'],
              onPressed: () => unawaited(c.switchToSuggested()),
            ),
          ),
        ],
        if (c.offline) ...[
          const SizedBox(height: 12),
          ColituNotice(loc['home.offline'], error: false),
        ],
        const SizedBox(height: 12),
        _LocationCard(controller: c, onChange: onChangeLocation),
        const SizedBox(height: 12),
        _PlanCard(controller: c, onOpenPlan: onOpenPlan),
        if (!c.advancedMode) ...[
          const SizedBox(height: 6),
          Center(
            child: ColituLinkButton(
              key: const ValueKey('advancedModeButton'),
              label: loc['mode.advanced'],
              icon: CupertinoIcons.slider_horizontal_3,
              color: ColituColors.muted,
              onPressed: () {
                unawaited(c.setAdvancedMode(true));
                showColituToast(context, loc['mode.advancedOn']);
              },
            ),
          ),
        ],
      ],
    );
  }

  String _phaseText(ColituLoc loc, ColituConnectPhase phase) => switch (phase) {
    ColituConnectPhase.preparing => loc['home.phase.preparing'],
    ColituConnectPhase.probing => loc['home.phase.probing'],
    ColituConnectPhase.starting => loc['home.phase.starting'],
    ColituConnectPhase.verifying => loc['home.phase.verifying'],
    ColituConnectPhase.switching => loc['home.phase.switching'],
    ColituConnectPhase.switchingServer => loc['home.phase.switchingServer'],
    ColituConnectPhase.idle => loc['home.sub.connecting'],
  };

  static String _speed(double bps) {
    final loc = ColituLoc.I;
    final units = loc.language == 'ru'
        ? const ['Б/с', 'КБ/с', 'МБ/с', 'ГБ/с']
        : const ['B/s', 'KB/s', 'MB/s', 'GB/s'];
    var value = bps;
    var unit = 0;
    while (value >= 1000 && unit < units.length - 1) {
      value /= 1000;
      unit++;
    }
    final text = unit == 0
        ? value.toStringAsFixed(0)
        : value >= 100
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
    return '${loc.language == 'en' ? text : text.replaceFirst('.', ',')} ${units[unit]}';
  }
}

/// Session clock inside the power button.
class _Clock extends StatelessWidget {
  const _Clock({required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return Text(
      '${two(h)}:${two(m)}:${two(s)}',
      key: const ValueKey('clock'),
      style: ColituText.h2.copyWith(
        color: Colors.white,
        fontSize: 24,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.active,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final parts = value.split(' ');
    return ColituPanel(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      radius: ColituRadius.md,
      child: Row(
        children: [
          ColituRoundIcon(icon, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: ColituText.small),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      parts.first,
                      style: ColituText.h2.copyWith(
                        fontSize: 20,
                        color: active ? ColituColors.text : ColituColors.muted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      parts.length > 1 ? parts.last : '',
                      style: ColituText.small.copyWith(fontSize: 11.5),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Entry FI → Exit DE" on a multihop route; with a rotating exit IP the
/// current exit and the time to the next change. Null for a plain tunnel.
String? routeChipText(ColituConnectionController c) {
  final loc = ColituLoc.I;
  final server = c.connectedServer;
  if (!c.connected || server == null) return null;
  if (server.isMultihop) {
    return loc.format('multihop.home', {
      'entry': server.entry?.short ?? '?',
      'exit': server.exit?.short ?? '?',
    });
  }
  final line = c.rotationLine;
  if (line == null) return null;
  final left = line.left;
  if (left == null) return loc.format('rotation.homeNow', {'exit': line.exit});
  return left > Duration.zero
      ? loc.format('rotation.home', {
          'exit': line.exit,
          'time': ColituRotation.formatCountdown(left),
        })
      : loc.format('rotation.homeDue', {'exit': line.exit});
}

class _LocationCard extends StatelessWidget {
  const _LocationCard({required this.controller, required this.onChange});

  final ColituConnectionController controller;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final c = controller;
    final server = c.connected
        ? (c.connectedServer ?? c.effectiveServer)
        : c.effectiveServer;
    final auto = c.automaticTarget;
    final title = auto ? loc['home.fastest'] : c.serverLabel(server);
    final subtitle = auto
        ? (server == null
            ? loc['home.autoPicked']
            : '${loc['home.autoPicked']} · ${c.serverLabel(server)}')
        : server != null && server.isMultihop
        ? loc.format('multihop.sub', {
            'entry': server.entry?.short ?? '?',
            'exit': server.exit?.short ?? '?',
          })
        : (server?.countryCode ?? '');
    return ColituPanel(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      radius: ColituRadius.md,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (auto)
                const ColituRoundIcon(CupertinoIcons.bolt_fill, size: 44, accent: true)
              else
                ColituFlag(server?.countryCode ?? '', size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: ColituText.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: ColituText.small,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                c.connected ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.info_circle,
                size: 18,
                color: c.connected ? ColituColors.success : ColituColors.dim,
              ),
            ],
          ),
          const SizedBox(height: 12),
          ColituButton(label: loc['home.changeServer'], onPressed: onChange, height: 46),
        ],
      ),
    );
  }
}

/// One-row plan summary: name, expiry (or "no expiry") and traffic, with a
/// button to the plan tab. A status badge appears only when something is
/// wrong (expired or no plan); an active plan needs no label.
class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.controller, required this.onOpenPlan});

  final ColituConnectionController controller;
  final VoidCallback onOpenPlan;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final user = controller.user;
    final status = planStatusOf(user);
    final active = status == 'active' || status == 'trialing';
    final expires = user?.expiresAt;
    final quota = user?.freeQuota;
    final hasQuota = quota != null && quota.limitBytes > 0;
    final detail = !active
        ? loc['plan.noneHint']
        : isFreePlan(user)
        ? loc['plan.freeHint']
        : [
            if (expires != null) planLeftOf(expires),
            if (!hasQuota) loc['home.unlimited'],
          ].join(' · ');
    return ColituPanel(
      onTap: onOpenPlan,
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      radius: ColituRadius.md,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ColituRoundIcon(
                active ? CupertinoIcons.star_fill : CupertinoIcons.star,
                size: 40,
                accent: active,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            planNameOf(user),
                            style: ColituText.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (!active) ...[
                          const SizedBox(width: 8),
                          ColituBadge(loc['plan.status.$status'], tone: ColituBadgeTone.danger),
                        ],
                      ],
                    ),
                    if (detail.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: ColituText.small,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ColituButton.secondary(
                label: loc['plan.manage'],
                onPressed: onOpenPlan,
                expand: false,
                height: 36,
              ),
            ],
          ),
          if (hasQuota) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(ColituRadius.pill),
              child: LinearProgressIndicator(
                value: quota.usedRatio,
                minHeight: 5,
                backgroundColor: ColituColors.glass10,
                valueColor: const AlwaysStoppedAnimation(ColituColors.lilac),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              '${loc['home.traffic']}: ${loc.format('home.trafficOf', {
                'used': loc.bytes(quota.usedBytes),
                'limit': loc.bytes(quota.limitBytes),
              })}',
              style: ColituText.small,
            ),
          ],
        ],
      ),
    );
  }
}

// ── Plan helpers shared by the home, plan and account tabs ─────────────────

String planStatusOf(ColituUser? user) {
  final raw = (user?.subscriptionStatus ?? '').toLowerCase();
  final status = switch (raw) {
    'active' => 'active',
    'trialing' || 'trial_active' => 'trialing',
    'expired' => 'expired',
    // The free plan's 10 GB are used up until the next month.
    'quota_exceeded' => 'quota',
    _ => 'inactive',
  };
  final expires = user?.expiresAt;
  if ((status == 'active' || status == 'trialing') &&
      expires != null &&
      expires.isBefore(ColituClock.now())) {
    return 'expired';
  }
  return status;
}

String planNameOf(ColituUser? user) {
  final loc = ColituLoc.I;
  final status = planStatusOf(user);
  if (status == 'inactive') return loc['plan.none'];
  if (status == 'trialing') return loc['plan.trialName'];
  if (isFreePlan(user)) return loc['plan.freeName'];
  final name = user?.plan?.trim();
  return name == null || name.isEmpty ? 'Colitu VPN' : name;
}

/// The free plan (10 GB a month); its entitlement renews every month.
bool isFreePlan(ColituUser? user) => (user?.plan ?? '').trim().toLowerCase() == 'free';

/// Short form for one-line rows: "211 days left" or "No expiry".
String planLeftOf(DateTime expires) {
  final loc = ColituLoc.I;
  final left = expires.difference(ColituClock.now());
  if (left.inDays > 3650) return loc['plan.lifetime'];
  final leftText = left.inDays >= 1
      ? loc.count('day', left.inDays)
      : loc.count('hour', left.inHours < 1 ? 1 : left.inHours);
  return loc.format('plan.left', {'left': leftText});
}

String planDetailOf(DateTime expires) {
  final loc = ColituLoc.I;
  final left = expires.difference(ColituClock.now());
  if (left.inDays > 3650) return loc['plan.lifetime'];
  final leftText = left.inDays >= 1
      ? loc.count('day', left.inDays)
      : loc.count('hour', left.inHours < 1 ? 1 : left.inHours);
  return '${loc.format('plan.until', {'date': loc.date(expires)})} · ${loc.format('plan.left', {'left': leftText})}';
}

/// "Split tunneling on: 3 sites outside VPN" (or "only 3 use VPN").
String splitTunnelChipText(SplitTunnelSettings settings) {
  final loc = ColituLoc.I;
  final count = loc.count('site', settings.count);
  return settings.mode == SplitTunnelMode.only
      ? loc.format('split.chip.only', {'count': count})
      : loc.format('split.chip.bypass', {'count': count});
}

/// The trial-end banner. Every number comes from the panel; the part about
/// paused devices only appears when the account has more devices than the
/// next plan allows.
String trialBannerText(TrialTransition trial) {
  final loc = ColituLoc.I;
  final left = trial.endsAt.difference(ColituClock.now());
  final days = left.inHours >= 24
      ? loc.count('day', (left.inHours / 24).ceil())
      : loc.count('hour', left.inHours < 1 ? 1 : left.inHours);
  final plan = trial.toFree
      ? loc['trial.toFree']
      : loc.format('trial.toPlan', {'name': trial.nextPlan});
  final limit = trial.nextDeviceLimit;
  final devices = limit == null ? null : loc.count('device', limit);
  final gb = trial.nextMonthlyGb;
  final details = gb != null && devices != null
      ? loc.format('trial.details', {'gb': gb, 'devices': devices})
      : devices ?? (gb == null ? null : '$gb GB');
  final key = trial.pausesDevices ? 'trial.bannerPaused' : 'trial.banner';
  final text = loc.format(key, {
    'days': days,
    'date': loc.date(trial.endsAt),
    'plan': plan,
    'details': details ?? '',
  });
  // Without plan numbers the parentheses would be empty.
  return details == null ? text.replaceAll(' ()', '') : text;
}
