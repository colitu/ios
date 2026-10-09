import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_errors.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/app_session.dart';
import 'package:colitu_vpn/colitu/services/auth_service.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/main/url.dart';

/// Answers the second sign-in step: [submit] signs in with the code and
/// returns when the session is ready. Injected by tests.
typedef MfaSubmit = Future<void> Function(MfaChallenge challenge, String code);

/// Two-step sign-in: the six-digit code from the authenticator app, or a
/// recovery code. Two-step sign-in is set up on the website only.
class ColituMfaPage extends StatefulWidget {
  const ColituMfaPage({super.key, required this.challenge, this.submit});

  final MfaChallenge challenge;
  final MfaSubmit? submit;

  @override
  State<ColituMfaPage> createState() => _ColituMfaPageState();
}

class _ColituMfaPageState extends State<ColituMfaPage> {
  final _code = TextEditingController();
  var _recovery = false;
  var _loading = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  /// A pasted "123 456" or "123-456" counts as the six digits; a recovery
  /// code keeps its letters and dashes, without spaces.
  String get _normalized {
    final text = _code.text.trim();
    if (_recovery) return text.replaceAll(RegExp(r'\s'), '');
    return text.replaceAll(RegExp(r'\D'), '');
  }

  void _backToSignIn([String? message]) {
    context.go(RouterPath.colituAuth, extra: message);
  }

  Future<void> _submit() async {
    final loc = ColituLoc.I;
    if (_loading) return;
    final code = _normalized;
    if (!_recovery && code.length != 6) {
      setState(() => _error = loc['mfa.err.length']);
      return;
    }
    if (_recovery && code.length < 6) {
      setState(() => _error = loc['mfa.err.recovery']);
      return;
    }
    if (widget.challenge.expired) {
      _backToSignIn(loc['mfa.err.expired']);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final submit =
          widget.submit ??
          (challenge, code) async {
            await AppSession.instance.loginMfa(challenge, code);
          };
      await submit(widget.challenge, code);
      if (!mounted) return;
      context.go(RouterPath.home);
    } on APIException catch (error) {
      if (!mounted) return;
      switch (error.code) {
        case APIErrorCode.mfaTokenExpired:
          _backToSignIn(loc['mfa.err.expired']);
        case APIErrorCode.mfaUpdateRequired:
          _backToSignIn(loc['mfa.err.update']);
        case APIErrorCode.emailNotVerified:
          context.go(RouterPath.colituVerify, extra: true);
        case APIErrorCode.mfaInvalidCode:
          _code.clear();
          final left = error.details?['attempts_left'];
          setState(() {
            _error = left is num
                ? '${loc['mfa.err.invalid']} ${loc.format('mfa.attemptsLeft', {'n': left.toInt()})}'
                : loc['mfa.err.invalid'];
          });
        default:
          setState(() => _error = colituErrorMessage(error, signingIn: true));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = colituErrorMessage(error, signingIn: true));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _byEmail => widget.challenge.isEmail;

  void _toggleRecovery() {
    setState(() {
      _recovery = !_recovery;
      _error = null;
      _code.clear();
    });
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
    return ColituScaffold(
      padding: EdgeInsets.zero,
      resizeToAvoidBottomInset: true,
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: ColituWordmark(height: 14),
            ),
            const SizedBox(height: 36),
            const Center(
              child: ColituRoundIcon(CupertinoIcons.lock_shield, size: 72, accent: true),
            ),
            const SizedBox(height: 18),
            Center(child: ColituKicker(loc['mfa.kicker'], color: ColituColors.lilac)),
            const SizedBox(height: 12),
            Text(
              _byEmail ? loc['mfa.loginEmailTitle'] : loc['mfa.title'],
              textAlign: TextAlign.center,
              style: ColituText.display.copyWith(fontSize: 30),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                _byEmail
                    ? loc['mfa.loginEmailBody']
                    : _recovery
                    ? loc['mfa.subRecovery']
                    : loc.format('mfa.sub', {'email': widget.challenge.email}),
                textAlign: TextAlign.center,
                style: ColituText.muted,
              ),
            ),
            const SizedBox(height: 22),
            ColituPanel(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ColituField(
                    key: ValueKey(_recovery ? 'mfaRecovery' : 'mfaCode'),
                    controller: _code,
                    label: _recovery ? loc['mfa.recoveryCode'] : loc['mfa.code'],
                    hint: _recovery ? 'xxxx-xxxx' : '••••••',
                    keyboardType: _recovery
                        ? TextInputType.visiblePassword
                        : TextInputType.number,
                    textInputAction: TextInputAction.done,
                    // iOS offers the code from Passwords / the authenticator
                    // above the keyboard; recovery codes are typed or pasted.
                    autofillHints: _recovery ? null : const [AutofillHints.oneTimeCode],
                    autocorrect: false,
                    prefixIcon: CupertinoIcons.lock,
                    enabled: !_loading,
                    // Room for a pasted code with spaces or dashes.
                    maxLength: _recovery ? 64 : 12,
                    onSubmitted: (_) => _submit(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    ColituNotice(_error!),
                  ],
                  const SizedBox(height: 18),
                  ColituButton(
                    key: const ValueKey('mfaSubmit'),
                    label: loc['mfa.submit'],
                    onPressed: _submit,
                    loading: _loading,
                  ),
                  if (!_byEmail) ...[
                    const SizedBox(height: 10),
                    Center(
                      child: ColituLinkButton(
                        key: const ValueKey('mfaToggleRecovery'),
                        label: _recovery ? loc['mfa.useApp'] : loc['mfa.useRecovery'],
                        onPressed: _loading ? null : _toggleRecovery,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _byEmail
                  ? null
                  : Text(loc['mfa.hint'], textAlign: TextAlign.center, style: ColituText.small),
            ),
            const SizedBox(height: 12),
            Center(
              child: ColituLinkButton(
                label: loc['mfa.back'],
                onPressed: _loading ? null : () => _backToSignIn(),
                color: ColituColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
