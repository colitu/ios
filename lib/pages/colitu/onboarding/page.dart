import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/colitu/theme/particles.dart';
import 'package:colitu_vpn/core/constants/preferences.dart';
import 'package:colitu_vpn/pages/main/url.dart';

/// First-launch tour: four slides that show what Colitu does and how to use
/// it, each with a live 3D hero. Ends on sign-up / sign-in. With [replay] it
/// is opened from the account page and simply closes at the end.
class ColituOnboardingPage extends StatefulWidget {
  const ColituOnboardingPage({super.key, this.replay = false});

  final bool replay;

  @override
  State<ColituOnboardingPage> createState() => _ColituOnboardingPageState();
}

class _ColituOnboardingPageState extends State<ColituOnboardingPage> {
  final _pages = PageController();
  var _index = 0;

  static const _count = 4;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _finish({required bool register}) async {
    await PreferencesKey().saveColituOnboardingSeen(true);
    if (!mounted) return;
    if (widget.replay) {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(RouterPath.home);
      }
      return;
    }
    context.go(
      register ? '${RouterPath.colituAuth}?mode=register' : RouterPath.colituAuth,
    );
  }

  void _next() {
    if (_index >= _count - 1) return;
    _pages.nextPage(
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ColituLoc.I,
      builder: (context, _) {
        final loc = ColituLoc.I;
        final last = _index == _count - 1;
        return ColituScaffold(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            children: [
              Row(
                children: [
                  const Expanded(child: ColituWordmark(height: 14)),
                  SizedBox(
                    width: 132,
                    child: ColituSegment<String>(
                      values: ColituLoc.languages,
                      selected: loc.language,
                      onChanged: (value) => ColituLoc.I.setLanguage(value),
                      labelOf: (value) => value.toUpperCase(),
                      height: 34,
                    ),
                  ),
                ],
              ),
              Expanded(
                child: PageView(
                  controller: _pages,
                  onPageChanged: (index) => setState(() => _index = index),
                  children: [
                    for (var i = 0; i < _count; i++)
                      _Slide(index: i, active: _index == i),
                  ],
                ),
              ),
              _Dots(count: _count, index: _index),
              const SizedBox(height: 22),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                child: last
                    ? Column(
                        key: const ValueKey('last'),
                        children: [
                          if (widget.replay)
                            ColituButton(
                              label: loc['onb.start'],
                              onPressed: () => _finish(register: false),
                            )
                          else ...[
                            ColituButton(
                              label: loc['onb.create'],
                              onPressed: () => _finish(register: true),
                            ),
                            const SizedBox(height: 10),
                            ColituButton.secondary(
                              label: loc['onb.signIn'],
                              onPressed: () => _finish(register: false),
                            ),
                          ],
                        ],
                      )
                    : Row(
                        key: const ValueKey('more'),
                        children: [
                          Expanded(
                            child: ColituButton.secondary(
                              label: loc['onb.skip'],
                              onPressed: () => _finish(register: false),
                              height: 56,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: ColituButton(
                              label: loc['onb.next'],
                              icon: CupertinoIcons.arrow_right,
                              onPressed: _next,
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Slide extends StatelessWidget {
  const _Slide({required this.index, required this.active});

  final int index;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final n = index + 1;
    final hero = switch (index) {
      0 => const ColituParticles(mode: ColituParticleMode.sphere, size: 250, energy: 0.55),
      1 => ColituPowerButton(
        state: ColituPowerState.on,
        size: 250,
        child: const Icon(CupertinoIcons.checkmark_alt, size: 42, color: Colors.white),
      ),
      2 => const _FlagsHero(),
      _ => const ColituParticles(mode: ColituParticleMode.gem, size: 250, energy: 0.6),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(height: 270, child: Center(child: hero)),
          const SizedBox(height: 14),
          if (index == 0) ...[
            _Pill(text: loc['onb.badge']),
            const SizedBox(height: 14),
          ],
          Text(
            loc['onb.$n.title'],
            textAlign: TextAlign.center,
            style: ColituText.display.copyWith(fontSize: 30),
          ),
          const SizedBox(height: 12),
          Text(
            loc['onb.$n.sub'],
            textAlign: TextAlign.center,
            style: ColituText.muted.copyWith(fontSize: 15.5),
          ),
        ],
      ),
    );
  }
}

/// Globe with a few country flags orbiting it (the "pick a location" slide).
class _FlagsHero extends StatelessWidget {
  const _FlagsHero();

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 250,
      child: Stack(
        alignment: Alignment.center,
        children: [
          const ColituParticles(mode: ColituParticleMode.sphere, size: 250, energy: 0.45),
          for (final (flag, dx, dy) in const [
            ('EE', -0.78, -0.55),
            ('DE', 0.82, -0.35),
            ('NL', -0.7, 0.55),
            ('US', 0.72, 0.6),
            ('TR', 0.05, -0.92),
          ])
            Align(
              alignment: Alignment(dx, dy),
              child: ColituFlag(flag, size: 40),
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 7, 12, 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ColituRadius.pill),
        border: Border.all(color: const Color(0x669F8CFF)),
        color: const Color(0x149F8CFF),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: ColituText.small.copyWith(
              color: ColituColors.lilac,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          const Icon(CupertinoIcons.arrow_up_right, size: 13, color: ColituColors.lilac),
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == index ? 24 : 7,
            height: 7,
            decoration: BoxDecoration(
              gradient: i == index ? ColituGradients.accent : null,
              color: i == index ? null : ColituColors.lineStrong,
              borderRadius: BorderRadius.circular(ColituRadius.pill),
            ),
          ),
      ],
    );
  }
}
