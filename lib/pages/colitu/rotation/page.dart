import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/api/models/multihop_models.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_errors.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';

/// Rotating exit IP: off / 5 / 10 / 30 minutes and the countries the exit
/// may be in. Russia is listed unchecked until the user ticks it; fewer than
/// two countries is refused here the way the panel would refuse it.
class ColituRotationPage extends StatefulWidget {
  const ColituRotationPage({super.key, required this.controller});

  final ColituConnectionController controller;

  /// Opens the page over the shell (from Account).
  static Future<void> open(
    BuildContext context,
    ColituConnectionController controller,
  ) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ColituRotationPage(controller: controller),
      ),
    );
  }

  /// "Off" or "Every 10 min": the row hint in Account.
  static String summary(RotationPreference? preference) {
    final loc = ColituLoc.I;
    if (preference == null || !preference.active) return loc['rotation.off'];
    return loc.format('rotation.rowOn', {'n': preference.intervalSeconds ~/ 60});
  }

  @override
  State<ColituRotationPage> createState() => _ColituRotationPageState();
}

class _ColituRotationPageState extends State<ColituRotationPage> {
  /// The checklist while it is not valid (and so not saved) yet.
  List<String>? _draft;
  String? _error;
  var _saving = false;
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    // Known already (loaded with the account): no request while it opens.
    if (widget.controller.rotation == null) {
      unawaited(_refresh());
    } else {
      _loaded = true;
    }
  }

  Future<void> _refresh() async {
    await widget.controller.refreshRotation();
    if (mounted) setState(() => _loaded = true);
  }

  /// Saves the interval and countries. Fewer than two countries is refused
  /// here the way the panel would (INVALID_PREFERENCE) and stays in the
  /// checklist until it is fixed.
  Future<void> _save(int seconds, List<String> selected) async {
    final c = widget.controller;
    final preference = c.rotation;
    if (preference == null || _saving) return;
    final loc = ColituLoc.I;
    if (ColituRotation.validate(seconds, selected, preference.availableCountries) !=
        RotationValidation.ok) {
      setState(() {
        _draft = selected;
        _error = loc['rotation.err.few'];
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // Off keeps the countries already stored; the default set is sent as
      // an empty list.
      final countries = seconds == 0
          ? preference.countries
          : ColituRotation.payloadCountries(selected, preference.availableCountries);
      await c.saveRotation(seconds, countries);
      _draft = null;
    } on APIException catch (e) {
      _draft = selected;
      _error = e.backendCode == 'INVALID_PREFERENCE'
          ? loc['rotation.err.few']
          : colituErrorMessage(e);
    } catch (e) {
      _draft = selected;
      _error = colituErrorMessage(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
    final preference = c.rotation;
    final selected = _draft ??
        (preference == null ? const <String>[] : ColituRotation.selectedCountries(preference));
    final countries = [
      for (final item in preference?.availableCountries ?? const <RotationCountry>[])
        if (item.exits > 0) item.country,
    ]..sort((a, b) => loc.countryName(a).compareTo(loc.countryName(b)));
    final intervals = [
      for (final seconds in ColituRotation.intervalChoices)
        if (seconds == 0 ||
            (preference?.intervals.isEmpty ?? true) ||
            preference!.intervals.contains(seconds))
          seconds,
    ];
    return ColituScaffold(
      padding: EdgeInsets.zero,
      child: RefreshIndicator(
        color: ColituColors.lilac,
        onRefresh: _refresh,
        child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
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
            kicker: loc['rotation.kicker'],
            title: loc['rotation.title'],
            subtitle: loc['rotation.hint'],
          ),
          const SizedBox(height: 18),
          if (preference == null) ...[
            if (_loaded) ColituNotice(loc['rotation.unavailable']),
          ] else ...[
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                loc['rotation.every'],
                style: ColituText.label.copyWith(color: ColituColors.muted),
              ),
            ),
            for (final seconds in intervals) ...[
              _OptionTile(
                key: ValueKey('rotationInterval.$seconds'),
                title: seconds == 0
                    ? loc['rotation.off']
                    : loc.format('rotation.minutes', {'n': seconds ~/ 60}),
                selected: seconds == preference.intervalSeconds,
                onTap: () {
                  if (seconds != preference.intervalSeconds) {
                    unawaited(_save(seconds, selected));
                  }
                },
              ),
              const SizedBox(height: 8),
            ],
            if (preference.active) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Text(
                  loc['rotation.countries'],
                  style: ColituText.label.copyWith(color: ColituColors.muted),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 10),
                child: Text(loc['rotation.countriesHint'], style: ColituText.small),
              ),
              for (final code in countries) ...[
                _OptionTile(
                  key: ValueKey('rotationCountry.$code'),
                  leading: ColituFlag(code, size: 30),
                  title: loc.countryName(code),
                  selected: selected.contains(code),
                  checkbox: true,
                  onTap: () {
                    final next = selected.contains(code)
                        ? [...selected.where((value) => value != code)]
                        : [...selected, code];
                    unawaited(_save(preference.intervalSeconds, next));
                  },
                ),
                const SizedBox(height: 6),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              ColituNotice(_error!),
            ],
          ],
        ],
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.leading,
    this.checkbox = false,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;
  final Widget? leading;

  /// A square tick (several can be on) instead of a round radio mark.
  final bool checkbox;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: ColituTile(
        active: selected,
        onTap: onTap,
        padding: EdgeInsets.fromLTRB(14, leading == null ? 14 : 9, 14, leading == null ? 14 : 9),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 12)],
            Expanded(child: Text(title, style: ColituText.label)),
            const SizedBox(width: 10),
            Icon(
              checkbox
                  ? (selected
                        ? CupertinoIcons.checkmark_square_fill
                        : CupertinoIcons.square)
                  : (selected
                        ? CupertinoIcons.checkmark_circle_fill
                        : CupertinoIcons.circle),
              size: 22,
              color: selected ? ColituColors.lilac : ColituColors.dim,
            ),
          ],
        ),
      ),
    );
  }
}
