import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_errors.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/connection_controller.dart';
import 'package:colitu_vpn/colitu/services/support_service.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/pages/colitu/shell/page.dart';

/// Live support inside the app: the list of requests, a new-request form with
/// attachments and diagnostics, and the chat thread, which refreshes every
/// few seconds while it is open.
class SupportTab extends StatefulWidget {
  const SupportTab({super.key, required this.controller, this.service});

  final ColituConnectionController controller;
  final ColituSupportService? service;

  @override
  State<SupportTab> createState() => _SupportTabState();
}

class _SupportTabState extends State<SupportTab> {
  late final ColituSupportService _service = widget.service ?? ColituSupportService();
  List<SupportConversation> _conversations = const [];
  var _loading = true;
  String? _error;
  String? _openId;
  var _composing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload(firstLoad: true));
  }

  Future<void> _reload({bool firstLoad = false}) async {
    try {
      final list = await _service.conversations();
      if (!mounted) return;
      setState(() {
        _conversations = list;
        _error = null;
        _loading = false;
        if (firstLoad && list.isEmpty) _composing = true;
      });
      widget.controller.setSupportUnread(list.fold(0, (sum, c) => sum + c.unread));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = colituErrorMessage(error);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = _openId;
    if (id != null) {
      return _SupportThread(
        service: _service,
        controller: widget.controller,
        id: id,
        initial: _conversations.where((c) => c.id == id).firstOrNull,
        onBack: () {
          setState(() => _openId = null);
          unawaited(_reload());
        },
      );
    }
    if (_composing) {
      return _NewRequest(
        service: _service,
        controller: widget.controller,
        onCancel: () => setState(() => _composing = false),
        onCreated: (created) async {
          setState(() => _composing = false);
          await _reload();
          if (mounted && created != null) setState(() => _openId = created.id);
        },
      );
    }
    final loc = ColituLoc.I;
    return ShellScroll(
      onRefresh: _reload,
      children: [
        Text(loc['support.title'], style: ColituText.h1),
        const SizedBox(height: 6),
        Text(loc['support.sub'], style: ColituText.muted),
        const SizedBox(height: 16),
        ColituButton(
          label: loc['support.new'],
          icon: CupertinoIcons.plus,
          height: 50,
          onPressed: () => setState(() => _composing = true),
        ),
        const SizedBox(height: 4),
        Center(
          child: ColituLinkButton(
            label: loc['support.help'],
            icon: CupertinoIcons.book,
            onPressed: () => launchUrl(
              Uri.parse('https://docs.colitu.com/${loc.language}'),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (_loading)
          const Padding(padding: EdgeInsets.symmetric(vertical: 30), child: Center(child: ColituSpinner()))
        else if (_error != null)
          ColituNotice(_error!)
        else if (_conversations.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 30),
            child: Center(child: Text(loc['support.empty'], style: ColituText.muted, textAlign: TextAlign.center)),
          )
        else
          for (final conversation in _conversations) ...[
            _ConversationRow(conversation: conversation, onTap: () => setState(() => _openId = conversation.id)),
            const SizedBox(height: 8),
          ],
      ],
    );
  }
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({required this.conversation, required this.onTap});

  final SupportConversation conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final at = conversation.lastMessageAt;
    return ColituTile(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  conversation.subject.isEmpty ? loc['support.title'] : conversation.subject,
                  style: ColituText.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (at != null) Text(_shortTime(at), style: ColituText.small.copyWith(color: ColituColors.dim)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  conversation.lastMessage.replaceAll('\n', ' '),
                  style: ColituText.small,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (conversation.unread > 0) ...[
                const SizedBox(width: 8),
                Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(color: ColituColors.danger, shape: BoxShape.circle),
                  child: Text(
                    '${conversation.unread > 9 ? 9 : conversation.unread}',
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          _StatusBadge(conversation.status),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge(this.status);

  final String status;

  @override
  Widget build(BuildContext context) {
    final known = const {'open', 'resolved', 'closed'}.contains(status) ? status : 'waiting';
    final tone = switch (known) {
      'open' => ColituBadgeTone.accent,
      'resolved' => ColituBadgeTone.success,
      'closed' => ColituBadgeTone.neutral,
      _ => ColituBadgeTone.warning,
    };
    return ColituBadge(ColituLoc.I['support.status.$known'], tone: tone);
  }
}

// ── New request ─────────────────────────────────────────────────────────────

class _NewRequest extends StatefulWidget {
  const _NewRequest({
    required this.service,
    required this.controller,
    required this.onCancel,
    required this.onCreated,
  });

  final ColituSupportService service;
  final ColituConnectionController controller;
  final VoidCallback onCancel;
  final Future<void> Function(SupportConversation?) onCreated;

  @override
  State<_NewRequest> createState() => _NewRequestState();
}

class _NewRequestState extends State<_NewRequest> {
  final _subject = TextEditingController();
  final _message = TextEditingController();
  final _files = <SupportUpload>[];
  var _diagnostics = true;
  var _sending = false;
  String? _error;

  @override
  void dispose() {
    _subject.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final loc = ColituLoc.I;
    if (_sending) return;
    if (_subject.text.trim().isEmpty || _message.text.trim().isEmpty) {
      setState(() => _error = loc['support.err.subject']);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final c = widget.controller;
      final server = c.connectedServer;
      final report = _diagnostics
          ? await ColituSupportService.diagnostics(
              server: server == null ? null : '${c.titleOf(server)} (${server.id})',
              protocol: c.connected ? c.transport : null,
              connected: c.connected,
              lastError: c.error,
            )
          : null;
      final created = await widget.service.create(
        subject: _subject.text.trim(),
        message: _message.text.trim(),
        files: List.of(_files),
        diagnostics: report,
      );
      if (!mounted) return;
      showColituToast(context, loc['support.sent']);
      await widget.onCreated(created);
    } catch (error) {
      if (mounted) setState(() => _error = colituErrorMessage(error));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    return ShellScroll(
      children: [
        Row(
          children: [
            _BackButton(onTap: widget.onCancel),
            const SizedBox(width: 10),
            Expanded(child: Text(loc['support.new'], style: ColituText.h1)),
          ],
        ),
        const SizedBox(height: 16),
        ColituPanel(
          padding: const EdgeInsets.all(16),
          radius: ColituRadius.md,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ColituField(
                controller: _subject,
                label: loc['support.subject'],
                hint: loc['support.subjectHint'],
                enabled: !_sending,
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text(loc['support.message'], style: ColituText.small.copyWith(fontWeight: FontWeight.w600)),
              ),
              _TextArea(controller: _message, hint: loc['support.messageHint'], minLines: 5, enabled: !_sending),
              const SizedBox(height: 10),
              _FileChips(files: _files, onRemove: (file) => setState(() => _files.remove(file))),
              _AttachButtons(
                onPicked: (files) => setState(() => _files.addAll(files)),
                current: _files.length,
                onError: (message) => setState(() => _error = message),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 2),
                child: Text(loc['support.attachHint'], style: ColituText.small),
              ),
              const SizedBox(height: 14),
              ColituTile(
                onTap: () => setState(() => _diagnostics = !_diagnostics),
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(loc['support.diagnostics'], style: ColituText.label),
                          const SizedBox(height: 2),
                          Text(loc['support.diagnosticsHint'], style: ColituText.small),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    CupertinoSwitch(
                      value: _diagnostics,
                      activeTrackColor: ColituColors.violet,
                      onChanged: (value) => setState(() => _diagnostics = value),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                ColituNotice(_error!),
              ],
              const SizedBox(height: 16),
              ColituButton(label: loc['support.create'], onPressed: _send, loading: _sending),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Thread ──────────────────────────────────────────────────────────────────

class _SupportThread extends StatefulWidget {
  const _SupportThread({
    required this.service,
    required this.controller,
    required this.id,
    required this.initial,
    required this.onBack,
  });

  final ColituSupportService service;
  final ColituConnectionController controller;
  final String id;
  final SupportConversation? initial;
  final VoidCallback onBack;

  @override
  State<_SupportThread> createState() => _SupportThreadState();
}

class _SupportThreadState extends State<_SupportThread> {
  late SupportConversation? _conversation = widget.initial;
  List<SupportMessage> _messages = const [];
  final _reply = TextEditingController();
  final _scroll = ScrollController();
  final _files = <SupportUpload>[];
  final _images = <String, Uint8List?>{};
  var _loading = true;
  var _sending = false;
  var _refreshing = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh(scrollToEnd: true));
    unawaited(widget.controller.checkSupport());
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_refresh()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _reply.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool scrollToEnd = false}) async {
    // One request at a time: on a slow network the 5 s poll would otherwise
    // stack requests whose late answers briefly undo newer messages.
    if (_refreshing && !scrollToEnd) return;
    _refreshing = true;
    try {
      final (conversation, messages) = await widget.service.thread(widget.id);
      if (!mounted) return;
      final grew = messages.length != _messages.length ||
          (messages.isNotEmpty && _messages.isNotEmpty && messages.last.id != _messages.last.id);
      setState(() {
        _conversation = conversation ?? _conversation;
        _messages = messages;
        _loading = false;
      });
      if (grew || scrollToEnd) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.animateTo(
              _scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
            );
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _send() async {
    final body = _reply.text.trim();
    if (_sending || (body.isEmpty && _files.isEmpty)) return;
    setState(() => _sending = true);
    try {
      await widget.service.reply(widget.id, body, List.of(_files));
      _reply.clear();
      _files.clear();
      await _refresh(scrollToEnd: true);
    } catch (error) {
      if (mounted) showColituToast(context, colituErrorMessage(error), error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _loadImage(SupportAttachment attachment) async {
    if (_images.containsKey(attachment.id)) return;
    _images[attachment.id] = null;
    try {
      final bytes = await widget.service.attachment(attachment.id);
      if (mounted) setState(() => _images[attachment.id] = bytes);
    } catch (_) {
      // Try again the next time the message is built (a short network drop
      // would otherwise leave the spinner turning forever).
      _images.remove(attachment.id);
    }
  }

  Future<void> _openFile(SupportAttachment attachment) async {
    File? file;
    try {
      final bytes = await widget.service.attachment(attachment.id);
      // Written to the app's own temporary folder under the original name
      // (only its base name, never a path from the server) and removed once
      // the share sheet closes, so attachments do not pile up in tmp.
      final dir = await Directory(
        p.join((await getTemporaryDirectory()).path, 'support-share'),
      ).create(recursive: true);
      var name = p.basename(attachment.fileName).replaceAll(RegExp(r'[\x00-\x1f\\/:]'), '_').trim();
      if (name.isEmpty || name == '.' || name == '..') name = 'attachment';
      file = File(p.join(dir.path, name));
      await file.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path, mimeType: attachment.contentType)]),
      );
    } catch (error) {
      if (mounted) showColituToast(context, colituErrorMessage(error), error: true);
    } finally {
      try {
        await file?.delete();
      } catch (_) {
        // Already gone.
      }
    }
  }

  void _viewImage(Uint8List bytes) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        // Decoded at most 2048 px wide: a huge photo would exhaust memory.
        child: InteractiveViewer(child: Center(child: Image.memory(bytes, cacheWidth: 2048))),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final conversation = _conversation;
    final closed = conversation?.closed == true;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final bottom = keyboard > 0 ? 8.0 : 96 + MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Row(
              children: [
                _BackButton(onTap: widget.onBack),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conversation == null || conversation.subject.isEmpty ? loc['support.title'] : conversation.subject,
                        style: ColituText.h2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      _StatusBadge(conversation?.status ?? 'waiting'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading && _messages.isEmpty
                ? const Center(child: ColituSpinner())
                // Anchored to the input like any chat: a short thread sits
                // at the bottom instead of leaving the screen empty.
                : Align(
                    alignment: Alignment.bottomCenter,
                    child: ListView(
                      shrinkWrap: true,
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      children: [
                      for (final (i, message) in _messages.indexed) ...[
                        if (_startsDay(i))
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Center(
                              child: Text(
                                loc.date(message.createdAt!.toLocal()),
                                style: ColituText.small.copyWith(color: ColituColors.dim),
                              ),
                            ),
                          ),
                        _Bubble(
                          message: message,
                          images: _images,
                          onLoadImage: _loadImage,
                          onOpenImage: _viewImage,
                          onOpenFile: _openFile,
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (_awaitingReply)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
                          child: Text(
                            loc['support.waitingHint'],
                            textAlign: TextAlign.right,
                            style: ColituText.small.copyWith(color: ColituColors.dim),
                          ),
                        ),
                    ],
                  ),
                  ),
          ),
          if (closed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Text(loc['support.closed'], style: ColituText.small),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Column(
                children: [
                  _FileChips(files: _files, onRemove: (file) => setState(() => _files.remove(file))),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _AttachButtons(
                        compact: true,
                        current: _files.length,
                        onPicked: (files) => setState(() => _files.addAll(files)),
                        onError: (message) => showColituToast(context, message, error: true),
                      ),
                      Expanded(child: _TextArea(controller: _reply, hint: loc['support.reply'], minLines: 1, maxLines: 5, enabled: !_sending)),
                      const SizedBox(width: 8),
                      ColituPressable(
                        onTap: _send,
                        child: Container(
                          width: 46,
                          height: 46,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(gradient: ColituGradients.accent, shape: BoxShape.circle),
                          child: _sending
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: ColituColors.onAccent))
                              : const Icon(CupertinoIcons.paperplane_fill, size: 20, color: ColituColors.onAccent),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// The last word is the user's and the request is still open.
  bool get _awaitingReply =>
      _messages.isNotEmpty && _messages.last.mine && _conversation?.closed != true;

  /// A date line above the first message of every day.
  bool _startsDay(int index) {
    final at = _messages[index].createdAt?.toLocal();
    if (at == null) return false;
    if (index == 0) return true;
    final previous = _messages[index - 1].createdAt?.toLocal();
    return previous == null || previous.year != at.year || previous.month != at.month || previous.day != at.day;
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.images,
    required this.onLoadImage,
    required this.onOpenImage,
    required this.onOpenFile,
  });

  final SupportMessage message;
  final Map<String, Uint8List?> images;
  final ValueChanged<SupportAttachment> onLoadImage;
  final ValueChanged<Uint8List> onOpenImage;
  final ValueChanged<SupportAttachment> onOpenFile;

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    final mine = message.mine;
    final fg = mine ? ColituColors.onAccent : ColituColors.text;
    final name = message.sender == 'bot' ? 'Colitu Bot' : loc['support.team'];
    // SelectableText takes all the width it is offered, which stretched
    // every bubble to the maximum; IntrinsicWidth sizes it to the text.
    final maxWidth = MediaQuery.sizeOf(context).width * 0.78;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: IntrinsicWidth(
          child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          decoration: BoxDecoration(
            gradient: mine ? ColituGradients.accent : null,
            color: mine ? null : ColituColors.surface2,
            border: mine ? null : Border.all(color: ColituColors.line),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(mine ? 18 : 6),
              bottomRight: Radius.circular(mine ? 6 : 18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!mine) ...[
                Text(
                  message.adminName != null && message.sender == 'admin' ? '$name · ${message.adminName}' : name,
                  style: ColituText.small.copyWith(color: ColituColors.lilac, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
              ],
              if (message.body.trim().isNotEmpty)
                SelectableText(message.body, style: ColituText.body.copyWith(fontSize: 15, height: 1.4, color: fg)),
              for (final attachment in message.attachments) ...[
                const SizedBox(height: 8),
                if (attachment.isImage) _imageOf(attachment) else _fileOf(attachment, mine),
              ],
              if (message.createdAt != null) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    _clock(message.createdAt!),
                    style: ColituText.small.copyWith(
                      fontSize: 10.5,
                      color: mine ? ColituColors.onAccent.withValues(alpha: 0.7) : ColituColors.dim,
                    ),
                  ),
                ),
              ],
            ],
          ),
          ),
        ),
      ),
    );
  }

  Widget _imageOf(SupportAttachment attachment) {
    if (!images.containsKey(attachment.id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onLoadImage(attachment));
    }
    final bytes = images[attachment.id];
    return GestureDetector(
      onTap: bytes == null ? null : () => onOpenImage(bytes),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minWidth: 120, minHeight: 80, maxWidth: 260, maxHeight: 220),
          color: const Color(0x14FFFFFF),
          child: bytes == null
              ? const Center(child: ColituSpinner())
              : Image.memory(bytes, fit: BoxFit.contain, cacheWidth: 600),
        ),
      ),
    );
  }

  Widget _fileOf(SupportAttachment attachment, bool mine) {
    return ColituPressable(
      onTap: () => onOpenFile(attachment),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(color: const Color(0x1FFFFFFF), borderRadius: BorderRadius.circular(10)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.doc, size: 16, color: mine ? ColituColors.onAccent : ColituColors.lilac),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '${attachment.fileName} · ${ColituLoc.I.bytes(attachment.size)}',
                style: ColituText.small.copyWith(color: mine ? ColituColors.onAccent : ColituColors.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Shared pieces ───────────────────────────────────────────────────────────

class _AttachButtons extends StatelessWidget {
  const _AttachButtons({
    required this.onPicked,
    required this.current,
    required this.onError,
    this.compact = false,
  });

  final ValueChanged<List<SupportUpload>> onPicked;
  final int current;
  final ValueChanged<String> onError;
  final bool compact;

  Future<void> _pickPhotos() async {
    final picked = await ImagePicker().pickMultiImage(imageQuality: 85, maxWidth: 2400);
    await _accept([for (final file in picked) (file.name, await file.readAsBytes())]);
  }

  Future<void> _pickFiles() async {
    // Without the data: a large file is refused by its size before anything
    // is read into memory.
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      withData: false,
      type: FileType.custom,
      allowedExtensions: ColituSupportService.allowedExtensions,
    );
    if (result == null) return;
    final files = <(String, Uint8List)>[];
    for (final file in result.files) {
      if (file.size > ColituSupportService.maxFileBytes) {
        onError(ColituLoc.I['support.err.file']);
        continue;
      }
      final path = file.path;
      if (path == null) continue;
      files.add((file.name, await File(path).readAsBytes()));
    }
    await _accept(files);
  }

  Future<void> _accept(List<(String, Uint8List)> files) async {
    final loc = ColituLoc.I;
    final accepted = <SupportUpload>[];
    for (final (name, bytes) in files) {
      if (current + accepted.length >= ColituSupportService.maxFiles) {
        onError(loc['support.err.files']);
        break;
      }
      if (bytes.isEmpty || bytes.length > ColituSupportService.maxFileBytes) {
        onError(loc['support.err.file']);
        continue;
      }
      accepted.add(SupportUpload(name, bytes));
    }
    if (accepted.isNotEmpty) onPicked(accepted);
  }

  @override
  Widget build(BuildContext context) {
    final loc = ColituLoc.I;
    if (compact) {
      return PopupMenuButton<int>(
        tooltip: loc['support.attach'],
        color: ColituColors.navy,
        onSelected: (value) => unawaited(value == 0 ? _pickPhotos() : _pickFiles()),
        itemBuilder: (_) => [
          PopupMenuItem(value: 0, child: Text(loc['support.photo'], style: ColituText.body)),
          PopupMenuItem(value: 1, child: Text(loc['support.file'], style: ColituText.body)),
        ],
        child: const SizedBox(
          width: 46,
          height: 46,
          child: Icon(CupertinoIcons.paperclip, color: ColituColors.muted, size: 22),
        ),
      );
    }
    return Wrap(
      spacing: 14,
      children: [
        ColituLinkButton(label: loc['support.photo'], icon: CupertinoIcons.photo, onPressed: _pickPhotos),
        ColituLinkButton(label: loc['support.file'], icon: CupertinoIcons.paperclip, onPressed: _pickFiles),
      ],
    );
  }
}

class _FileChips extends StatelessWidget {
  const _FileChips({required this.files, required this.onRemove});

  final List<SupportUpload> files;
  final ValueChanged<SupportUpload> onRemove;

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final file in files)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 4, 2, 4),
              decoration: BoxDecoration(
                color: ColituColors.surface2,
                border: Border.all(color: ColituColors.line),
                borderRadius: BorderRadius.circular(ColituRadius.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      '${file.name} · ${ColituLoc.I.bytes(file.bytes.length)}',
                      style: ColituText.small,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onRemove(file),
                    icon: const Icon(CupertinoIcons.xmark, size: 14, color: ColituColors.dim),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TextArea extends StatelessWidget {
  const _TextArea({
    required this.controller,
    required this.hint,
    this.minLines = 1,
    this.maxLines = 10,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String hint;
  final int minLines;
  final int maxLines;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      minLines: minLines,
      maxLines: maxLines,
      maxLength: 8000,
      buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
      keyboardType: TextInputType.multiline,
      style: ColituText.body.copyWith(fontSize: 15, color: ColituColors.text),
      cursorColor: ColituColors.lilac,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: ColituText.body.copyWith(fontSize: 15, color: ColituColors.dim),
        filled: true,
        fillColor: ColituColors.field,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ColituRadius.md),
          borderSide: const BorderSide(color: ColituColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ColituRadius.md),
          borderSide: const BorderSide(color: ColituColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ColituRadius.md),
          borderSide: const BorderSide(color: ColituColors.violet),
        ),
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: ColituLoc.I['support.back'],
      child: ColituPressable(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(color: ColituColors.surface2, shape: BoxShape.circle),
          child: const Icon(CupertinoIcons.chevron_left, size: 18, color: ColituColors.text),
        ),
      ),
    );
  }
}

String _clock(DateTime value) {
  final local = value.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

String _shortTime(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  if (local.year == now.year && local.month == now.month && local.day == now.day) return _clock(value);
  final date = ColituLoc.I.date(local);
  final parts = date.split(' ');
  return parts.length > 2 ? parts.take(2).join(' ') : date;
}
