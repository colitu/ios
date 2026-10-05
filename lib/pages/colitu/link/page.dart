import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_errors.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/app_session.dart';
import 'package:colitu_vpn/colitu/services/auth_service.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';

/// Signs a TV in to this account: scan the QR code on the TV's sign-in screen
/// (or type its code), check which device asks, and approve it. Returns true
/// when a device was approved.
class ColituLinkScannerPage extends StatefulWidget {
  const ColituLinkScannerPage({super.key, required this.email});

  final String email;

  @override
  State<ColituLinkScannerPage> createState() => _ColituLinkScannerPageState();
}

class _ColituLinkScannerPageState extends State<ColituLinkScannerPage> {
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  final _typed = TextEditingController();
  var _typing = false;
  var _busy = false;
  var _scanning = true;
  String? _error;
  LinkRequest? _request;

  @override
  void dispose() {
    _scanner.dispose();
    _typed.dispose();
    super.dispose();
  }

  String _friendly(Object error) => colituErrorMessage(error);

  Future<void> _lookup(String raw) async {
    final code = LinkRequest.codeOf(raw);
    if (code == null) {
      setState(() {
        _error = ColituLoc.I['link.invalid'];
        _scanning = true;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final request = await AppSession.instance.lookupLink(code);
      if (!mounted) return;
      setState(() => _request = request);
      await _scanner.stop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = _friendly(error);
          _scanning = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decide(bool approve) async {
    final request = _request;
    if (request == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppSession.instance.decideLink(request.code, approve: approve);
      if (mounted) Navigator.of(context).pop(approve);
    } catch (error) {
      if (mounted) setState(() => _error = _friendly(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (!_scanning || _busy || _request != null || _typing) return;
    final value = capture.barcodes.map((code) => code.rawValue).whereType<String>().firstOrNull;
    if (value == null) return;
    _scanning = false;
    _lookup(value);
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
    final request = _request;
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (request == null && !_typing) ...[
            MobileScanner(
              controller: _scanner,
              onDetect: _onDetect,
              errorBuilder: (context, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(loc['link.cameraDenied'], textAlign: TextAlign.center, style: ColituText.muted),
                ),
              ),
            ),
            Center(
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: ColituColors.lilac, width: 3),
                ),
              ),
            ),
          ],
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(loc['link.row'], style: ColituText.h2.copyWith(color: Colors.white))),
                      ColituIconButton(
                        icon: CupertinoIcons.xmark,
                        tooltip: loc['pay.cancel'],
                        onPressed: () => Navigator.of(context).pop(false),
                      ),
                    ],
                  ),
                  const Spacer(),
                  if (request != null)
                    _confirmPanel(request)
                  else if (_typing)
                    _typePanel()
                  else
                    _scanHint(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _scanHint() {
    final loc = ColituLoc.I;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_busy) const Center(child: ColituSpinner()),
          if (_error != null) ...[ColituNotice(_error!), const SizedBox(height: 12)],
          Text(loc['link.scanTitle'], textAlign: TextAlign.center, style: ColituText.h2.copyWith(color: Colors.white)),
          const SizedBox(height: 6),
          Text(loc['link.scanHint'], textAlign: TextAlign.center, style: ColituText.muted),
          const SizedBox(height: 16),
          ColituButton.secondary(
            label: loc['link.enterCode'],
            height: 48,
            onPressed: () => setState(() {
              _typing = true;
              _error = null;
            }),
          ),
        ],
      ),
    );
  }

  Widget _typePanel() {
    final loc = ColituLoc.I;
    return ColituPanel(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ColituField(
            controller: _typed,
            label: loc['link.codeLabel'],
            hint: 'ABCD-2345',
            autocorrect: false,
            textInputAction: TextInputAction.done,
            prefixIcon: CupertinoIcons.tv,
            enabled: !_busy,
            onSubmitted: (value) => _lookup(value),
          ),
          if (_error != null) ...[const SizedBox(height: 12), ColituNotice(_error!)],
          const SizedBox(height: 14),
          ColituButton(
            label: loc['link.continue'],
            loading: _busy,
            onPressed: () => _lookup(_typed.text),
          ),
          const SizedBox(height: 4),
          Center(
            child: ColituLinkButton(
              label: loc['link.useCamera'],
              icon: CupertinoIcons.qrcode_viewfinder,
              onPressed: () => setState(() {
                _typing = false;
                _error = null;
                _scanning = true;
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _confirmPanel(LinkRequest request) {
    final loc = ColituLoc.I;
    final details = [
      request.platform == 'android' ? 'Android TV' : request.platform,
      ?request.country,
      LinkRequest.shown(request.code),
    ].where((part) => part.isNotEmpty).join(' · ');
    return ColituPanel(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const ColituRoundIcon(CupertinoIcons.tv, size: 48, accent: true),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.deviceName.isEmpty ? loc['link.unknownDevice'] : request.deviceName,
                      style: ColituText.label,
                      maxLines: 2,
                    ),
                    const SizedBox(height: 2),
                    Text(details, style: ColituText.small),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(loc['link.confirmTitle'], style: ColituText.h2),
          const SizedBox(height: 6),
          Text(loc.format('link.confirmBody', {'email': widget.email}), style: ColituText.muted),
          if (_error != null) ...[const SizedBox(height: 12), ColituNotice(_error!)],
          const SizedBox(height: 16),
          ColituButton(label: loc['link.approve'], loading: _busy, onPressed: () => _decide(true)),
          const SizedBox(height: 8),
          ColituButton.secondary(
            label: loc['link.deny'],
            height: 48,
            onPressed: _busy ? null : () => _decide(false),
          ),
        ],
      ),
    );
  }
}
