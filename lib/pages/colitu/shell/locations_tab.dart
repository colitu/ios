import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/colitu_ad_block.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/shell/page.dart';

/// "all" plus the panel's use-case categories.
const _filters = ['all', ...VPNServer.categoryOrder];

enum _Sort { ping, name, load }

/// Server list: title with the "fastest server" shortcut, search, category
/// chips, a sort menu, the recommended locations and then every other one.
/// Each card shows the round flag, the city, the ping and what opens there.
class LocationsTab extends StatefulWidget {
  const LocationsTab({super.key, required this.controller, this.onOpenPlan});

  final ColituConnectionController controller;
  final VoidCallback? onOpenPlan;

  @override
  State<LocationsTab> createState() => _LocationsTabState();
}

class _LocationsTabState extends State<LocationsTab> {
  final _search = TextEditingController();
  var _filter = 'all';
  var _sort = _Sort.ping;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    unawaited(widget.controller.measurePings());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _fold(String value) => value
      .toLowerCase()
      .replaceAll('ı', 'i')
      .replaceAll('ğ', 'g')
      .replaceAll('ü', 'u')
      .replaceAll('ş', 's')
      .replaceAll('ö', 'o')
      .replaceAll('ç', 'c');

  List<VPNServer> _filtered() {
    final c = widget.controller;
    final query = _fold(_search.text.trim());
    final items = c.servers.where((server) {
      if (!server.inCategory(_filter)) return false;
      if (query.isEmpty) return true;
      final haystack = _fold(
        '${c.titleOf(server)} ${server.displayTitle} ${server.displayCountry} ${server.city ?? ''} ${server.countryCode}',
      );
      return haystack.contains(query);
    }).toList();
    int byName(VPNServer a, VPNServer b) =>
        c.titleOf(a).compareTo(c.titleOf(b));
    items.sort((a, b) {
      if (a.isSelectable != b.isSelectable) return a.isSelectable ? -1 : 1;
      switch (_sort) {
        case _Sort.ping:
          final pa = c.pingOf(a) ?? 1 << 30;
          final pb = c.pingOf(b) ?? 1 << 30;
          return pa != pb ? pa.compareTo(pb) : byName(a, b);
        case _Sort.load:
          final la = a.load ?? 1 << 30;
          final lb = b.load ?? 1 << 30;
          return la != lb ? la.compareTo(lb) : byName(a, b);
        case _Sort.name:
          return byName(a, b);
      }
    });
    return items;
  }

  /// Multihop routes matching the search; they belong to no category.
  List<VPNServer> _routes() {
    if (_filter != 'all') return const [];
    final query = _fold(_search.text.trim());
    return [
      for (final route in widget.controller.multihopServers)
        if (query.isEmpty ||
            _fold(
              '${route.name} ${route.entry?.label ?? ''} ${route.exit?.label ?? ''} ${route.entry?.country ?? ''} ${route.exit?.country ?? ''}',
            ).contains(query))
          route,
    ];
  }

  /// The panel's recommended locations; without any, the three fastest.
  List<VPNServer> _recommended(List<VPNServer> items) {
    final c = widget.controller;
    final flagged = items
        .where((s) => s.isRecommended && s.isSelectable)
        .toList();
    if (flagged.isNotEmpty) return flagged;
    final fastest =
        items.where((s) => s.isSelectable && c.pingOf(s) != null).toList()
          ..sort((a, b) => c.pingOf(a)!.compareTo(c.pingOf(b)!));
    final keep = fastest.take(3).toSet();
    return items.where(keep.contains).toList();
  }

  Future<void> _chooseSort() async {
    final loc = ColituLoc.I;
    final picked = await showCupertinoModalPopup<_Sort>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(loc['locations.sortTitle']),
        actions: [
          for (final sort in _Sort.values)
            CupertinoActionSheetAction(
              isDefaultAction: sort == _sort,
              onPressed: () => Navigator.of(context).pop(sort),
              child: Text(loc['locations.sort.${sort.name}']),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(loc['locations.sortCancel']),
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _sort = picked);
  }

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final c = widget.controller;
    final items = _filtered();
    final recommended = _recommended(items);
    final rest = items.where((s) => !recommended.contains(s)).toList();
    final routes = _routes();
    var index = 0;
    Widget card(VPNServer server) {
      final delay = Duration(milliseconds: 40 * (index++).clamp(0, 8));
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: ColituReveal(
          delay: delay,
          child: _ServerCard(controller: c, server: server),
        ),
      );
    }

