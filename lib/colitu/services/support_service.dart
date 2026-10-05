import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:colitu_vpn/colitu/api/api_client.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';

/// One live-support conversation (panel `/api/v1/support`).
class SupportConversation {
  const SupportConversation({
    required this.id,
    required this.subject,
    required this.status,
    required this.unread,
    required this.lastMessage,
    this.lastMessageAt,
  });

  final String id;
  final String subject;

  /// waiting, open, resolved or closed.
  final String status;
  final int unread;
  final String lastMessage;
  final DateTime? lastMessageAt;

  bool get closed => status == 'closed';

  static SupportConversation? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = '${json['id'] ?? ''}';
    if (id.isEmpty) return null;
    return SupportConversation(
      id: id,
      subject: '${json['subject'] ?? ''}',
      status: '${json['status'] ?? 'waiting'}',
      unread: json['unread'] is int ? json['unread'] as int : 0,
      lastMessage: '${json['last_message'] ?? ''}',
      lastMessageAt: DateTime.tryParse('${json['last_message_at'] ?? ''}'),
    );
  }
}

class SupportAttachment {
  const SupportAttachment({
    required this.id,
    required this.fileName,
    required this.contentType,
    required this.size,
    required this.isImage,
  });

  final String id;
  final String fileName;
  final String contentType;
  final int size;
  final bool isImage;

  static SupportAttachment? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = '${json['id'] ?? ''}';
    if (id.isEmpty) return null;
    final type = '${json['content_type'] ?? 'application/octet-stream'}';
    return SupportAttachment(
      id: id,
      fileName: '${json['file_name'] ?? 'file'}',
      contentType: type,
      size: json['size_bytes'] is int ? json['size_bytes'] as int : 0,
      isImage: json['is_image'] == true || type.startsWith('image/'),
    );
  }
}

class SupportMessage {
  const SupportMessage({
    required this.id,
    required this.sender,
    this.adminName,
    required this.body,
    this.createdAt,
    required this.attachments,
  });

  final String id;

  /// user, admin or bot.
  final String sender;
  final String? adminName;
  final String body;
  final DateTime? createdAt;
  final List<SupportAttachment> attachments;

  bool get mine => sender == 'user';

  static SupportMessage? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = '${json['id'] ?? ''}';
    if (id.isEmpty) return null;
    final files = json['attachments'];
    final name = json['admin_name'];
    return SupportMessage(
      id: id,
      sender: '${json['sender'] ?? 'admin'}',
      adminName: name is String && name.isNotEmpty ? name : null,
      body: '${json['body'] ?? ''}',
      createdAt: DateTime.tryParse('${json['created_at'] ?? ''}'),
      attachments: files is List
          ? [for (final file in files) ?SupportAttachment.fromJson(file)]
          : const [],
    );
  }
}

class SupportUpload {
  const SupportUpload(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

/// In-app live support: conversations, messages with attachments,
/// diagnostics and the unread counter.
class ColituSupportService {
  ColituSupportService({APIClient? client}) : _client = client ?? APIClient();

  final APIClient _client;

  static const maxFileBytes = 10 * 1024 * 1024;
  static const maxFiles = 5;
  static const allowedExtensions = ['png', 'jpg', 'jpeg', 'webp', 'gif', 'pdf', 'txt', 'log', 'zip', 'json'];

  Future<List<SupportConversation>> conversations() async {
    final list = await _client.get(APIEndpoint.supportConversations, (json) {
      final data = json is Map<String, dynamic> ? json['data'] : null;
      return data is List ? [for (final item in data) ?SupportConversation.fromJson(item)] : <SupportConversation>[];
    });
    list.sort((a, b) => (b.lastMessageAt ?? DateTime(0)).compareTo(a.lastMessageAt ?? DateTime(0)));
    return list;
  }

  Future<(SupportConversation?, List<SupportMessage>)> thread(String id) {
    return _client.get(APIEndpoint.supportThread(id), (json) {
      final data = json is Map<String, dynamic> ? json['data'] : null;
      if (data is! Map<String, dynamic>) return (null, const <SupportMessage>[]);
      final messages = data['messages'];
      return (
        SupportConversation.fromJson(data['conversation']),
        messages is List ? [for (final item in messages) ?SupportMessage.fromJson(item)] : const <SupportMessage>[],
      );
    });
  }

  Future<int> unread() {
    return _client.get(APIEndpoint.supportUnread, (json) {
      final data = json is Map<String, dynamic> ? json['data'] : null;
      return data is Map<String, dynamic> && data['unread'] is int ? data['unread'] as int : 0;
    });
  }

  Future<SupportConversation?> create({
    required String subject,
    required String message,
    required List<SupportUpload> files,
    Map<String, dynamic>? diagnostics,
  }) {
    final payload = {
      'subject': subject,
      'message': message,
      'locale': ColituLoc.I.language,
      'diagnostics': ?diagnostics,
    };
    return _client.postRenewing(
      APIEndpoint.supportConversations,
      (json) => SupportConversation.fromJson(json is Map<String, dynamic> ? json['data'] : null),
      data: () => _body(payload, files),
    );
  }

  Future<void> reply(String id, String body, List<SupportUpload> files) async {
    await _client.postRenewing(
      APIEndpoint.supportMessages(id),
      (_) => null,
      data: () => _body({'body': body}, files),
    );
  }

  Future<Uint8List> attachment(String id) => _client.getBytes(APIEndpoint.supportAttachment(id));

  Object _body(Map<String, dynamic> payload, List<SupportUpload> files) {
    if (files.isEmpty) return payload;
    return FormData.fromMap({
      'payload': MultipartFile.fromString(jsonEncode(payload), contentType: DioMediaType('application', 'json')),
      'file': [for (final file in files) MultipartFile.fromBytes(file.bytes, filename: file.name)],
    }, ListFormat.multiCompatible);
  }

  /// Versions, device model, connection state and the last error; never
  /// browsing history.
  static Future<Map<String, dynamic>> diagnostics({
    String? server,
    String? protocol,
    required bool connected,
    String? lastError,
  }) async {
    final package = await PackageInfo.fromPlatform();
    var device = Platform.operatingSystem;
    var os = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    try {
      if (Platform.isIOS) {
        final info = await DeviceInfoPlugin().iosInfo;
        device = info.utsname.machine;
        os = 'iOS ${info.systemVersion}';
      }
    } catch (_) {}
    return {
      'platform': Platform.isIOS ? 'ios' : Platform.operatingSystem,
      'device': device,
      'os': os,
      'app_version': '${package.version}+${package.buildNumber}',
      'server': ?server,
      'protocol': ?protocol,
      'connected': connected,
      if (lastError != null && lastError.isNotEmpty) 'last_errors': [lastError],
    };
  }
}
