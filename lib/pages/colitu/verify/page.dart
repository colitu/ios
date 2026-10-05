import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_errors.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/app_session.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/main/url.dart';

const _resendCooldown = 60;

/// Six-digit e-mail code after sign-up (or a sign-in to an unconfirmed
/// account). Confirming registers this device and starts the trial.
class ColituVerifyPage extends StatefulWidget {
  const ColituVerifyPage({super.key, this.codeJustSent = false});

  final bool codeJustSent;

  @override
  State<ColituVerifyPage> createState() => _ColituVerifyPageState();
}

class _ColituVerifyPageState extends State<ColituVerifyPage> {
  final _code = TextEditingController();
  String _email = '';
  var _loading = false;
  var _cooldown = 0;
  String? _error;
  String? _info;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_loadEmail());
    if (widget.codeJustSent) _startCooldown();
  }

  Future<void> _loadEmail() async {
    try {
      final email = await AppSession.instance.pendingVerificationEmail();
      if (mounted) setState(() => _email = email ?? '');
    } catch (_) {
      // Keychain unavailable: the text simply omits the address.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _cooldown = _resendCooldown);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _cooldown--);
      if (_cooldown <= 0) timer.cancel();
    });
  }

  Future<void> _submit() async {
    final loc = ColituLoc.I;
    if (_loading) return;
    final digits = _code.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 6) {
      setState(() => _error = loc['verify.err.length']);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    try {
      await AppSession.instance.verifyEmail(digits);
      if (!mounted) return;
      showColituToast(context, loc['verify.done']);
      context.go(RouterPath.home);
    } on APIException catch (error) {
      if (!mounted) return;
      const retryable = {
        'VERIFICATION_CODE_INVALID',
        'VERIFICATION_CODE_EXPIRED',
        'RATE_LIMITED',
        'EMAIL_NOT_VERIFIED',
      };
      final network = error.code == APIErrorCode.networkUnavailable ||
          error.code == APIErrorCode.backendUnavailable ||
          error.code == APIErrorCode.serverUnavailable;
      if (retryable.contains(error.backendCode) || network) {
        setState(() => _error = colituErrorMessage(error));
      } else {
        // The address is confirmed but this device could not be added
        // (device limit, trial used here, no plan), or the session ended.
        final message = error.statusCode == 401
            ? loc['auth.expired']
            : colituErrorMessage(error);
        await AppSession.instance.logout();
        if (mounted) context.go(RouterPath.colituAuth, extra: message);
      }
    } catch (error) {
      if (mounted) setState(() => _error = colituErrorMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resend() async {
    if (_cooldown > 0 || _loading) return;
    setState(() => _error = null);
    try {
      await AppSession.instance.sendVerificationCode();
      if (!mounted) return;
      setState(() => _info = ColituLoc.I['verify.sent']);
      _startCooldown();
    } on APIException catch (error) {
      if (!mounted) return;
      setState(() => _error = colituErrorMessage(error));
      if (error.backendCode == 'VERIFICATION_RATE_LIMITED') _startCooldown();
    } catch (error) {
      if (mounted) setState(() => _error = colituErrorMessage(error));
    }
  }

  Future<void> _otherAccount() async {
    await AppSession.instance.logout();
    if (mounted) context.go(RouterPath.colituAuth);
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
            const Align(alignment: Alignment.centerLeft, child: ColituWordmark(height: 14)),
            const SizedBox(height: 36),
            const Center(child: ColituRoundIcon(CupertinoIcons.mail, size: 72, accent: true)),
            const SizedBox(height: 18),
            Center(child: ColituKicker(loc['verify.kicker'], color: ColituColors.lilac)),
            const SizedBox(height: 12),
            Text(
              loc['verify.title'],
              textAlign: TextAlign.center,
              style: ColituText.display.copyWith(fontSize: 30),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                loc.format('verify.sub', {'email': _email}),
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
                    controller: _code,
                    label: loc['verify.code'],
                    hint: '••••••',
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    autocorrect: false,
                    prefixIcon: CupertinoIcons.lock,
                    enabled: !_loading,
                    onSubmitted: (_) => _submit(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    ColituNotice(_error!),
                  ],
                  if (_info != null) ...[
                    const SizedBox(height: 14),
                    ColituNotice(_info!, error: false),
                  ],
                  const SizedBox(height: 18),
                  ColituButton(label: loc['verify.submit'], onPressed: _submit, loading: _loading),
                  const SizedBox(height: 10),
                  Center(
                    child: ColituLinkButton(
                      label: _cooldown > 0
                          ? loc.format('verify.resendIn', {'n': _cooldown})
                          : loc['verify.resend'],
                      onPressed: _cooldown > 0 || _loading ? null : _resend,
                      color: _cooldown > 0 ? ColituColors.dim : ColituColors.lilac,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(loc['verify.hint'], textAlign: TextAlign.center, style: ColituText.small),
            ),
            const SizedBox(height: 12),
            Center(child: ColituLinkButton(label: loc['verify.other'], onPressed: _otherAccount)),
          ],
        ),
      ),
    );
  }
}