    return ShellScroll(
      onRefresh: () => c.load(showLoading: false),
      children: [
        Row(
          children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  loc['locations.title'],
                  style: ColituText.h1.copyWith(fontSize: 30),
                  maxLines: 1,
                ),
              ),
            ),
            const SizedBox(width: 10),
            _FastestButton(controller: c),
          ],
        ),
        const SizedBox(height: 4),
        Text(loc['locations.tagline'], style: ColituText.muted),
        const SizedBox(height: 16),
        TextField(
          controller: _search,
          style: ColituText.body.copyWith(fontSize: 16),
          cursorColor: ColituColors.lilac,
          decoration: InputDecoration(
            hintText: '${loc['locations.search']}…',
            hintStyle: ColituText.body.copyWith(
              color: ColituColors.dim,
              fontSize: 16,
            ),
            prefixIcon: const Padding(
              padding: EdgeInsets.only(left: 16, right: 8),
              child: Icon(
                CupertinoIcons.search,
                size: 20,
                color: ColituColors.muted,
              ),
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 44),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    onPressed: _search.clear,
                    icon: const Icon(
                      CupertinoIcons.xmark_circle_fill,
                      size: 18,
                      color: ColituColors.dim,
                    ),
                  ),
            filled: true,
            fillColor: ColituColors.surface2,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 15,
            ),
            border: _border(ColituColors.line),
            enabledBorder: _border(ColituColors.line),
            focusedBorder: _border(ColituColors.violet),
          ),
        ),
        const SizedBox(height: 14),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            children: [
              for (final filter in _filters)
                if (filter == 'all' ||
                    filter == _filter ||
                    c.servers.any((s) => s.inCategory(filter))) ...[
                  ColituChip(
                    label: filter == 'all'
                        ? loc['locations.all']
                        : loc['cat.$filter'],
                    icon: _categoryIcon(filter),
                    selected: _filter == filter,
                    onTap: () => setState(() => _filter = filter),
                  ),
                  const SizedBox(width: 8),
                ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (!c.planActive && widget.onOpenPlan != null) ...[
          ColituPanel(
            onTap: widget.onOpenPlan,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            radius: ColituRadius.md,
            child: Row(
              children: [
                const ColituRoundIcon(
                  CupertinoIcons.globe,
                  size: 42,
                  accent: true,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(loc['locations.promo'], style: ColituText.label),
                      const SizedBox(height: 2),
                      Text(loc['locations.promoSub'], style: ColituText.small),
                    ],
                  ),
                ),
                const Icon(
                  CupertinoIcons.chevron_right,
                  size: 16,
                  color: ColituColors.dim,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (c.servers.isEmpty)
          _Empty(c.planRequired ? loc['plan.noneHint'] : loc['server.none'])
        else if (items.isEmpty)
          _Empty(
            _filter != 'all' && _search.text.trim().isEmpty
                ? loc['cat.empty']
                : loc['locations.empty'],
          )
        else ...[
          _SectionHeader(
            title: recommended.isNotEmpty
                ? loc['locations.recommended']
                : loc['locations.allServers'],
            trailing: _SortButton(
              label: loc['locations.sort.${_sort.name}'],
              onTap: _chooseSort,
            ),
          ),
          const SizedBox(height: 12),
          for (final server in recommended) card(server),
          if (recommended.isNotEmpty && rest.isNotEmpty) ...[
            const SizedBox(height: 10),
            _SectionHeader(title: loc['locations.allServers']),
            const SizedBox(height: 12),
          ],
          for (final server in rest) card(server),
        ],
        if (routes.isNotEmpty) ...[
          const SizedBox(height: 14),
          _SectionHeader(title: loc['multihop.section']),
          const SizedBox(height: 4),
          Text(loc['multihop.sectionHint'], style: ColituText.small),
          const SizedBox(height: 12),
          for (final route in routes)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _RouteCard(controller: c, route: route),
            ),
        ],
      ],
    );
  }

  OutlineInputBorder _border(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(ColituRadius.pill),
    borderSide: BorderSide(color: color),
  );
}

IconData _categoryIcon(String category) => switch (category) {
  'all' => CupertinoIcons.square_grid_2x2,
  'ai' => Icons.smart_toy_outlined,
  'streaming' => Icons.movie_creation_outlined,
  'gaming' => Icons.sports_esports_outlined,
  'speed' => CupertinoIcons.bolt,
  'privacy' => CupertinoIcons.shield,
  'torrent' => CupertinoIcons.arrow_down_circle,
  'adblock' => CupertinoIcons.eye_slash,
  _ => CupertinoIcons.circle,
};

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 30),
    child: Center(
      child: Text(text, style: ColituText.muted, textAlign: TextAlign.center),
    ),
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(title, style: ColituText.h2.copyWith(fontSize: 20))),
      ?trailing,
    ],
  );
}

