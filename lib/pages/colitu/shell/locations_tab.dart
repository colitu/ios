import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:colitu_vpn/colitu/l10n/server_names.dart';
import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/colitu_ad_block.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/services/server_groups.dart';
import 'package:colitu_vpn/colitu/services/server_shortcuts.dart';
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

  /// The category filter in use; Simple mode always shows all.
  String get _activeFilter => widget.controller.advancedMode ? _filter : 'all';
  var _sort = _Sort.ping;

  /// Countries the user opened or closed by hand (country code -> open).
  /// Without an entry a country is open when it holds the selected server.
  final _expanded = <String, bool>{};

  /// Pings were paused (VPN on) at the last controller change.
  late bool _pingsWerePaused;
  Timer? _pingResume;

  /// After the tunnel goes down, measuring waits this long so the system
  /// has removed its routes and the probes take the direct path.
  static const pingResumeDelay = Duration(milliseconds: 1500);

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _shortcuts.addListener(_onShortcuts);
    unawaited(_shortcuts.load());
    _pingsWerePaused = widget.controller.pingsPaused;
    widget.controller.addListener(_onController);
    unawaited(widget.controller.measurePings());
  }

  @override
  void didUpdateWidget(LocationsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
      _pingsWerePaused = widget.controller.pingsPaused;
    }
  }

  /// The VPN went off: measuring picks up again.
  void _onController() {
    final paused = widget.controller.pingsPaused;
    if (_pingsWerePaused && !paused) {
      _pingResume?.cancel();
      _pingResume = Timer(pingResumeDelay, () {
        if (mounted) unawaited(widget.controller.measurePings());
      });
    } else if (paused) {
      _pingResume?.cancel();
    }
    _pingsWerePaused = paused;
  }

  final _shortcuts = ColituServerShortcuts.instance;

  void _onShortcuts() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pingResume?.cancel();
    _shortcuts.removeListener(_onShortcuts);
    widget.controller.removeListener(_onController);
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
      if (!server.inCategory(_activeFilter)) return false;
      if (query.isEmpty) return true;
      final haystack = _fold(
        '${c.titleOf(server)} ${serverCityLabel(server)} ${server.displayTitle} ${server.displayCountry} ${server.city ?? ''} ${server.countryCode}',
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
    // Simple mode lists no multihop routes.
    if (!widget.controller.advancedMode || _activeFilter != 'all') {
      return const [];
    }
    final query = _fold(_search.text.trim());
    return [
      for (final route in widget.controller.multihopServers)
        if (query.isEmpty ||
            _fold(
              '${route.name} ${ColituServerNames.route(route.name)} ${route.entry?.label ?? ''} ${route.exit?.label ?? ''} ${route.entry?.country ?? ''} ${route.exit?.country ?? ''}',
            ).contains(query))
          route,
    ];
  }

  /// The top of the automatic ranking among the shown servers: with the
  /// whole list on screen it is exactly what "Fastest server" connects to.
  /// It stays listed in its place below as well.
  List<VPNServer> _recommended(List<VPNServer> items) {
    final shown = items.toSet();
    final best = widget.controller.rankedServers
        .where(shown.contains)
        .firstOrNull;
    return best == null ? const [] : [best];
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
    final rest = items;
    final routes = _routes();
    final searching = _search.text.trim().isNotEmpty;
    final selectedKey = c.autoSelection ? null : c.selectedServer?.selectionKey;
    // Favourites and recent servers (device only); a server that left the
    // list is not shown. A search shows only the matches.
    final known = [...c.servers, ...c.multihopServers];
    final favorites = searching
        ? const <VPNServer>[]
        : _shortcuts.favorites(known);
    final recents = searching
        ? const <VPNServer>[]
        : _shortcuts
              .recents(known)
              .where(
                (s) => !favorites.any((f) => f.selectionKey == s.selectionKey),
              )
              .toList();
    Widget shortcutCard(VPNServer server) => Padding(
      key: ValueKey('shortcut.${server.selectionKey}'),
      padding: const EdgeInsets.only(bottom: _cardGap),
      child: server.isMultihop
          ? _RouteCard(controller: c, route: server)
          : _ServerCard(controller: c, server: server),
    );
    // A search lists the matches flat; otherwise a country with several
    // servers becomes one expandable group.
    final groups = groupServersByCountry(rest, flat: searching);
    var index = 0;
    // The first rows fade in one after another; later ones share the last
    // delay so a long list never waits.
    Duration nextDelay() => _staggerStep * math.min(index++, _staggerRows);

    Widget card(VPNServer server, {bool recommended = false}) => Padding(
      padding: const EdgeInsets.only(bottom: _cardGap),
      child: _Reveal(
        delay: nextDelay(),
        child: _ServerCard(
          controller: c,
          server: server,
          recommended: recommended,
        ),
      ),
    );

    Widget groupCard(ServerGroup group) {
      final delay = nextDelay();
      final open = isGroupExpanded(
        group,
        selectedKey: selectedKey,
        overrides: _expanded,
      );
      return Padding(
        key: ValueKey('group.${group.key}'),
        padding: const EdgeInsets.only(bottom: _cardGap),
        child: _Reveal(
          delay: delay,
          child: _CountryGroup(
            controller: c,
            group: group,
            expanded: open,
            onToggle: () => setState(() => _expanded[group.key] = !open),
          ),
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
        const SizedBox(height: 6),
        Text(loc['locations.tagline'], style: ColituText.muted),
        const SizedBox(height: 20),
        Semantics(
          label: loc['locations.searchLabel'],
          child: TextField(
            key: const ValueKey('locationsSearch'),
            controller: _search,
            style: ColituText.body.copyWith(fontSize: 16, height: 1.25),
            cursorColor: ColituColors.lilac,
            decoration: InputDecoration(
              constraints: const BoxConstraints(minHeight: _fieldHeight),
              hintText: '${loc['locations.search']}…',
              // Muted rather than dim: the hint keeps a 4.5:1 contrast.
              hintStyle: ColituText.body.copyWith(
                color: ColituColors.muted,
                fontSize: 16,
                height: 1.25,
              ),
              prefixIcon: const Padding(
                padding: EdgeInsets.only(left: 18, right: 10),
                child: Icon(
                  CupertinoIcons.search,
                  size: 20,
                  color: ColituColors.muted,
                ),
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 48),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: loc['locations.clearSearch'],
                      onPressed: _search.clear,
                      icon: const Icon(
                        CupertinoIcons.xmark_circle_fill,
                        size: 18,
                        color: ColituColors.muted,
                      ),
                    ),
              filled: true,
              fillColor: ColituColors.surface,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 16,
              ),
              border: _border(ColituColors.line),
              enabledBorder: _border(ColituColors.line),
              focusedBorder: _border(_selectedBorder),
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (favorites.isNotEmpty) ...[
          _SectionHeader(title: loc['locations.favorites']),
          const SizedBox(height: 12),
          for (final server in favorites) shortcutCard(server),
          const SizedBox(height: 14),
        ],
        if (recents.isNotEmpty) ...[
          _SectionHeader(title: loc['locations.recents']),
          const SizedBox(height: 12),
          for (final server in recents) shortcutCard(server),
          const SizedBox(height: 14),
        ],
        // Simple mode: no category filters.
        if (c.advancedMode) ...[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: Row(
              children: [
                for (final filter in _filters)
                  if (filter == 'all' ||
                      filter == _filter ||
                      c.servers.any((s) => s.inCategory(filter))) ...[
                    _FilterChip(
                      label: filter == 'all'
                          ? loc['locations.all']
                          : loc['cat.$filter'],
                      icon: _categoryIcon(filter),
                      selected: _filter == filter,
                      onTap: () => setState(() => _filter = filter),
                    ),
                    const SizedBox(width: 10),
                  ],
              ],
            ),
          ),
          const SizedBox(height: 26),
        ] else
          const SizedBox(height: 12),
        if (!c.planActive && widget.onOpenPlan != null) ...[
          ColituPanel(
            onTap: widget.onOpenPlan,
            padding: _cardPadding,
            radius: _cardRadius,
            child: Row(
              children: [
                const ColituRoundIcon(
                  CupertinoIcons.globe,
                  size: _flagSize,
                  accent: true,
                ),
                const SizedBox(width: 14),
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
                const SizedBox(width: 10),
                const Icon(
                  CupertinoIcons.chevron_right,
                  size: 16,
                  color: ColituColors.muted,
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
        ],
        if (c.servers.isEmpty)
          _Empty(c.planRequired ? loc['plan.noneHint'] : loc['server.none'])
        else if (items.isEmpty)
          _Empty(
            _activeFilter != 'all' && _search.text.trim().isEmpty
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
          if (c.pingsPaused) ...[
            const SizedBox(height: 4),
            const _PingCachedHint(),
          ],
          const SizedBox(height: 12),
          for (final server in recommended) card(server, recommended: true),
          if (recommended.isNotEmpty && rest.isNotEmpty) ...[
            const SizedBox(height: 14),
            _SectionHeader(title: loc['locations.allServers']),
            const SizedBox(height: 12),
          ],
          for (final group in groups)
            if (group.isSingle) card(group.servers.first) else groupCard(group),
        ],
        if (routes.isNotEmpty) ...[
          const SizedBox(height: 14),
          _SectionHeader(title: loc['multihop.section']),
          const SizedBox(height: 6),
          Text(loc['multihop.sectionHint'], style: ColituText.small),
          const SizedBox(height: 12),
          for (final route in routes)
            Padding(
              padding: const EdgeInsets.only(bottom: _cardGap),
              child: _RouteCard(controller: c, route: route),
            ),
        ],
        // Room so the floating navigation bar never covers the last row.
        const SizedBox(height: 24),
      ],
    );
  }

  OutlineInputBorder _border(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(_fieldRadius),
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

// ── Metrics and motion ─────────────────────────────────────────────────────
// The Android list uses the same numbers; keep the two in step.

const _cardRadius = 24.0;
const _cardPadding = EdgeInsets.symmetric(horizontal: 20, vertical: 16);
const _cardGap = 12.0;
const _rowMinHeight = 76.0;
const _flagSize = 44.0;
const _flagGap = 14.0;
const _fieldHeight = 52.0;
const _fieldRadius = 18.0;

const _nameStyle = TextStyle(
  fontFamily: ColituText.family,
  fontSize: 17,
  fontWeight: FontWeight.w600,
  letterSpacing: -0.2,
  color: ColituColors.text,
  height: 1.25,
);
const _subStyle = TextStyle(
  fontFamily: ColituText.family,
  fontSize: 14,
  fontWeight: FontWeight.w400,
  color: ColituColors.muted,
  height: 1.3,
);
final _connectedStyle = _subStyle.copyWith(
  color: ColituColors.lilac,
  fontWeight: FontWeight.w600,
);
const _kickerStyle = TextStyle(
  fontFamily: ColituText.family,
  fontSize: 12,
  fontWeight: FontWeight.w600,
  letterSpacing: 1.9,
  color: ColituColors.muted,
  height: 1.2,
);

/// Border of the selected or connected row: a soft violet line, no fill.
const _selectedBorder = Color(0x999F8CFF);

/// Border of the recommended card: the accent-on-dark violet, kept faint.
const _recommendedBorder = Color(0x4D9B8CFF);

const _expandDuration = Duration(milliseconds: 250);
const _borderDuration = Duration(milliseconds: 220);
const _staggerStep = Duration(milliseconds: 35);
const _staggerRows = 8;

/// True when the system asks for reduced motion.
bool _still(BuildContext context) => MediaQuery.disableAnimationsOf(context);

Duration _motion(BuildContext context, Duration duration) =>
    _still(context) ? Duration.zero : duration;

/// Upper case that keeps the Turkish dotted capital İ.
String _upper(String text) => ColituLoc.I.language == 'tr'
    ? text.replaceAll('i', 'İ').toUpperCase()
    : text.toUpperCase();

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

/// Quiet small-caps section label with an optional control on the right.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            _upper(title),
            style: _kickerStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// While the VPN is on no ping is measured (it would run through the
/// tunnel); a quiet line says the numbers are the last direct readings.
class _PingCachedHint extends StatelessWidget {
  const _PingCachedHint();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Row(
      children: [
        const Icon(CupertinoIcons.clock, size: 13, color: ColituColors.muted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            ColituLoc.I['locations.pingCached'],
            style: ColituText.small,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

/// Fades a row in and lifts it a few points; skipped under reduced motion.
class _Reveal extends StatefulWidget {
  const _Reveal({required this.child, this.delay = Duration.zero});

  final Widget child;
  final Duration delay;

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );
  late final _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_still(context)) {
      _timer?.cancel();
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_still(context)) return widget.child;
    return AnimatedBuilder(
      animation: _curve,
      builder: (context, child) => Opacity(
        opacity: _curve.value,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - _curve.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// Shrinks to 0.98 while pressed and springs back on release.
class _PressScale extends StatelessWidget {
  const _PressScale({required this.pressed, required this.child});

  final bool pressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (_still(context)) return child;
    return AnimatedScale(
      scale: pressed ? 0.98 : 1,
      duration: Duration(milliseconds: pressed ? 110 : 320),
      curve: pressed ? Curves.easeOut : Curves.easeOutBack,
      child: child,
    );
  }
}

/// A tappable surface with the press scale.
class _Press extends StatefulWidget {
  const _Press({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_Press> createState() => _PressState();
}

class _PressState extends State<_Press> {
  var _down = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onTap == null) return widget.child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: _PressScale(pressed: _down, child: widget.child),
    );
  }
}

enum _Edge { plain, recommended, selected }

/// The row card: dark surface, 24 radius, a hairline that turns violet
/// (animated) when the row is chosen.
class _Card extends StatelessWidget {
  const _Card({
    required this.child,
    this.edge = _Edge.plain,
    this.padding = _cardPadding,
  });

  final Widget child;
  final _Edge edge;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: _motion(context, _borderDuration),
    curve: Curves.easeOutCubic,
    padding: padding,
    decoration: BoxDecoration(
      color: ColituColors.surface,
      borderRadius: BorderRadius.circular(_cardRadius),
      border: Border.all(
        color: switch (edge) {
          _Edge.selected => _selectedBorder,
          _Edge.recommended => _recommendedBorder,
          _Edge.plain => ColituColors.line,
        },
        width: edge == _Edge.selected ? 1.5 : 1,
      ),
    ),
    child: child,
  );
}

/// Flag, title and one secondary line; [trailing] sits on the right.
class _RowBody extends StatelessWidget {
  const _RowBody({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.connected = false,
    this.badge,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final List<Widget> trailing;
  final bool connected;
  final Widget? badge;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      minHeight: _rowMinHeight - _cardPadding.vertical,
    ),
    child: Row(
      children: [
        leading,
        const SizedBox(width: _flagGap),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      style: _nameStyle,
                      // Large text wraps to a second line before it is cut.
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (badge != null) ...[const SizedBox(width: 8), badge!],
                ],
              ),
              if (connected || subtitle.isNotEmpty) ...[
                const SizedBox(height: 3),
                _SubLine(subtitle, connected: connected),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        ...trailing,
      ],
    ),
  );
}

/// The muted second line; "Connected" in violet goes first when it applies.
class _SubLine extends StatelessWidget {
  const _SubLine(this.text, {this.connected = false});

  final String text;
  final bool connected;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (connected) ...[
        Text(ColituLoc.I['server.connected'], style: _connectedStyle),
        if (text.isNotEmpty) const Text(' · ', style: _subStyle),
      ],
      if (text.isNotEmpty)
        Flexible(
          child: Text(
            text,
            style: _subStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ],
  );
}

/// "Fastest server" in the title row: picks the server automatically.
class _FastestButton extends StatelessWidget {
  const _FastestButton({required this.controller});

  final ColituConnectionController controller;

  @override
  Widget build(BuildContext context) {
    final active = controller.automaticTarget;
    return _Press(
      onTap: controller.selectAuto,
      child: AnimatedContainer(
        duration: _motion(context, _borderDuration),
        curve: Curves.easeOutCubic,
        height: 44,
        padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
        decoration: BoxDecoration(
          color: ColituColors.surface,
          borderRadius: BorderRadius.circular(ColituRadius.pill),
          border: Border.all(
            color: active ? _selectedBorder : ColituColors.lineStrong,
            width: active ? 1.5 : 1,
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

/// Category filter: calm pill, violet outline when chosen.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) => _Press(
    onTap: onTap,
    child: AnimatedContainer(
      duration: _motion(context, _borderDuration),
      curve: Curves.easeOutCubic,
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: selected ? const Color(0x1F9F8CFF) : ColituColors.surface,
        borderRadius: BorderRadius.circular(_fieldRadius),
        border: Border.all(
          color: selected ? _selectedBorder : ColituColors.line,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 18,
            color: selected ? ColituColors.lilac : ColituColors.muted,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: ColituText.label.copyWith(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: ColituColors.text,
            ),
          ),
        ],
      ),
    ),
  );
}

class _SortButton extends StatelessWidget {
  const _SortButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _Press(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
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
            style: ColituText.small.copyWith(
              fontSize: 13,
              color: ColituColors.text,
            ),
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
  const _ServerCard({
    required this.controller,
    required this.server,
    this.recommended = false,
  });

  final ColituConnectionController controller;
  final VPNServer server;
  final bool recommended;

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
        : ColituServerNames.displayName(server.displayCountry);
    final title = country.isEmpty
        ? ColituServerNames.displayName(server.displayTitle, countryCode: code)
        : country;
    final city = ColituServerNames.city(server.city);
    final subtitle =
        city.isNotEmpty && city.toLowerCase() != title.toLowerCase()
        ? city
        : '';
    return Opacity(
      opacity: selectable ? 1 : 0.5,
      child: _Press(
        onTap: selectable ? () => c.selectServer(server) : null,
        child: _Card(
          edge: selected || connected
              ? _Edge.selected
              : recommended
              ? _Edge.recommended
              : _Edge.plain,
          child: _RowBody(
            leading: ColituFlag(code, size: _flagSize),
            title: title,
            subtitle: subtitle,
            connected: connected,
            badge: _badgeFor(server),
            trailing: [
              if (selectable && !c.pingFailed(server))
                _Ping(c.pingOf(server))
              else
                const _Unreachable(),
              const SizedBox(width: 2),
              _StarButton(server: server),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Unreachable": the server is down or did not answer the last probe.
class _Unreachable extends StatelessWidget {
  const _Unreachable();

  @override
  Widget build(BuildContext context) => Text(
    ColituLoc.I['server.unreachable'],
    key: const ValueKey('unreachable'),
    style: ColituText.small,
  );
}

/// Star that adds a server to the favourites (kept on this device). The
/// tap target is 44 x 44 points.
class _StarButton extends StatelessWidget {
  const _StarButton({required this.server});

  final VPNServer server;

  @override
  Widget build(BuildContext context) {
    final shortcuts = ColituServerShortcuts.instance;
    final on = shortcuts.isFavorite(server);
    return Semantics(
      button: true,
      toggled: on,
      label: ColituLoc.I[on ? 'fav.remove' : 'fav.add'],
      excludeSemantics: true,
      onTap: () => unawaited(shortcuts.toggleFavorite(server)),
      child: GestureDetector(
        key: ValueKey('star.${server.selectionKey}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(shortcuts.toggleFavorite(server)),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Icon(
              on ? CupertinoIcons.star_fill : CupertinoIcons.star,
              size: 20,
              color: on ? ColituColors.warning : ColituColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}

/// The one small badge a row may carry: PRO first, else ad-free YouTube or
/// the ad blocker when the node has them.
Widget? _badgeFor(VPNServer server) {
  if (server.isPremium) return const _PremiumBadge();
  if (server.services.contains('youtube_adfree')) {
    return const _MiniBadge(
      mark: ColituServiceMark('youtube_adfree', size: 12),
    );
  }
  if (ColituAdBlock.hostsDns(server.host)) {
    return const _MiniBadge(
      mark: Icon(CupertinoIcons.eye_slash, size: 12, color: ColituColors.muted),
    );
  }
  return null;
}

/// Premium server: a small star (read as "Premium") so the name keeps its
/// room.
class _PremiumBadge extends StatelessWidget {
  const _PremiumBadge();

  @override
  Widget build(BuildContext context) => Semantics(
    label: ColituLoc.I['plan.premiumBadge'],
    excludeSemantics: true,
    child: const _MiniBadge(
      key: ValueKey('premiumBadge'),
      mark: Icon(CupertinoIcons.star_fill, size: 12, color: ColituColors.lilac),
    ),
  );
}

/// Icon-only round badge so the country name keeps its room.
class _MiniBadge extends StatelessWidget {
  const _MiniBadge({super.key, required this.mark});

  final Widget mark;

  @override
  Widget build(BuildContext context) => Container(
    width: 22,
    height: 22,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: ColituColors.surface2,
      shape: BoxShape.circle,
      border: Border.all(color: ColituColors.line),
    ),
    child: SizedBox(width: 12, height: 12, child: mark),
  );
}

/// Localized service name when the strings have one, else the brand name.
String _serviceLabel(String key, String fallback) {
  final text = ColituLoc.I['service.$key'];
  return text == 'service.$key' ? fallback : text;
}

/// Services the panel verified on this node first, then the use cases they
/// do not already cover.
List<_Tag> _tagsOf(VPNServer server) {
  final out = <_Tag>[
    if (ColituAdBlock.hostsDns(server.host))
      _Tag(ColituLoc.I['cat.adblock'], category: 'adblock'),
    for (final entry in VPNServer.serviceNames.entries)
      if (server.services.contains(entry.key))
        _Tag(_serviceLabel(entry.key, entry.value), service: entry.key),
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

/// A country with several servers: one card whose header (flag, country,
/// how many locations, best ping) opens and closes the city rows inside it.
class _CountryGroup extends StatefulWidget {
  const _CountryGroup({
    required this.controller,
    required this.group,
    required this.expanded,
    required this.onToggle,
  });

  final ColituConnectionController controller;
  final ServerGroup group;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  State<_CountryGroup> createState() => _CountryGroupState();
}

class _CountryGroupState extends State<_CountryGroup> {
  var _down = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final c = widget.controller;
    final group = widget.group;
    final expanded = widget.expanded;
    final first = group.servers.first;
    final code = first.countryCode;
    final country = code.length == 2
        ? loc.countryName(code)
        : ColituServerNames.displayName(first.displayCountry);
    final selectedKey = c.autoSelection ? null : c.selectedServer?.selectionKey;
    final connectedKey = c.connected ? c.connectedServer?.selectionKey : null;
    final hasSelected = group.contains(selectedKey);
    final hasConnected = group.contains(connectedKey);
    final anySelectable = group.servers.any((s) => s.isSelectable);
    return _PressScale(
      pressed: _down,
      child: _Card(
        // Open, the chosen city carries the outline instead of the card.
        edge: !expanded && (hasSelected || hasConnected)
            ? _Edge.selected
            : _Edge.plain,
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            Semantics(
              button: true,
              expanded: expanded,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) => _set(true),
                onTapUp: (_) => _set(false),
                onTapCancel: () => _set(false),
                onTap: widget.onToggle,
                child: Opacity(
                  opacity: anySelectable ? 1 : 0.5,
                  child: Padding(
                    padding: _cardPadding,
                    child: _RowBody(
                      leading: ColituFlag(code, size: _flagSize),
                      title: country.isEmpty
                          ? ColituServerNames.displayName(
                              first.displayTitle,
                              countryCode: code,
                            )
                          : country,
                      subtitle: loc.count(
                        'locationCount',
                        group.servers.length,
                      ),
                      connected: !expanded && hasConnected,
                      trailing: [
                        if (anySelectable)
                          _Ping(group.bestPing(c.pingOf))
                        else
                          const _Unreachable(),
                        const SizedBox(width: 12),
                        AnimatedRotation(
                          turns: expanded ? 0.5 : 0,
                          duration: _motion(context, _expandDuration),
                          curve: Curves.easeOutCubic,
                          child: const Icon(
                            CupertinoIcons.chevron_down,
                            size: 16,
                            color: ColituColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            _Expandable(
              expanded: expanded,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(10, 0, 10, 6),
                      child: Divider(height: 1, color: ColituColors.line),
                    ),
                    for (final server in group.servers)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: _CityRow(controller: c, server: server),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens and closes its child with a size and fade animation (250 ms). The
/// child leaves the tree once it is fully closed.
class _Expandable extends StatefulWidget {
  const _Expandable({required this.expanded, required this.child});

  final bool expanded;
  final Widget child;

  @override
  State<_Expandable> createState() => _ExpandableState();
}

class _ExpandableState extends State<_Expandable>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: _expandDuration,
    value: widget.expanded ? 1 : 0,
  );
  late final _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void didUpdateWidget(covariant _Expandable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == oldWidget.expanded) return;
    if (_still(context)) {
      _controller.value = widget.expanded ? 1 : 0;
    } else if (widget.expanded) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, child) {
      if (!widget.expanded && _controller.value == 0) {
        return const SizedBox(width: double.infinity);
      }
      final t = _curve.value;
      return ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: t,
          child: Opacity(opacity: t, child: child),
        ),
      );
    },
    child: widget.child,
  );
}

/// One city inside an open country card: city, up to three service tags,
/// ping, and a check when it is the chosen one. Tapping selects it just like
/// a single server row.
class _CityRow extends StatelessWidget {
  const _CityRow({required this.controller, required this.server});

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
    final active = selected || connected;
    final selectable = server.isSelectable;
    final tags = _tagsOf(server);
    return Opacity(
      opacity: selectable ? 1 : 0.5,
      child: _Press(
        key: ValueKey('city.${server.selectionKey}'),
        onTap: selectable ? () => c.selectServer(server) : null,
        child: AnimatedContainer(
          duration: _motion(context, _borderDuration),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_fieldRadius),
            border: Border.all(
              color: active ? _selectedBorder : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            serverCityLabel(server),
                            style: _nameStyle.copyWith(fontSize: 15.5),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (connected) ...[
                          const SizedBox(width: 8),
                          Text(
                            loc['server.connected'],
                            style: _connectedStyle.copyWith(fontSize: 12.5),
                          ),
                        ] else if (server.isPremium) ...[
                          const SizedBox(width: 8),
                          const _PremiumBadge(),
                        ],
                      ],
                    ),
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _TagLine(tags),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (selectable && !c.pingFailed(server))
                _Ping(c.pingOf(server))
              else
                const _Unreachable(),
              const SizedBox(width: 8),
              SizedBox(
                width: 18,
                height: 18,
                child: AnimatedSwitcher(
                  duration: _motion(context, _borderDuration),
                  child: active
                      ? const Icon(
                          CupertinoIcons.checkmark_alt,
                          key: ValueKey('check'),
                          size: 17,
                          color: ColituColors.lilac,
                        )
                      : const SizedBox.shrink(),
                ),
              ),
              _StarButton(server: server),
            ],
          ),
        ),
      ),
    );
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
        !c.autoSelection &&
        c.selectedServer?.selectionKey == route.selectionKey;
    final connected =
        c.connected && c.connectedServer?.selectionKey == route.selectionKey;
    final selectable = route.isSelectable;
    return Opacity(
      opacity: selectable ? 1 : 0.5,
      child: _Press(
        key: ValueKey('route.${route.id}'),
        onTap: selectable ? () => c.selectServer(route) : null,
        child: _Card(
          edge: selected || connected ? _Edge.selected : _Edge.plain,
          child: _RowBody(
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ColituFlag(route.entry?.country ?? '', size: 32),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(
                    CupertinoIcons.arrow_right,
                    size: 13,
                    color: ColituColors.muted,
                  ),
                ),
                ColituFlag(route.exit?.country ?? '', size: 32),
              ],
            ),
            title: ColituServerNames.route(route.name),
            subtitle: selectable
                ? loc['multihop.ping']
                : loc['server.unreachable'],
            connected: connected,
            trailing: [
              if (selectable) _Ping(c.pingOf(route)),
              const SizedBox(width: 2),
              _StarButton(server: route),
            ],
          ),
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
  fontSize: 12,
  height: 1.2,
  fontWeight: FontWeight.w500,
  color: ColituColors.muted,
);
const _tagIcon = 13.0;
const _tagIconGap = 5.0;
const _tagSpacing = 12.0;

/// Tags an open city row may show; the rest stay hidden.
const _maxTags = 3;

/// Slack per tag so rounding never squeezes a label into an ellipsis.
const _tagSlack = 6.0;

/// One quiet line of at most three tags, as many as fit.
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
        var used = 0.0;
        var count = 0;
        for (var i = 0; i < tags.length && i < _maxTags; i++) {
          final width =
              _tagSlack +
              _tagIcon +
              _tagIconGap +
              _textWidth(tags[i].label, _tagStyle, scaler);
          final next = used + (i == 0 ? 0 : _tagSpacing) + width;
          if (next > max && i > 0) break;
          used = next;
          count = i + 1;
        }
        return Row(
          children: [
            for (var i = 0; i < count; i++) ...[
              if (i > 0) const SizedBox(width: _tagSpacing),
              Flexible(child: _TagView(tags[i])),
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
                  color: ColituColors.muted,
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

/// Signal bars and the ping in milliseconds, in calm tones; a new value
/// cross-fades in.
class _Ping extends StatelessWidget {
  const _Ping(this.ms);

  final int? ms;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: _motion(context, const Duration(milliseconds: 220)),
    layoutBuilder: (current, previous) => Stack(
      alignment: Alignment.centerRight,
      children: [...previous, ?current],
    ),
    child: _PingView(ms, key: ValueKey(ms)),
  );
}

class _PingView extends StatelessWidget {
  const _PingView(this.ms, {super.key});

  final int? ms;

  @override
  Widget build(BuildContext context) {
    final value = ms;
    final color = value == null
        ? ColituColors.dim
        : value < 60
        ? ColituColors.success.withValues(alpha: 0.8)
        : value < 150
        ? ColituColors.warning.withValues(alpha: 0.8)
        : ColituColors.danger.withValues(alpha: 0.8);
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
            width: 3,
            height: 5.0 + i * 3,
            decoration: BoxDecoration(
              color: i < bars ? color : ColituColors.lineStrong,
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
          if (i < 3) const SizedBox(width: 2),
        ],
        const SizedBox(width: 7),
        Text(
          value == null ? '—' : '$value ms',
          style: ColituText.small.copyWith(
            fontSize: 13,
            color: ColituColors.muted,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
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
      case 'youtube_adfree':
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
