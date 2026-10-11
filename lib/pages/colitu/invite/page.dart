import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_errors.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/colitu_referral.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';

/// "Invite a friend": the user's invite link with Copy and Share, four
/// counters and the rules. Never shows names or e-mails of invitees.
class ColituInvitePage extends StatefulWidget {
  const ColituInvitePage({super.key, this.service});

  final ColituReferralService? service;

  /// Opens the page over the shell (from Account).
  static Future<void> open(BuildContext context) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const ColituInvitePage()),
    );
  }

  /// The text that goes with the link in the share sheet.
  static String shareText(ColituReferral referral) {
    final loc = ColituLoc.I;
    return '${loc.format('invite.shareText', {'days': loc.count('day', referral.inviteeDays)})} ${referral.link}';
  }

  @override
  State<ColituInvitePage> createState() => _ColituInvitePageState();
}

class _ColituInvitePageState extends State<ColituInvitePage> {
  late final ColituReferralService _service =
      widget.service ?? ColituReferralService();
  ColituReferral? _referral;
  String? _error;
  var _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final referral = await _service.load();
      if (!mounted) return;
      setState(() => _referral = referral);
    } catch (e) {
      if (mounted) setState(() => _error = colituErrorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copy(ColituReferral referral) async {
    await Clipboard.setData(ClipboardData(text: referral.link));
    if (mounted) showColituToast(context, ColituLoc.I['invite.copied']);
  }

  Future<void> _share(ColituReferral referral) async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: ColituInvitePage.shareText(referral),
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      debugPrint('Share invite failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ColituLoc.I,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final loc = ColituLoc.I;
    final referral = _referral;
    return ColituScaffold(
      padding: EdgeInsets.zero,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          8,
          20,
          28 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: ColituIconButton(
              icon: CupertinoIcons.chevron_left,
              size: 40,
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          const SizedBox(height: 14),
          ColituPageHeader(
            kicker: loc['invite.kicker'],
            title: loc['invite.title'],
            subtitle: loc['invite.sub'],
          ),
          const SizedBox(height: 18),
          if (_loading && referral == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: ColituSpinner()),
            )
          else if (referral == null)
            ColituNotice(
              _error ?? loc['err.generic'],
              action: ColituLinkButton(
                key: const ValueKey('inviteRetry'),
                label: loc['pricing.retry'],
                onPressed: _load,
              ),
            )
          else ...[
            if (!referral.enabled) ...[
              ColituNotice(loc['invite.disabled'], error: false),
              const SizedBox(height: 14),
            ],
            _LinkCard(
              referral: referral,
              onCopy: () => _copy(referral),
              onShare: () => _share(referral),
            ),
            const SizedBox(height: 14),
            _Stats(referral: referral),
            const SizedBox(height: 18),
            _Rules(referral: referral),
          ],
        ],
      ),
    );
  }
}

class _LinkCard extends StatelessWidget {
  const _LinkCard({
    required this.referral,
    required this.onCopy,
    required this.onShare,
  });

  final ColituReferral referral;
  final VoidCallback onCopy;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    return ColituPanel(
      glow: true,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            loc['invite.link'],
            style: ColituText.small.copyWith(
              color: ColituColors.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            key: const ValueKey('inviteLink'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: ColituColors.field,
              borderRadius: BorderRadius.circular(ColituRadius.md),
              border: Border.all(color: ColituColors.line),
            ),
            child: SelectableText(
              referral.link,
              style: ColituText.body.copyWith(fontSize: 15),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ColituButton.secondary(
                  key: const ValueKey('inviteCopy'),
                  label: loc['invite.copy'],
                  icon: CupertinoIcons.doc_on_doc,
                  onPressed: onCopy,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ColituButton(
                  key: const ValueKey('inviteShare'),
                  label: loc['invite.share'],
                  icon: CupertinoIcons.share,
                  height: 52,
                  onPressed: onShare,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.referral});

  final ColituReferral referral;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final r = referral;
    final cells = [
      _Stat(
        key: const ValueKey('statInvited'),
        label: loc['invite.stat.invited'],
        value: '${r.invited}',
      ),
      _Stat(
        key: const ValueKey('statValid'),
        label: loc['invite.stat.valid'],
        value: '${r.rewarded}',
        note: r.pending > 0
            ? loc.format('invite.stat.pending', {'n': r.pending})
            : null,
      ),
      _Stat(
        key: const ValueKey('statEarned'),
        label: loc['invite.stat.earned'],
        value: loc.count('day', r.daysEarned),
      ),
      _Stat(
        key: const ValueKey('statLeft'),
        label: loc['invite.stat.left'],
        value: '${r.left} / ${r.monthlyCap}',
      ),
    ];
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: cells[0]),
            const SizedBox(width: 10),
            Expanded(child: cells[1]),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: cells[2]),
            const SizedBox(width: 10),
            Expanded(child: cells[3]),
          ],
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({super.key, required this.label, required this.value, this.note});

  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return ColituTile(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: ColituText.small),
          const SizedBox(height: 6),
          Text(value, style: ColituText.h2),
          if (note != null) ...[
            const SizedBox(height: 2),
            Text(note!, style: ColituText.small.copyWith(color: ColituColors.lilac)),
          ],
        ],
      ),
    );
  }
}

class _Rules extends StatelessWidget {
  const _Rules({required this.referral});

  final ColituReferral referral;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final r = referral;
    final lines = [
      loc.format('invite.rule1', {'days': loc.count('day', r.inviteeDays)}),
      loc.format('invite.rule2', {'days': loc.count('day', r.rewardDays)}),
      loc.format('invite.rule3', {'cap': r.monthlyCap}),
      loc['invite.rule4'],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            loc['invite.rules'],
            style: ColituText.label.copyWith(color: ColituColors.muted),
          ),
        ),
        for (var i = 0; i < lines.length; i++)
          Padding(
            key: ValueKey('inviteRule$i'),
            padding: const EdgeInsets.only(left: 4, right: 4, bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 3),
                  child: Icon(
                    CupertinoIcons.checkmark_circle,
                    size: 16,
                    color: ColituColors.lilac,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(lines[i], style: ColituText.muted)),
              ],
            ),
          ),
      ],
    );
  }
}
