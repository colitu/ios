import 'package:colitu_vpn/colitu/api/api_client.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/api/models/user_models.dart';

class UserService {
  UserService({APIClient? client}) : _client = client ?? APIClient();

  final APIClient _client;

  Future<ColituUser> me() {
    return _client.get(
      APIEndpoint.me,
      (json) => ColituUser.fromJson(json as Map<String, dynamic>),
      queryParameters: {'_ts': DateTime.now().millisecondsSinceEpoch},
    );
  }

  Future<List<ColituDevice>> devices() {
    return _client.get(APIEndpoint.userDevices, (json) {
      final map = json as Map<String, dynamic>;
      final list = map['data'] is List
          ? map['data'] as List
          : map['devices'] is List
          ? map['devices'] as List
          : const [];
      return list
          .whereType<Map<String, dynamic>>()
          // Removed devices (revoked_at set) neither show nor count.
          .where((d) => d['revoked_at'] == null && d['revokedAt'] == null)
          .map(ColituDevice.fromJson)
          .toList();
    });
  }

  /// Makes this (paused) device the active one; the panel pauses another
  /// device of the account instead.
  Future<void> activateDevice(String id) {
    return _client.postRenewing(
      APIEndpoint.activateDevice(id),
      (_) {},
      data: () => const <String, dynamic>{},
    );
  }

  Future<void> disconnectDevice(String id) async {
    try {
      await _client.delete(
        '${APIEndpoint.userDevices}/${Uri.encodeComponent(id)}',
        (_) {},
      );
    } on APIException catch (e) {
      // Already removed (on the site or another app): the goal is reached.
      if (e.backendCode != 'DEVICE_NOT_FOUND') rethrow;
    }
  }
}
