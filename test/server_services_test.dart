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

  test('ad-free YouTube is a service tag but not a streaming one', () {
    final server = VPNServer.fromJson({'id': 'al', 'name': 'Arnavutluk', 'country': 'AL', 'status': 'online', 'services': ['youtube_adfree']});
    expect(server.services, ['youtube_adfree']);
    expect(server.opensStreaming, isFalse);
    expect(server.inCategory('streaming'), isFalse);
    expect(VPNServer.serviceNames.keys.first, 'youtube_adfree');
    expect(VPNServer.streamingServices, ['netflix', 'youtube_premium']);
  });
}
