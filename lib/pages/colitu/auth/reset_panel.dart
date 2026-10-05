import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_errors.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/app_session.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';

/// "Forgot password": the address gets a six-digit code, and the code plus a
/// new password sign this device in. Every other session of the account ends.
class ColituPasswordResetPanel extends StatefulWidget {
  const ColituPasswordResetPanel({
    super.key,
    required this.initialEmail,
    required this.onBack,
    required this.onSignedIn,
    required this.onVerify,
  });

  final String initialEmail;
  final VoidCallback onBack;
  final VoidCallback onSignedIn;
  final VoidCallback onVerify;

  @override
  State<ColituPasswordResetPanel> createState() => _ColituPasswordResetPanelState();
}

class _ColituPasswordResetPanelState extends State<ColituPasswordResetPanel> {
  static const _cooldownSeconds = 60;

  late final _email = TextEditingController(text: widget.initialEmail.trim());
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  var _codeSent = false;
  var _loading = false;
  var _showPassword = false;
  var _cooldown = 0;
  Timer? _timer;
  String? _emailError;
  String? _passwordError;
  String? _repeatError;
  String? _message;
  String? _info;

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _cooldown = _cooldownSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _cooldown--);
      if (_cooldown <= 0) timer.cancel();
    });
  }

  Future<void> _send() async {
    final loc = ColituLoc.I;
    if (_loading || _cooldown > 0) return;
    final email = _email.text.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      setState(() => _emailError = loc['auth.err.email']);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _emailError = _message = _info = null;
    });
    try {
      await AppSession.instance.requestPasswordReset(email);
      if (!mounted) return;
      setState(() {
        _codeSent = true;
        _info = loc.format('reset.sent', {'email': email});
      });
      _startCooldown();
    } on APIException catch (error) {
      if (!mounted) return;
      setState(() {
        _message = colituErrorMessage(error);
        if (error.backendCode == 'VERIFICATION_RATE_LIMITED') _codeSent = true;
      });
      if (error.backendCode == 'VERIFICATION_RATE_LIMITED') _startCooldown();
    } catch (error) {
      if (mounted) setState(() => _message = colituErrorMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final loc = ColituLoc.I;
    if (_loading) return;
    final code = _code.text.replaceAll(RegExp(r'\D'), '');
    setState(() {
      _message = code.length == 6 ? null : loc['verify.err.length'];
      _passwordError = _password.text.length >= 10 ? null : loc['auth.err.password'];
      _repeatError = _repeat.text == _password.text ? null : loc['auth.err.mismatch'];
    });
    if (_message != null || _passwordError != null || _repeatError != null) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _info = null;
    });
    try {
      await AppSession.instance.resetPassword(_email.text.trim(), code, _password.text);
      if (!mounted) return;
      widget.onSignedIn();
    } on APIException catch (error) {
      if (!mounted) return;
      if (error.code == APIErrorCode.emailNotVerified) {
        widget.onVerify();
        return;
      }
      setState(() => _message = colituErrorMessage(error));
    } catch (error) {
      if (mounted) setState(() => _message = colituErrorMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    return ColituPanel(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(loc[_codeSent ? 'reset.codeSub' : 'reset.sub'], style: ColituText.muted),
            const SizedBox(height: 18),
            ColituField(
              controller: _email,
              label: loc['auth.email'],
              hint: loc['auth.emailHint'],
              keyboardType: TextInputType.emailAddress,
              textInputAction: _codeSent ? TextInputAction.next : TextInputAction.done,
              autofillHints: const [AutofillHints.email],
              autocorrect: false,
              prefixIcon: CupertinoIcons.mail,
              error: _emailError,
              enabled: !_loading && !_codeSent,
              onSubmitted: _codeSent ? null : (_) => _send(),
            ),
            if (_codeSent) ...[
              const SizedBox(height: 14),
              ColituField(
                controller: _code,
                label: loc['verify.code'],
                hint: '••••••',
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.oneTimeCode],
                autocorrect: false,
                prefixIcon: CupertinoIcons.lock,
                enabled: !_loading,
              ),
              const SizedBox(height: 14),
              ColituField(
                controller: _password,
                label: loc['reset.newPassword'],
                hint: loc['auth.passwordHint'],
                obscureText: !_showPassword,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.newPassword],
                autocorrect: false,
                prefixIcon: CupertinoIcons.lock,
                error: _passwordError,
                enabled: !_loading,
                suffix: IconButton(
                  tooltip: loc['auth.show'],
                  onPressed: () => setState(() => _showPassword = !_showPassword),
                  icon: Icon(
                    _showPassword ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
                    size: 20,
                    color: ColituColors.dim,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              ColituField(
                controller: _repeat,
                label: loc['auth.passwordRepeat'],
                obscureText: !_showPassword,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.newPassword],
                autocorrect: false,
                prefixIcon: CupertinoIcons.lock,
                error: _repeatError,
                enabled: !_loading,
                onSubmitted: (_) => _submit(),
              ),
            ],
            if (_info != null) ...[
              const SizedBox(height: 16),
              ColituNotice(_info!, error: false),
            ],
            if (_message != null) ...[
              const SizedBox(height: 16),
              ColituNotice(_message!),
            ],
            const SizedBox(height: 20),
            ColituButton(
              label: loc[_codeSent ? 'reset.submit' : 'reset.send'],
              loading: _loading,
              onPressed: _codeSent ? _submit : _send,
            ),
            if (_codeSent) ...[
              const SizedBox(height: 10),
              Center(
                child: ColituLinkButton(
                  label: _cooldown > 0
                      ? loc.format('verify.resendIn', {'n': _cooldown})
                      : loc['verify.resend'],
                  color: _cooldown > 0 ? ColituColors.dim : ColituColors.lilac,
                  onPressed: _cooldown > 0 || _loading ? null : _send,
                ),
              ),
              Center(
                child: ColituLinkButton(
                  label: loc['reset.changeEmail'],
                  onPressed: _loading
                      ? null
                      : () => setState(() {
                          _codeSent = false;
                          _code.clear();
                          _info = _message = null;
                        }),
                ),
              ),
              const SizedBox(height: 6),
              Text(loc['reset.note'], textAlign: TextAlign.center, style: ColituText.small),
            ],
            const SizedBox(height: 6),
            Center(
              child: ColituLinkButton(
                label: loc['reset.back'],
                onPressed: _loading ? null : widget.onBack,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
