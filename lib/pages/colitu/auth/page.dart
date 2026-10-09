import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/api/models/auth_models.dart';
import 'package:colitu_vpn/colitu/config/app_environment.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_errors.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/app_session.dart';
import 'package:colitu_vpn/colitu/services/auth_service.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/colitu/theme/particles.dart';
import 'package:colitu_vpn/pages/colitu/auth/reset_panel.dart';
import 'package:colitu_vpn/pages/main/url.dart';

enum _AuthMode { login, register }

/// Sign-in / sign-up: 3D globe hero, language picker and a tabbed form. A
/// successful sign-in is kept on the device until the user signs out.
class ColituAuthPage extends StatefulWidget {
  const ColituAuthPage({super.key, this.initialMessage, this.register = false});

  final String? initialMessage;

  /// Open on the sign-up tab (from the tour's "Create account").
  final bool register;

  @override
  State<ColituAuthPage> createState() => _ColituAuthPageState();
}

class _ColituAuthPageState extends State<ColituAuthPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  late var _mode = widget.register ? _AuthMode.register : _AuthMode.login;
  var _loading = false;
  var _showPassword = false;
  var _acceptTerms = false;
  // "Forgot password" replaces the form until the user goes back.
  var _forgot = false;
  String? _emailError;
  String? _passwordError;
  String? _repeatError;
  String? _termsError;
  String? _message;

  @override
  void initState() {
    super.initState();
    _message = widget.initialMessage;
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  bool _validate() {
    final loc = ColituLoc.I;
    final email = _email.text.trim();
    _emailError = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)
        ? null
        : loc['auth.err.email'];
    // The 10-character minimum is for new passwords only: accounts with an
    // older, shorter password must still be able to sign in.
    _passwordError = (_mode == _AuthMode.register
            ? _password.text.length >= 10
            : _password.text.isNotEmpty)
        ? null
        : loc['auth.err.password'];
    _repeatError = null;
    _termsError = null;
    if (_mode == _AuthMode.register) {
      if (_repeat.text != _password.text) _repeatError = loc['auth.err.mismatch'];
      if (!_acceptTerms) _termsError = loc['auth.err.terms'];
    }
    setState(() {});
    return _emailError == null &&
        _passwordError == null &&
        _repeatError == null &&
        _termsError == null;
  }

  Future<void> _submit() async {
    if (_loading || !_validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final email = _email.text.trim();
      if (_mode == _AuthMode.register) {
        await AppSession.instance.register(
          RegisterRequest(email: email, password: _password.text),
        );
      } else {
        await AppSession.instance.login(
          LoginRequest(email: email, password: _password.text),
        );
      }
      if (!mounted) return;
      context.go(RouterPath.home);
    } on MfaRequiredException catch (required) {
      // Two-step sign-in: the code page finishes the sign-in.
      if (mounted) context.go(RouterPath.colituMfa, extra: required.challenge);
    } on APIException catch (error) {
      if (!mounted) return;
      if (error.code == APIErrorCode.emailNotVerified) {
        context.go(RouterPath.colituVerify, extra: true);
        return;
      }
      setState(() => _message = colituErrorMessage(error, signingIn: true));
    } catch (error) {
      if (mounted) {
        setState(() => _message = colituErrorMessage(error, signingIn: true));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setMode(_AuthMode mode) {
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      _message = null;
      _emailError = _passwordError = _repeatError = _termsError = null;
    });
  }

  Future<void> _open(String path) async {
    final uri = Uri.parse('${AppEnvironment.webBaseUrl}$path');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (error) {
      debugPrint('Open url failed: $uri $error');
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
    final register = _mode == _AuthMode.register;
    final title = _forgot
        ? loc['reset.title']
        : register
        ? loc['auth.registerTitle']
        : loc['auth.loginTitle'];
    final subtitle = _forgot
        ? loc['reset.heroSub']
        : register
        ? loc['auth.registerSub']
        : loc['auth.loginSub'];
    return ColituScaffold(
      padding: EdgeInsets.zero,
      resizeToAvoidBottomInset: true,
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
            const SizedBox(height: 6),
            const Center(
              child: ColituParticles(
                mode: ColituParticleMode.sphere,
                size: 190,
                energy: 0.5,
              ),
            ),
            const SizedBox(height: 4),
            Center(child: _Pill(text: loc['auth.kicker'])),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: ColituText.display.copyWith(fontSize: 30),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                subtitle,
                textAlign: TextAlign.center,
                style: ColituText.muted,
              ),
            ),
            const SizedBox(height: 22),
            if (_forgot)
              ColituPasswordResetPanel(
                initialEmail: _email.text,
                onBack: () => setState(() => _forgot = false),
                onSignedIn: () => context.go(RouterPath.home),
                onVerify: () => context.go(RouterPath.colituVerify, extra: true),
              )
            else
            ColituPanel(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ColituSegment<_AuthMode>(
                      values: _AuthMode.values,
                      selected: _mode,
                      onChanged: _setMode,
                      labelOf: (mode) => mode == _AuthMode.login
                          ? loc['auth.login']
                          : loc['auth.register'],
                      height: 44,
                    ),
                    const SizedBox(height: 20),
                    ColituField(
                      controller: _email,
                      label: loc['auth.email'],
                      hint: loc['auth.emailHint'],
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      autocorrect: false,
                      prefixIcon: CupertinoIcons.mail,
                      error: _emailError,
                      enabled: !_loading,
                    ),
                    if (register) ...[
                      const SizedBox(height: 6),
                      Text(
                        loc['auth.registerHint'],
                        key: const ValueKey('registerHint'),
                        style: ColituText.small,
                      ),
                    ],
                    const SizedBox(height: 14),
                    ColituField(
                      controller: _password,
                      label: loc['auth.password'],
                      hint: loc['auth.passwordHint'],
                      obscureText: !_showPassword,
                      textInputAction: register
                          ? TextInputAction.next
                          : TextInputAction.done,
                      autofillHints: [
                        register
                            ? AutofillHints.newPassword
                            : AutofillHints.password,
                      ],
                      autocorrect: false,
                      prefixIcon: CupertinoIcons.lock,
                      error: _passwordError,
                      enabled: !_loading,
                      onSubmitted: register ? null : (_) => _submit(),
                      suffix: IconButton(
                        tooltip: loc['auth.show'],
                        onPressed: () =>
                            setState(() => _showPassword = !_showPassword),
                        icon: Icon(
                          _showPassword ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
                          size: 20,
                          color: ColituColors.dim,
                        ),
                      ),
                    ),
                    if (!register)
                      Align(
                        alignment: Alignment.centerRight,
                        child: ColituLinkButton(
                          label: loc['auth.forgot'],
                          onPressed: _loading
                              ? null
                              : () => setState(() {
                                  _message = null;
                                  _forgot = true;
                                }),
                        ),
                      ),
                    if (register) ...[
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
                      const SizedBox(height: 16),
                      ColituCheck(
                        value: _acceptTerms,
                        onChanged: (value) => setState(() {
                          _acceptTerms = value;
                          _termsError = null;
                        }),
                        child: Text(
                          loc['auth.terms'],
                          style: ColituText.muted.copyWith(fontSize: 13.5),
                        ),
                      ),
                      if (_termsError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6, left: 32),
                          child: Text(
                            _termsError!,
                            style: ColituText.small.copyWith(
                              color: ColituColors.danger,
                            ),
                          ),
                        ),
                    ],
                    if (_message != null) ...[
                      const SizedBox(height: 16),
                      ColituNotice(_message!),
                    ],
                    const SizedBox(height: 20),
                    ColituButton(
                      label: register
                          ? loc['auth.submitRegister']
                          : loc['auth.submitLogin'],
                      loading: _loading,
                      onPressed: _submit,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      loc['auth.remember'],
                      textAlign: TextAlign.center,
                      style: ColituText.small,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 18,
              children: [
                ColituLinkButton(
                  label: loc['settings.terms'],
                  onPressed: () => _open('/legal/terms'),
                ),
                ColituLinkButton(
                  label: loc['settings.privacy'],
                  onPressed: () => _open('/legal/privacy'),
                ),
                ColituLinkButton(
                  label: loc['settings.website'],
                  onPressed: () => _open(''),
                ),
              ],
            ),
          ],
        ),
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
      padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ColituRadius.pill),
        border: Border.all(color: const Color(0x669F8CFF)),
        color: const Color(0x149F8CFF),
      ),
      child: Text(
        text,
        style: ColituText.kicker.copyWith(color: ColituColors.lilac, fontSize: 10.5),
      ),
    );
  }
}