/// "Fastest server" in the title row: picks the server automatically.
class _FastestButton extends StatelessWidget {
  const _FastestButton({required this.controller});

  final ColituConnectionController controller;

  @override
  Widget build(BuildContext context) {
    final active = controller.autoSelection;
    return ColituPressable(
      onTap: controller.selectAuto,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
        decoration: BoxDecoration(
          color: active
              ? ColituColors.violet.withValues(alpha: 0.18)
              : ColituColors.surface2,
          borderRadius: BorderRadius.circular(ColituRadius.pill),
          border: Border.all(
            color: active ? ColituColors.violet : ColituColors.lineStrong,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              CupertinoIcons.bolt_fill,
              size: 18,
              color: ColituColors.violet,
            ),
            const SizedBox(width: 6),
            Text(
              ColituLoc.I['locations.fastest'],
              style: ColituText.label.copyWith(fontSize: 14),
            ),
            const SizedBox(width: 4),
            Icon(
              active
                  ? CupertinoIcons.checkmark_alt
                  : CupertinoIcons.chevron_right,
              size: 14,
              color: active ? ColituColors.lilac : ColituColors.muted,
            ),
          ],
        ),
      ),
    );
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ColituPressable(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ColituColors.surface2,
        borderRadius: BorderRadius.circular(ColituRadius.pill),
        border: Border.all(color: ColituColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.sort_down,
            size: 16,
            color: ColituColors.muted,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: ColituText.small.copyWith(color: ColituColors.text),
          ),
          const SizedBox(width: 4),
          const Icon(
            CupertinoIcons.chevron_down,
            size: 12,
            color: ColituColors.muted,
          ),
        ],
      ),
    ),
  );
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({required this.controller, required this.server});

  final ColituConnectionController controller;
  final VPNServer server;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final c = controller;
    final selected =
        !c.autoSelection &&
        c.selectedServer?.selectionKey == server.selectionKey;
    final connected =
        c.connected && c.connectedServer?.selectionKey == server.selectionKey;
    final selectable = server.isSelectable;
    final code = server.countryCode;
    final country = code.length == 2
        ? loc.countryName(code)
        : server.displayCountry;
    final city = server.city?.trim() ?? '';
    final tags = _tags(server);
    return Opacity(
      opacity: selectable ? 1 : 0.5,
      child: ColituTile(
        active: selected || connected,
        onTap: selectable ? () => c.selectServer(server) : null,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ColituFlag(code, size: 46),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              country.isEmpty ? server.displayTitle : country,
                              style: ColituText.label.copyWith(fontSize: 17),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (connected) ...[
                            const SizedBox(width: 8),
                            _Pill(loc['server.connected'], accent: true),
                          ] else if (server.isPremium) ...[
                            const SizedBox(width: 8),
                            const ColituBadge('PRO'),
                          ],
                        ],
                      ),
                      if (city.isNotEmpty &&
                          city.toLowerCase() != country.toLowerCase()) ...[
                        const SizedBox(height: 2),
                        Text(
                          city,
                          style: ColituText.muted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (selectable)
                  _Ping(c.pingOf(server))
                else
                  Text(loc['server.offline'], style: ColituText.small),
                const SizedBox(width: 12),
                _GoButton(active: selected || connected),
              ],
            ),
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(left: 58),
                child: _TagLine(tags),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Services the panel verified on this node first, then the use cases they
  /// do not already cover.
  static List<_Tag> _tags(VPNServer server) {
    final out = <_Tag>[
      // First, so it never folds into the "+N" pill.
      if (ColituAdBlock.hostsDns(server.host))
        _Tag(ColituLoc.I['cat.adblock'], category: 'adblock'),
      for (final entry in VPNServer.serviceNames.entries)
        if (server.services.contains(entry.key))
          _Tag(entry.value, service: entry.key),
    ];
    final hasAi = server.services.any(VPNServer.requiredAiServices.contains);
    final hasStreaming = server.services.any(
      VPNServer.streamingServices.contains,
    );
    for (final category in VPNServer.categoryOrder) {
      if (!server.categories.contains(category)) continue;
      if (category == 'ai' && hasAi) continue;
      if (category == 'streaming' && hasStreaming) continue;
      out.add(_Tag(ColituLoc.I['cat.$category'], category: category));
    }
    return out;
  }
}

