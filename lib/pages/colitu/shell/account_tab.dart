import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:colitu_vpn/colitu/api/models/user_models.dart';
import 'package:colitu_vpn/colitu/config/app_environment.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_errors.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/colitu_ad_block.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/services/email_support_service.dart';
import 'package:colitu_vpn/colitu/services/tunnel_diagnostics_service.dart';
import 'package:colitu_vpn/colitu/services/user_service.dart';
import 'package:colitu_vpn/colitu/storage/secure_token_store.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/link/page.dart';
import 'package:colitu_vpn/pages/colitu/shell/home_tab.dart';
import 'package:colitu_vpn/pages/colitu/shell/page.dart';
import 'package:colitu_vpn/pages/main/url.dart';

/// Account and settings in one place: profile, features (always-on,
/// auto-connect, DNS), connection (protocol, language), devices, general.
class AccountTab extends StatefulWidget {
  const AccountTab({
    super.key,
    required this.controller,
    required this.onOpenPlan,
    required this.onSignOut,
    this.onSessionEnded,
    this.onOpenSupport,
    this.users,
  });

  final ColituConnectionController controller;
  final VoidCallback onOpenPlan;
  final Future<void> Function() onSignOut;

  /// Signs out without asking again (this device was just removed).
  final Future<void> Function()? onSessionEnded;
  final VoidCallback? onOpenSupport;
  final UserService? users;

  @override
  State<AccountTab> createState() => _AccountTabState();
}

class _AccountTabState extends State<AccountTab> {
  late final UserService _users = widget.users ?? UserService();
  List<ColituDevice> _devices = const [];
  var _loadingDevices = true;
  String? _error;
  String _version = '';

  @override
  void initState() {
    super.initState();
    unawaited(_loadDevices());
    PackageInfo.fromPlatform().then((info) {
      if (mounted) {
        setState(() => _version = '${info.version} (${info.buildNumber})');
      }
    });
  }

  Future<void> _loadDevices() async {
    setState(() => _loadingDevices = true);
    try {
      String? currentId;
      try {
        currentId = await SecureTokenStore().readDeviceId();
      } catch (_) {
        // Keychain unavailable (tests, early startup): rely on the API flag.
      }
      final devices = await _users.devices();
      if (!mounted) return;
      setState(() {
        _devices = [
          for (final device in devices)
            device.markCurrent(device.current || device.id == currentId),
        ]..sort((a, b) => a.current == b.current ? 0 : (a.current ? -1 : 1));
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = colituErrorMessage(e));
    } finally {
      if (mounted) setState(() => _loadingDevices = false);
    }
  }

  Future<void> _remove(ColituDevice device) async {
    final loc = ColituLoc.I;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(loc['account.remove']),
        content: Text(loc.format('account.removeConfirm', {'name': device.name})),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(loc['pay.cancel']),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(loc['account.remove']),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _users.disconnectDevice(device.id);
      if (device.current) {
        // Already confirmed: removing this device ends the session; a second
        // "sign out?" dialog left the app half signed out when cancelled.
        await (widget.onSessionEnded ?? widget.onSignOut)();
        return;
      }
      if (!mounted) return;
      showColituToast(context, loc['account.removed']);
      await _loadDevices();
    } catch (e) {
      if (mounted) showColituToast(context, colituErrorMessage(e), error: true);
    }
  }

