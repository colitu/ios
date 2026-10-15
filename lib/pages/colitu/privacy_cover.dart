import 'package:flutter/widgets.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';

/// Covers the app with the brand screen while it is not in the foreground,
/// so the app switcher snapshot iOS takes never shows an e-mail address, a
/// sign-in or verification code, a device link code or account details.
class ColituPrivacyCover extends StatefulWidget {
  const ColituPrivacyCover({super.key, required this.child});

  final Widget child;

  /// Whether the cover shows in [state].
  static bool coversIn(AppLifecycleState state) =>
      state != AppLifecycleState.resumed;

  @override
  State<ColituPrivacyCover> createState() => _ColituPrivacyCoverState();
}

class _ColituPrivacyCoverState extends State<ColituPrivacyCover>
    with WidgetsBindingObserver {
  var _covered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final covered = ColituPrivacyCover.coversIn(state);
    if (covered != _covered) setState(() => _covered = covered);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      textDirection: TextDirection.ltr,
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_covered)
          const ColoredBox(
            key: ValueKey('colituPrivacyCover'),
            color: ColituColors.bg,
            child: Center(child: ColituWordmark(height: 22)),
          ),
      ],
    );
  }
}
