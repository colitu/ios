import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:colitu_vpn/colitu/api/models/multihop_models.dart';
import 'package:colitu_vpn/colitu/api/models/user_models.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/config/colitu_clock.dart';
import 'package:colitu_vpn/colitu/l10n/server_names.dart';
import 'package:colitu_vpn/colitu/services/colitu_ad_block.dart';
import 'package:colitu_vpn/colitu/services/server_groups.dart';
import 'package:colitu_vpn/colitu/services/server_shortcuts.dart';
import 'package:colitu_vpn/colitu/services/colitu_split_tunnel.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/colitu/theme/particles.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_art.dart';
import 'package:colitu_vpn/pages/colitu/shell/invite_card.dart';
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
    this.onOpenPassport,
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

  /// Opens Colitu Passport (the passport card).
  final VoidCallback? onOpenPassport;

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
        _QuickServers(controller: c),
        const SizedBox(height: 12),
        _PlanCard(controller: c, onOpenPlan: onOpenPlan),
        const SizedBox(height: 12),
        _QuickSettings(
          controller: c,
          onOpenSplitTunnel: onOpenSplitTunnel,
        ),
        if (onOpenPassport != null && c.paused == null) ...[
          const SizedBox(height: 12),
          PassportCard(premium: c.planActive, onOpen: onOpenPassport!),
        ],
        if (c.paused == null) ColituHomeInviteCard(connected: on),
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
    // The whole card opens the locations; one label for screen readers.
    return Semantics(
      key: const ValueKey('locationCard'),
      button: true,
      label: loc.format('home.serverCard', {
        'server': subtitle.isEmpty ? title : '$title, $subtitle',
      }),
      excludeSemantics: true,
      onTap: onChange,
      child: ColituPanel(
        onTap: onChange,
        padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
        radius: ColituRadius.md,
        child: Row(
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
                  // Large text wraps to a second line before it is cut.
                  Text(
                    title,
                    style: ColituText.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: ColituText.small,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (c.connected) ...[
              const Icon(
                CupertinoIcons.checkmark_circle_fill,
                size: 18,
                color: ColituColors.success,
              ),
              const SizedBox(width: 8),
            ],
            const Icon(
              CupertinoIcons.chevron_right,
              size: 18,
              color: ColituColors.muted,
            ),
          ],
        ),
      ),
    );
  }
}

/// Up to three small buttons under the location card: favourites first,
/// then the last servers used. One tap switches to that server. Hidden while
/// the lists are empty.
class _QuickServers extends StatelessWidget {
  const _QuickServers({required this.controller});

  final ColituConnectionController controller;