/// A multihop route: the entry and exit flags, the route name and the ping
/// to the entry (an estimate: the exit adds a hop).
class _RouteCard extends StatelessWidget {
  const _RouteCard({required this.controller, required this.route});

  final ColituConnectionController controller;
  final VPNServer route;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final c = controller;
    final selected =
        !c.autoSelection && c.selectedServer?.selectionKey == route.selectionKey;
    final connected =
        c.connected && c.connectedServer?.selectionKey == route.selectionKey;
    final selectable = route.isSelectable;
    return Opacity(
      opacity: selectable ? 1 : 0.5,
      child: ColituTile(
        key: ValueKey('route.${route.id}'),
        active: selected || connected,
        onTap: selectable ? () => c.selectServer(route) : null,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Row(
          children: [
            ColituFlag(route.entry?.country ?? '', size: 36),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                CupertinoIcons.arrow_right,
                size: 14,
                color: ColituColors.muted,
              ),
            ),
            ColituFlag(route.exit?.country ?? '', size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          route.name,
                          style: ColituText.label.copyWith(fontSize: 16),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (connected) ...[
                        const SizedBox(width: 8),
                        _Pill(loc['server.connected'], accent: true),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    selectable ? loc['multihop.ping'] : loc['server.offline'],
                    style: ColituText.small,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (selectable) _Ping(c.pingOf(route)),
            const SizedBox(width: 10),
            _GoButton(active: selected || connected),
          ],
        ),
      ),
    );
  }
}

class _Tag {
  const _Tag(this.label, {this.service, this.category});

  final String label;
  final String? service;
  final String? category;
}

const _tagStyle = TextStyle(
  fontFamily: ColituText.family,
  fontSize: 12.5,
  height: 1.2,
  fontWeight: FontWeight.w500,
  color: ColituColors.text,
);
const _pillStyle = TextStyle(
  fontFamily: ColituText.family,
  fontSize: 12,
  height: 1.2,
  fontWeight: FontWeight.w600,
  color: ColituColors.muted,
);
const _tagIcon = 17.0;
const _tagIconGap = 5.0;
const _tagSpacing = 10.0;

/// Slack per tag so rounding never squeezes a label into an ellipsis.
const _tagSlack = 6.0;

/// One line of tags: as many as fit, then "+N" for the rest.
class _TagLine extends StatelessWidget {
  const _TagLine(this.tags);

  final List<_Tag> tags;

  static double _textWidth(String text, TextStyle style, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    return painter.width;
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final max = constraints.maxWidth;
        double pill(int n) => _textWidth('+$n', _pillStyle, scaler) + 20;
        var used = 0.0;
        var count = 0;
        for (var i = 0; i < tags.length; i++) {
          final width =
              _tagSlack +
              _tagIcon +
              _tagIconGap +
              _textWidth(tags[i].label, _tagStyle, scaler);
          final next = used + (i == 0 ? 0 : _tagSpacing) + width;
          final left = tags.length - i - 1;
          final reserve = left > 0 ? _tagSpacing + pill(left) : 0;
          if (next + reserve > max && i > 0) break;
          used = next;
          count = i + 1;
        }
        final hidden = tags.length - count;
        return Row(
          children: [
            for (var i = 0; i < count; i++) ...[
              if (i > 0) const SizedBox(width: _tagSpacing),
              Flexible(child: _TagView(tags[i])),
            ],
            if (hidden > 0) ...[
              const SizedBox(width: _tagSpacing),
              _Pill('+$hidden'),
            ],
          ],
        );
      },
    );
  }
}

class _TagView extends StatelessWidget {
  const _TagView(this.tag);

  final _Tag tag;

  @override
  Widget build(BuildContext context) {
    final service = tag.service;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: _tagIcon,
          height: _tagIcon,
          child: service != null
              ? ColituServiceMark(service, size: _tagIcon)
              : Icon(
                  _categoryIcon(tag.category ?? ''),
                  size: _tagIcon - 1,
                  color: ColituColors.text,
                ),
        ),
        const SizedBox(width: _tagIconGap),
        Flexible(
          child: Text(
            tag.label,
            style: _tagStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {this.accent = false});

  final String text;
  final bool accent;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: accent
          ? ColituColors.violet.withValues(alpha: 0.22)
          : ColituColors.surface2,
      borderRadius: BorderRadius.circular(ColituRadius.pill),
      border: Border.all(
        color: accent ? Colors.transparent : ColituColors.line,
      ),
    ),
    child: Text(
      text,
      style: _pillStyle.copyWith(
        color: accent ? ColituColors.lilac : ColituColors.muted,
      ),
    ),
  );
}

