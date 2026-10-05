import 'package:colitu_vpn/colitu/api/api_client.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
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
          .map(ColituDevice.fromJson)
          .toList();
    });
  }

  Future<void> disconnectDevice(String id) {
    return _client.delete(
      '${APIEndpoint.userDevices}/${Uri.encodeComponent(id)}',
      (_) {},
    );
  }
}
