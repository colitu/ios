import 'package:colitu_vpn/colitu/api/models/vpn_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('servers carry the services the panel verified from the node', () {
    final server = VPNServer.fromJson({
      'id': 'ee1',
      'name': 'Estonya',
      'country': 'EE',
      'city': '',
      'region': '',
      'status': 'online',
      'protocols': ['hysteria2'],
      'services': ['chatgpt', 'gemini', 'netflix', 42],
    });
    expect(server.services, ['chatgpt', 'gemini', 'netflix']);
    expect(server.opensAi, isTrue);
    expect(server.opensStreaming, isTrue);
  });

  test('ChatGPT without Gemini does not count as an AI server', () {
    final server = VPNServer.fromJson({'id': 'ee', 'name': 'Estonya', 'country': 'EE', 'status': 'online', 'services': ['chatgpt', 'claude']});
    expect(server.opensAi, isFalse);
  });

  test('older panels without services leave the categories empty', () {
    final server = VPNServer.fromJson({'id': 'x', 'name': 'X', 'country': 'DE', 'status': 'online'});
    expect(server.services, isEmpty);
    expect(server.opensAi, isFalse);
    expect(server.opensStreaming, isFalse);
  });
}