  /// Scans the QR code on a TV's sign-in screen and approves it.
  Future<void> _linkTv(String email) async {
    final approved = await Navigator.of(context, rootNavigator: true).push<bool>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => ColituLinkScannerPage(email: email)),
    );
    if (approved == true && mounted) {
      showColituToast(context, ColituLoc.I['link.approved']);
      Future.delayed(const Duration(seconds: 6), () {
        if (mounted) _loadDevices();
      });
    }
  }

  Future<void> _open(String path) async {
    final uri = Uri.parse('${AppEnvironment.webBaseUrl}$path');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Open url failed: $uri $e');
    }
  }

  Future<void> _mail() async {
    final opened = await EmailSupportService().openSupportEmail();
    if (!opened && mounted) {
      showColituToast(context, ColituLoc.I['account.mailUnavailable'], error: true);
    }
  }

  Future<void> _shareDiagnostics() async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    try {
      await TunnelDiagnosticsService().share(origin: origin);
    } catch (e) {
      debugPrint('Share diagnostics failed: $e');
      if (mounted) {
        showColituToast(context, ColituLoc.I['account.diagnosticsFailed'], error: true);
      }
    }
  }

  void _howItWorks() {
    try {
      context.push('${RouterPath.colituOnboarding}?replay=1');
    } catch (e) {
      debugPrint('Onboarding replay failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final c = widget.controller;
    final user = c.user;
    final email = user?.email ?? '';
    final status = planStatusOf(user);
    final active = status == 'active' || status == 'trialing';
    final limit = user?.deviceLimit ?? 1;
    return ShellScroll(
      onRefresh: () async {
        await c.load(showLoading: false);
        await _loadDevices();
      },
      children: [
        Text(loc['account.title'], style: ColituText.h1),
        const SizedBox(height: 14),
        // Profile
        ColituPanel(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          radius: ColituRadius.md,
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      gradient: ColituGradients.accent,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      email.isEmpty ? '•' : email.substring(0, 1).toUpperCase(),
                      style: ColituText.h2.copyWith(color: ColituColors.onAccent, fontSize: 20),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          email.isEmpty ? '—' : email,
                          style: ColituText.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isFreePlan(user)
                              ? '${planNameOf(user)} · ${loc['plan.freeHint']}'
                              : active && user?.expiresAt != null
                              ? '${planNameOf(user)} · ${loc.date(user!.expiresAt!)}'
                              : planNameOf(user),
                          style: ColituText.small,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ColituBadge(
                    loc['plan.status.$status'],
                    tone: active ? ColituBadgeTone.accent : ColituBadgeTone.danger,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ColituButton(
                label: isFreePlan(user)
                    ? loc['plan.upgrade']
                    : active
                    ? loc['plan.extend']
                    : loc['plan.choose'],
                onPressed: widget.onOpenPlan,
                height: 44,
              ),
              const SizedBox(height: 4),
              ColituLinkButton(
                label: loc['account.manage'],
                icon: CupertinoIcons.arrow_up_right_square,
                onPressed: () => _open('/account'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // Sign a TV in by scanning the QR code on its sign-in screen.
        ColituActionRow(
          icon: CupertinoIcons.tv,
          title: loc['link.row'],
          hint: loc['link.rowHint'],
          onTap: () => _linkTv(email),
          trailing: const Icon(CupertinoIcons.qrcode_viewfinder, size: 22, color: ColituColors.lilac),
        ),
        const SizedBox(height: 18),
        // Features
        _SectionTitle(loc['account.features']),
        ColituSwitchRow(
          icon: CupertinoIcons.shield_lefthalf_fill,
          title: loc['settings.alwaysOn'],
          hint: loc['settings.alwaysOnHint'],
          value: c.alwaysOn,
          onChanged: c.setAlwaysOn,
        ),
        const SizedBox(height: 8),
        ColituSwitchRow(
          icon: CupertinoIcons.bolt_fill,
          title: loc['settings.autoConnect'],
          hint: loc['settings.autoConnectHint'],
          value: c.autoConnect,
          onChanged: c.setAutoConnect,
        ),
        if (ColituAdBlock.available) ...[
          const SizedBox(height: 8),
          ColituSwitchRow(
            icon: CupertinoIcons.eye_slash_fill,
            title: loc['settings.adBlock'],
            hint: loc['settings.adBlockHint'],
            value: c.adBlock,
            onChanged: c.setAdBlock,
          ),
        ],
        const SizedBox(height: 8),
        ColituSwitchRow(
          icon: CupertinoIcons.lock_shield_fill,
          title: loc['settings.dns'],
          hint: loc['settings.dnsHint'],
          value: true,
          trailing: const Icon(
            CupertinoIcons.checkmark_seal_fill,
            size: 22,
            color: ColituColors.success,
          ),
        ),
        const SizedBox(height: 18),
        // Connection
        _SectionTitle(loc['account.connection']),
        ColituActionRow(
          icon: CupertinoIcons.antenna_radiowaves_left_right,
          title: loc['account.protocol'],
          hint: c.connected && c.transport != null
              ? '${loc['account.protocolAuto']} · ${c.transportName}'
              : loc['account.protocolAuto'],
          trailing: const SizedBox.shrink(),
        ),
        const SizedBox(height: 8),
        ColituTile(
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const ColituRoundIcon(CupertinoIcons.globe),
                  const SizedBox(width: 12),
                  Text(loc['settings.language'], style: ColituText.label),
                ],
              ),
              const SizedBox(height: 10),
              ColituSegment<String>(
                values: ColituLoc.languages,
                selected: loc.language,
                onChanged: (value) => ColituLoc.I.setLanguage(value),
                labelOf: (value) => switch (value) {
                  'ru' => 'Русский',
                  'tr' => 'Türkçe',
                  _ => 'English',
                },
                height: 40,
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        // Devices
        Row(
          children: [
            Expanded(child: _SectionTitle(loc['account.devices'])),
            if (!_loadingDevices)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  loc.format('account.devicesTitle', {
                    'used': _devices.length,
                    'limit': limit < _devices.length ? _devices.length : limit,
                  }),
                  style: ColituText.small,
                ),
              ),
          ],
        ),
        if (_loadingDevices)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Center(child: ColituSpinner()),
          )
        else if (_error != null)
          ColituNotice(
            _error!,
            action: ColituLinkButton(label: loc['pricing.retry'], onPressed: _loadDevices),
          )
        else
          for (final device in _devices) ...[
            _DeviceRow(device: device, onRemove: () => _remove(device)),
            const SizedBox(height: 8),
          ],
        const SizedBox(height: 10),
        // General
        _SectionTitle(loc['account.general']),
        ColituActionRow(
          icon: CupertinoIcons.play_circle,
          title: loc['account.howItWorks'],
          onTap: _howItWorks,
        ),
        const SizedBox(height: 8),
        ColituActionRow(
          icon: CupertinoIcons.chat_bubble_text,
          title: loc['support.title'],
          hint: loc['account.helpHint'],
          onTap: widget.onOpenSupport ?? () => _open('/support'),
        ),
        const SizedBox(height: 8),
        ColituActionRow(
          icon: CupertinoIcons.question_circle,
          title: loc['support.help'],
          onTap: () => launchUrl(
            Uri.parse('https://docs.colitu.com/${loc.language}'),
            mode: LaunchMode.externalApplication,
          ),
        ),
        const SizedBox(height: 8),
        ColituActionRow(
          icon: CupertinoIcons.mail,
          title: loc['account.mail'],
          onTap: _mail,
        ),
        const SizedBox(height: 8),
        ColituActionRow(
          icon: CupertinoIcons.doc_on_clipboard,
          title: loc['account.diagnostics'],
          hint: loc['account.diagnosticsHint'],
          onTap: _shareDiagnostics,
        ),
        const SizedBox(height: 8),
        ColituActionRow(
          icon: CupertinoIcons.doc_text,
          title: loc['settings.terms'],
          onTap: () => _open('/legal/terms'),
        ),
        const SizedBox(height: 8),
        ColituActionRow(
          icon: CupertinoIcons.lock_shield,
          title: loc['settings.privacy'],
          onTap: () => _open('/legal/privacy'),
        ),
        const SizedBox(height: 8),
        ColituActionRow(
          icon: CupertinoIcons.chevron_left_slash_chevron_right,
          title: loc['settings.openSource'],
          hint: loc['settings.openSourceHint'],
          onTap: () => launchUrl(
            Uri.parse(AppEnvironment.sourceCodeUrl),
            mode: LaunchMode.externalApplication,
          ),
        ),
        const SizedBox(height: 8),
        ColituActionRow(
          icon: CupertinoIcons.doc_plaintext,
          title: loc['settings.licenses'],
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'Colitu VPN',
            applicationVersion: _version,
            applicationLegalese:
                'GPL-3.0 · ${AppEnvironment.sourceCodeUrl}\n'
                'Based on OneXray (GPL-3.0). Xray-core (MPL-2.0), '
                'libXray (MIT), hev-socks5-tunnel (MIT).',
          ),
        ),
        const SizedBox(height: 8),
        ColituActionRow(
          icon: CupertinoIcons.info,
          title: 'Colitu VPN',
          hint: _version.isEmpty ? null : loc.format('settings.version', {'version': _version}),
          onTap: () => _open(''),
        ),
        const SizedBox(height: 18),
        ColituButton.danger(
          label: loc['account.signOut'],
          icon: CupertinoIcons.square_arrow_right,
          onPressed: widget.onSignOut,
        ),
        const SizedBox(height: 14),
        Center(
          child: Text(
            loc.format('brand.credit', {'brand': AppEnvironment.companyName}),
            style: ColituText.small,
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(text, style: ColituText.label.copyWith(color: ColituColors.muted)),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.onRemove});

  final ColituDevice device;
  final VoidCallback onRemove;

  IconData get _icon => switch ((device.platform ?? '').toLowerCase()) {
    'ios' || 'iphone' || 'ipad' => CupertinoIcons.device_phone_portrait,
    'android' => CupertinoIcons.device_phone_portrait,
    'macos' || 'mac' => CupertinoIcons.device_laptop,
    'windows' || 'linux' => CupertinoIcons.desktopcomputer,
    _ => CupertinoIcons.device_phone_portrait,
  };

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    return ColituTile(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        children: [
          ColituRoundIcon(_icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        device.name,
                        style: ColituText.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (device.current) ...[
                      const SizedBox(width: 8),
                      ColituBadge(loc['account.thisDevice']),
                    ],
                  ],
                ),
                if (device.lastActiveAt != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    loc.format('account.lastSeen', {'date': loc.date(device.lastActiveAt!)}),
                    style: ColituText.small,
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: loc['account.remove'],
            onPressed: onRemove,
            icon: const Icon(CupertinoIcons.xmark_circle, size: 20, color: ColituColors.dim),
          ),
        ],
      ),
    );
  }
}