/// Signal bars and the ping in milliseconds.
class _Ping extends StatelessWidget {
  const _Ping(this.ms);

  final int? ms;

  @override
  Widget build(BuildContext context) {
    final value = ms;
    final color = value == null
        ? ColituColors.dim
        : value < 60
        ? ColituColors.success
        : value < 150
        ? ColituColors.warning
        : ColituColors.danger;
    final bars = value == null
        ? 0
        : value < 60
        ? 4
        : value < 100
        ? 3
        : value < 200
        ? 2
        : 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 4; i++) ...[
          Container(
            width: 3.5,
            height: 6.0 + i * 3,
            decoration: BoxDecoration(
              color: i < bars ? color : ColituColors.lineStrong,
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
          if (i < 3) const SizedBox(width: 2),
        ],
        const SizedBox(width: 8),
        Text(
          value == null ? '—' : '$value ms',
          style: ColituText.small.copyWith(color: ColituColors.muted),
        ),
      ],
    );
  }
}

class _GoButton extends StatelessWidget {
  const _GoButton({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 180),
    width: 40,
    height: 40,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: active ? ColituGradients.accent : null,
      color: active ? null : ColituColors.surface2,
      border: Border.all(
        color: active ? Colors.transparent : ColituColors.lineStrong,
      ),
    ),
    child: Icon(
      CupertinoIcons.chevron_right,
      size: 17,
      color: active ? ColituColors.onAccent : ColituColors.text,
    ),
  );
}

/// Small marks for the services a node opens. They are drawn here rather
/// than shipped as the companies' logo files.
class ColituServiceMark extends StatelessWidget {
  const ColituServiceMark(this.service, {super.key, this.size = 18});

  final String service;
  final double size;

  @override
  Widget build(BuildContext context) {
    switch (service) {
      case 'netflix':
        return Center(
          child: Text(
            'N',
            style: TextStyle(
              fontFamily: ColituText.family,
              fontSize: size * 1.05,
              height: 1,
              fontWeight: FontWeight.w900,
              color: const Color(0xFFE50914),
            ),
          ),
        );
      case 'claude':
        return Center(
          child: Text(
            'A\\',
            style: TextStyle(
              fontFamily: ColituText.family,
              fontSize: size * 0.92,
              height: 1,
              letterSpacing: -1.2,
              fontWeight: FontWeight.w800,
              color: ColituColors.text,
            ),
          ),
        );
      case 'gemini':
        return CustomPaint(size: Size.square(size), painter: _SparkPainter());
      case 'youtube_premium':
        return CustomPaint(size: Size.square(size), painter: _PlayPainter());
      case 'chatgpt':
        return CustomPaint(size: Size.square(size), painter: _KnotPainter());
      default:
        return Icon(
          CupertinoIcons.checkmark_seal,
          size: size,
          color: ColituColors.text,
        );
    }
  }
}

/// Four-point star with a blue-to-violet fill.
class _SparkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final c = Offset(w / 2, w / 2);
    final path = Path()
      ..moveTo(c.dx, 0)
      ..quadraticBezierTo(c.dx, c.dy, w, c.dy)
      ..quadraticBezierTo(c.dx, c.dy, c.dx, w)
      ..quadraticBezierTo(c.dx, c.dy, 0, c.dy)
      ..quadraticBezierTo(c.dx, c.dy, c.dx, 0)
      ..close();
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
        colors: [Color(0xFF4796E3), Color(0xFF9177C7)],
      ).createShader(Offset.zero & size);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Red rounded rectangle with a white play triangle.
class _PlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, w * 0.18, w, w * 0.64),
      Radius.circular(w * 0.18),
    );
    canvas.drawRRect(rect, Paint()..color = const Color(0xFFFF0033));
    final play = Path()
      ..moveTo(w * 0.40, w * 0.34)
      ..lineTo(w * 0.66, w * 0.5)
      ..lineTo(w * 0.40, w * 0.66)
      ..close();
    canvas.drawPath(play, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Six interlaced petals, the shape people know as the chat assistant mark.
class _KnotPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.09
      ..color = ColituColors.text;
    canvas.save();
    canvas.translate(w / 2, w / 2);
    for (var i = 0; i < 6; i++) {
      canvas.save();
      canvas.rotate(i * math.pi / 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(0, -w * 0.16),
            width: w * 0.30,
            height: w * 0.56,
          ),
          Radius.circular(w * 0.15),
        ),
        paint,
      );
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
