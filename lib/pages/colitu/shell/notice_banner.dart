import 'package:flutter/cupertino.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/notice_service.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:url_launcher/url_launcher.dart';

Color noticeColor(NoticeLevel level) => switch (level) {
  NoticeLevel.critical => ColituColors.danger,
  NoticeLevel.warning => ColituColors.warning,
  NoticeLevel.promo => ColituColors.accent,
  NoticeLevel.info => ColituColors.muted,
};

/// The panel notice on the home screen: title, text, an optional button and
/// a close ×. Shows nothing while there is no notice.
class NoticeBanner extends StatefulWidget {
  const NoticeBanner({super.key, this.service, this.openLink});

  final NoticeService? service;

  /// Opens the notice link; the browser by default.
  final Future<void> Function(Uri uri)? openLink;

  @override
  State<NoticeBanner> createState() => _NoticeBannerState();
}

class _NoticeBannerState extends State<NoticeBanner> {
  late final NoticeService _service = widget.service ?? NoticeService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_changed);
    _service.refresh();
  }

  @override
  void dispose() {
    _service.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _open(ClientNotice notice) async {
    final uri = notice.link;
    if (uri == null) return;
    _service.clicked(notice);
    try {
      final open = widget.openLink;
      if (open != null) {
        await open(uri);
      } else {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      // No browser: the click was still counted.
    }
  }

  @override
  Widget build(BuildContext context) {
    final notice = _service.current;
    if (notice == null) return const SizedBox.shrink();
    final color = noticeColor(notice.level);
    final loc = ColituLoc.I;
    final canOpen = notice.link != null && notice.button != null;
    return Padding(
      key: const ValueKey('noticeBanner'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(ColituRadius.md),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                notice.level == NoticeLevel.critical ||
                        notice.level == NoticeLevel.warning
                    ? CupertinoIcons.exclamationmark_triangle
                    : CupertinoIcons.info_circle,
                size: 18,
                color: color,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (notice.title.isNotEmpty)
                    Text(
                      notice.title,
                      style: ColituText.body.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  if (notice.body.isNotEmpty) ...[
                    if (notice.title.isNotEmpty) const SizedBox(height: 2),
                    Text(
                      notice.body,
                      style: ColituText.body.copyWith(fontSize: 14),
                    ),
                  ],
                  if (canOpen) ...[
                    const SizedBox(height: 6),
                    ColituLinkButton(
                      key: const ValueKey('noticeButton'),
                      label: notice.button!,
                      color: color,
                      onPressed: () => _open(notice),
                    ),
                  ],
                ],
              ),
            ),
            Semantics(
              button: true,
              label: loc['trial.dismiss'],
              child: ColituPressable(
                key: const ValueKey('noticeClose'),
                onTap: () => _service.dismiss(notice),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(
                    CupertinoIcons.xmark,
                    size: 16,
                    color: ColituColors.muted,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