  @override
  Widget build(BuildContext context) {
    final shortcuts = ColituServerShortcuts.instance;
    return ListenableBuilder(
      listenable: shortcuts,
      builder: (context, _) {
        final c = controller;
        final buttons = shortcuts.homeButtons(
          [...c.servers, ...c.multihopServers],
          except: c.autoSelection ? null : c.selectedServer?.selectionKey,
        );
        if (buttons.isEmpty) return const SizedBox.shrink();
        return Padding(
          key: const ValueKey('quickServers'),
          padding: const EdgeInsets.only(top: 10),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final server in buttons)
                _QuickServerButton(
                  server: server,
                  label: server.isMultihop
                      ? ColituServerNames.route(server.name)
                      : serverCityLabel(server),
                  onTap: () => unawaited(c.selectServer(server)),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _QuickServerButton extends StatelessWidget {
  const _QuickServerButton({
    required this.server,
    required this.label,
    required this.onTap,
  });

  final VPNServer server;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final code = server.isMultihop
        ? (server.exit?.country ?? '')
        : server.countryCode;
    return Semantics(
      button: true,
      label: ColituLoc.I.format('home.quickSwitch', {'server': label}),
      excludeSemantics: true,
      onTap: onTap,
      child: ColituPressable(
        key: ValueKey('quickServer.${server.selectionKey}'),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44, maxWidth: 220),
          padding: const EdgeInsets.fromLTRB(8, 6, 14, 6),
          decoration: BoxDecoration(
            color: ColituColors.surface,
            borderRadius: BorderRadius.circular(ColituRadius.pill),
            border: Border.all(color: ColituColors.lineStrong),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ColituFlag(code, size: 24),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  style: ColituText.label.copyWith(fontSize: 13.5),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The connection switches of the account tab in one small card; each row
/// calls the same controller method as its account-tab twin. Rows follow the
/// account tab's mode: Simple mode keeps only always-on protection.
class _QuickSettings extends StatelessWidget {
  const _QuickSettings({required this.controller, this.onOpenSplitTunnel});

  final ColituConnectionController controller;
  final VoidCallback? onOpenSplitTunnel;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final c = controller;
    return ColituPanel(
      key: const ValueKey('quickSettings'),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
      radius: ColituRadius.md,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 4),
            child: Text(
              loc['home.quickSettings'],
              style: ColituText.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _QuickSwitch(
            key: const ValueKey('quick.alwaysOn'),
            icon: CupertinoIcons.shield_lefthalf_fill,
            title: loc['settings.alwaysOn'],
            value: c.alwaysOn,
            onChanged: c.setAlwaysOn,
          ),
          if (c.advancedMode) ...[
            if (ColituAdBlock.available)
              _QuickSwitch(
                key: const ValueKey('quick.adBlock'),
                icon: CupertinoIcons.eye_slash_fill,
                title: loc['settings.adBlock'],
                value: c.adBlock,
                onChanged: c.setAdBlock,
              ),
            _QuickSwitch(
              key: const ValueKey('quick.killSwitch'),
              icon: CupertinoIcons.nosign,
              title: loc['killSwitch.title'],
              value: c.strictKillSwitch,
              onChanged: c.setStrictKillSwitch,
            ),
            if (onOpenSplitTunnel != null)
              _QuickRow(
                key: const ValueKey('quick.splitTunnel'),
                icon: CupertinoIcons.arrow_branch,
                title: loc['split.title'],
                value: c.splitTunnel.active
                    ? splitTunnelChipText(c.splitTunnel)
                    : null,
                onTap: onOpenSplitTunnel!,
              ),
          ],
        ],
      ),
    );
  }
}

class _QuickSwitch extends StatelessWidget {
  const _QuickSwitch({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: ColituPressable(
      onTap: () => onChanged(!value),
      scale: 0.99,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Icon(icon, size: 18, color: ColituColors.lilac),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: ColituText.body.copyWith(fontSize: 14.5),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            CupertinoSwitch(
              value: value,
              onChanged: onChanged,
              activeTrackColor: ColituColors.violet,
            ),
          ],
        ),
      ),
    ),
  );
}

class _QuickRow extends StatelessWidget {
  const _QuickRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.value,
  });

  final IconData icon;
  final String title;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: value == null ? title : '$title, $value',
    excludeSemantics: true,
    onTap: onTap,
    child: ColituPressable(
      onTap: onTap,
      scale: 0.99,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Icon(icon, size: 18, color: ColituColors.lilac),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: ColituText.body.copyWith(fontSize: 14.5),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (value != null)
                    Text(
                      value!,
                      style: ColituText.small,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(
                CupertinoIcons.chevron_right,
                size: 16,
                color: ColituColors.muted,
              ),
            ),
          ],
        ),
      ),
    ),
  );
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
    final free = isFreePlan(user);
    final freeState = freeQuotaStateOf(user);
    final usedUp = free && freeState == FreeQuotaState.usedUp;
    final near = free && freeState == FreeQuotaState.near;
    final detail = free
        ? freePlanDetailOf(user)
        : !active
        ? loc['plan.noneHint']
        : [
            if (expires != null) planLeftOf(expires),
            if (!hasQuota) loc['home.unlimited'],
          ].join(' · ');
    final barColor = usedUp
        ? ColituColors.danger
        : near
        ? ColituColors.warning
        : ColituColors.lilac;
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
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (usedUp) ...[
                          const SizedBox(width: 8),
                          ColituBadge(loc['plan.status.quota'], tone: ColituBadgeTone.danger),
                        ] else if (!active) ...[
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
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              // The free plan has the wide "Go Premium" button below.
              if (!free) ...[
                const SizedBox(width: 8),
                ColituButton.secondary(
                  label: loc['plan.manage'],
                  onPressed: onOpenPlan,
                  expand: false,
                  height: 36,
                ),
              ],
            ],
          ),
          if (hasQuota) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(ColituRadius.pill),
              child: LinearProgressIndicator(
                value: usedUp ? 1 : quota.usedRatio,
                minHeight: 5,
                backgroundColor: ColituColors.glass10,
                valueColor: AlwaysStoppedAnimation(barColor),
              ),
            ),
            // The free plan's line above already says what is left.
            if (!free) ...[
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
          // Free plan close to or at its monthly allowance: say so plainly,
          // name what Premium adds and point to the plan page in the app
          // (no prices or purchase links here).
          if (near || usedUp) ...[
            const SizedBox(height: 10),
            Text(
              freeQuotaNoticeOf(user),
              key: const ValueKey('freeQuotaNotice'),
              style: ColituText.small.copyWith(
                color: usedUp ? ColituColors.danger : ColituColors.warning,
              ),
            ),
            const SizedBox(height: 4),
            Text(loc['plan.premiumPitch'], style: ColituText.small),
          ],
          // Free plan: straight to the plan tab in the app (no prices or
          // purchase links here).
          if (free) ...[
            const SizedBox(height: 10),
            ColituButton(
              key: const ValueKey('freeQuotaUpgrade'),
              label: loc['plan.goPremium'],
              onPressed: onOpenPlan,
              height: 44,
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
    // The free plan's monthly allowance is used up until the next month.
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

/// The free plan (1 GB a month); its entitlement renews every month.
bool isFreePlan(ColituUser? user) => (user?.plan ?? '').trim().toLowerCase() == 'free';

/// How close the free plan is to its monthly allowance.
enum FreeQuotaState { normal, near, usedUp }

/// `near` from 80 % of the allowance; `usedUp` when nothing is left or the
/// panel reports the allowance as exhausted.
FreeQuotaState freeQuotaStateOf(ColituUser? user) {
  if (planStatusOf(user) == 'quota') return FreeQuotaState.usedUp;
  final quota = user?.freeQuota;
  if (quota == null || quota.limitBytes <= 0) return FreeQuotaState.normal;
  if (quota.remainingBytes <= 0 || quota.usedBytes >= quota.limitBytes) {
    return FreeQuotaState.usedUp;
  }
  return quota.usedRatio >= 0.8 ? FreeQuotaState.near : FreeQuotaState.normal;
}

/// Free-plan line under the plan name: "800 MB of 1 GB left · 1 device".
String freePlanDetailOf(ColituUser? user) {
  final loc = ColituLoc.I;
  final quota = user?.freeQuota;
  final devices = loc.count('device', user?.deviceLimit ?? 1);
  // Without numbers, or once used up (the notice below says when it renews).
  if (quota == null ||
      quota.limitBytes <= 0 ||
      freeQuotaStateOf(user) == FreeQuotaState.usedUp) {
    return '${loc['plan.freeHint']} · $devices';
  }
  final allowance = loc.format('plan.freeLeft', {
    'left': loc.bytes(quota.remainingBytes),
    'limit': loc.bytes(quota.limitBytes),
  });
  return '$allowance · $devices';
}

/// The warning under the free-plan bar: what is left, or when the next
/// allowance arrives once it is used up.
String freeQuotaNoticeOf(ColituUser? user) {
  final loc = ColituLoc.I;
  final quota = user?.freeQuota;
  final limit = loc.bytes(
    quota != null && quota.limitBytes > 0 ? quota.limitBytes : 1073741824,
  );
  if (freeQuotaStateOf(user) == FreeQuotaState.usedUp) {
    final reset = quota?.resetAt;
    return reset == null
        ? loc.format('plan.freeUsedUpLater', {'limit': limit})
        : loc.format('plan.freeUsedUp', {'limit': limit, 'date': loc.date(reset)});
  }
  return loc.format('plan.freeNear', {'left': loc.bytes(quota?.remainingBytes ?? 0)});
}

/// The expiry date, or "No expiry" when it is more than ten years away.
String planDateOf(DateTime expires) =>
    expires.difference(ColituClock.now()).inDays > 3650
    ? ColituLoc.I['plan.lifetime']
    : ColituLoc.I.date(expires);

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
