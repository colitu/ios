import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/colitu_growth.dart';
import 'package:colitu_vpn/colitu/services/colitu_referral.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/invite/page.dart';

/// Opens a Telegram or WhatsApp share link in the external handler.
Future<void> colituOpenShareLink(Uri uri) async {
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('Open share link failed: ${uri.host} $e');
  }
}

/// The share template and the day count for a referral, in the app language.
({String template, String days}) colituShareParts(ColituReferral referral) {
  final loc = ColituLoc.I;
  return (
    template: loc['invite.oneTapText'],
    days: loc.count('day', referral.inviteeDays),
  );
}

/// Telegram, WhatsApp and system Share buttons for one referral.
class ColituShareButtons extends StatelessWidget {
  const ColituShareButtons({
    super.key,
    required this.referral,
    this.height = 44,
  });

  final ColituReferral referral;
  final double height;

  Future<void> _system(BuildContext context) async {
    final parts = colituShareParts(referral);
    final text = ColituShare.message(parts.template, parts.days, referral.link);
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    try {
      await SharePlus.instance.share(
        ShareParams(text: text, sharePositionOrigin: origin),
      );
    } catch (e) {
      debugPrint('Share invite failed: $e');
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) showColituToast(context, ColituLoc.I['invite.copied']);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final parts = colituShareParts(referral);
    return Row(
      children: [
        Expanded(
          child: ColituButton.secondary(
            key: const ValueKey('shareTelegram'),
            label: loc['invite.telegram'],
            height: height,
            onPressed: () => unawaited(
              colituOpenShareLink(
                ColituShare.telegramUri(parts.template, parts.days, referral.link),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ColituButton.secondary(
            key: const ValueKey('shareWhatsapp'),
            label: loc['invite.whatsapp'],
            height: height,
            onPressed: () => unawaited(
              colituOpenShareLink(
                ColituShare.whatsappUri(parts.template, parts.days, referral.link),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Builder(
            builder: (inner) => ColituButton.secondary(
              key: const ValueKey('shareSystem'),
              label: loc['invite.share'],
              height: height,
              onPressed: () => unawaited(_system(inner)),
            ),
          ),
        ),
      ],
    );
  }
}

/// Compact invite card for the home screen. Appears only after the first
/// successful connection on this install, never when the panel reports the
/// programme off or gives no https colitu.com link, and stays away for 14
/// days after the X.
class ColituHomeInviteCard extends StatefulWidget {
  const ColituHomeInviteCard({
    super.key,
    required this.connected,
    this.service,
    this.prefs,
  });

  /// Whether the tunnel is up right now (marks the install eligible).
  final bool connected;
  final ColituReferralService? service;
  final ColituInviteCardPrefs? prefs;

  @override
  State<ColituHomeInviteCard> createState() => _ColituHomeInviteCardState();
}

class _ColituHomeInviteCardState extends State<ColituHomeInviteCard> {
  // Kept between visits to the tab so the panel is asked once in a while.
  static ColituReferral? _cached;
  static DateTime? _cachedAt;
  static const _cacheFor = Duration(minutes: 30);

  late final ColituInviteCardPrefs _prefs =
      widget.prefs ?? ColituInviteCardPrefs.instance;
  ColituReferral? _referral;
  var _visible = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(ColituHomeInviteCard old) {
    super.didUpdateWidget(old);
    if (widget.connected && !old.connected) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (widget.connected) await _prefs.markConnected();
    if (!await _prefs.isEligible() || await _prefs.isDismissed()) return;
    var referral = _cached;
    final at = _cachedAt;
    if (referral == null ||
        at == null ||
        DateTime.now().difference(at) > _cacheFor) {
      try {
        referral = await (widget.service ?? ColituReferralService()).load();
        _cached = referral;
        _cachedAt = DateTime.now();
      } catch (_) {
        referral = null;
      }
    }
    final show = await _prefs.shouldShow(referral);
    if (!mounted) return;
    setState(() {
      _referral = referral;
      _visible = show;
    });
  }

  Future<void> _dismiss() async {
    setState(() => _visible = false);
    await _prefs.dismiss();
  }

  @override
  Widget build(BuildContext context) {
    final referral = _referral;
    if (!_visible || referral == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: ColituLoc.I,
      builder: (context, _) {
        final loc = ColituLoc.I;
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: ColituPanel(
            key: const ValueKey('homeInviteCard'),
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
            radius: ColituRadius.md,
            onTap: () => ColituInvitePage.open(context),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const ColituRoundIcon(CupertinoIcons.gift, size: 36, accent: true),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            loc['invite.title'],
                            style: ColituText.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            loc.format('invite.cardBody', {
                              'days': loc.count('day', referral.inviteeDays),
                            }),
                            style: ColituText.small,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    ColituIconButton(
                      key: const ValueKey('homeInviteDismiss'),
                      icon: CupertinoIcons.xmark,
                      size: 36,
                      tooltip: loc['invite.hide'],
                      onPressed: () => unawaited(_dismiss()),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ColituShareButtons(referral: referral, height: 40),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
