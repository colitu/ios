import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/colitu_split_tunnel.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';

/// Split tunneling: the mode (off, listed sites bypass the VPN, only listed
/// sites use it) and the list of domains and IP ranges. iOS cannot choose
/// apps for a consumer VPN, and the page says so.
class ColituSplitTunnelPage extends StatefulWidget {
  const ColituSplitTunnelPage({super.key, required this.controller});

  final ColituConnectionController controller;

  /// Opens the page over the shell (from Account or the home screen chip).
  static Future<void> open(
    BuildContext context,
    ColituConnectionController controller,
  ) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ColituSplitTunnelPage(controller: controller),
      ),
    );
  }

  @override
  State<ColituSplitTunnelPage> createState() => _ColituSplitTunnelPageState();
}

class _ColituSplitTunnelPageState extends State<ColituSplitTunnelPage> {
  final _input = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _add() {
    final loc = ColituLoc.I;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final result = widget.controller.splitTunnel.add(text);
    final settings = result.settings;
    if (settings == null) {
      setState(() {
        _error = switch (result.error) {
          SplitTunnelEntryError.duplicate => loc['split.err.duplicate'],
          SplitTunnelEntryError.tooMany => loc.format('split.err.tooMany', {
            'n': ColituSplitTunnel.maxEntries,
          }),
          _ => loc['split.err.invalid'],
        };
      });
      return;
    }
    _input.clear();
    setState(() => _error = null);
    unawaited(widget.controller.setSplitTunnel(settings));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.controller, ColituLoc.I]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final loc = ColituLoc.I;
    final c = widget.controller;
    final settings = c.splitTunnel;
    final entries = [...settings.domains, ...settings.ips];
    return ColituScaffold(
      padding: EdgeInsets.zero,
      resizeToAvoidBottomInset: true,
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
            kicker: loc['split.kicker'],
            title: loc['split.title'],
            subtitle: loc['split.intro'],
          ),
          const SizedBox(height: 18),
          for (final mode in SplitTunnelMode.values) ...[
            _ModeOption(
              key: ValueKey('splitMode.${mode.name}'),
              title: loc['split.mode.${mode.name}'],
              hint: loc['split.mode.${mode.name}Hint'],
              selected: settings.mode == mode,
              onTap: () => unawaited(c.setSplitTunnel(settings.copyWith(mode: mode))),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              loc['split.list'],
              style: ColituText.label.copyWith(color: ColituColors.muted),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: ColituField(
                  key: const ValueKey('splitInput'),
                  controller: _input,
                  label: loc['split.field'],
                  hint: 'example.com, 203.0.113.0/24',
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  autocorrect: false,
                  maxLength: 300,
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: ColituIconButton(
                  key: const ValueKey('splitAdd'),
                  icon: CupertinoIcons.add,
                  accent: true,
                  tooltip: loc['split.add'],
                  onPressed: _add,
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            ColituNotice(_error!),
          ],
          const SizedBox(height: 10),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(loc['split.empty'], style: ColituText.small),
            )
          else
            for (final entry in entries) ...[
              _EntryRow(
                entry: entry,
                isDomain: settings.domains.contains(entry),
                onRemove: () => unawaited(c.setSplitTunnel(settings.remove(entry))),
              ),
              const SizedBox(height: 6),
            ],
          const SizedBox(height: 16),
          ColituPanel(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            radius: ColituRadius.md,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ColituRoundIcon(CupertinoIcons.app_badge, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(loc['split.appsTitle'], style: ColituText.label),
                      const SizedBox(height: 4),
                      Text(loc['split.appsBody'], style: ColituText.small),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(loc['split.notes'], style: ColituText.small),
          ),
        ],
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({
    super.key,
    required this.title,
    required this.hint,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String hint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: ColituTile(
        active: selected,
        onTap: onTap,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: ColituText.label),
                  const SizedBox(height: 2),
                  Text(hint, style: ColituText.small),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              selected
                  ? CupertinoIcons.checkmark_circle_fill
                  : CupertinoIcons.circle,
              size: 22,
              color: selected ? ColituColors.lilac : ColituColors.dim,
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.isDomain,
    required this.onRemove,
  });

  final String entry;
  final bool isDomain;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return ColituTile(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      child: Row(
        children: [
          Icon(
            isDomain ? CupertinoIcons.globe : CupertinoIcons.number,
            size: 18,
            color: ColituColors.lilac,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              entry,
              style: ColituText.body.copyWith(fontSize: 15),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: ColituLoc.I['split.remove'],
            onPressed: onRemove,
            icon: const Icon(
              CupertinoIcons.minus_circle,
              size: 22,
              color: ColituColors.danger,
            ),
          ),
        ],
      ),
    );
  }
}
