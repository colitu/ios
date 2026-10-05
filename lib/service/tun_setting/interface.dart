import 'dart:io';

Future<List<NetworkInterface>> queryInterfaceList() async {
  final interfaces = await NetworkInterface.list();
  final filterInterfaces = interfaces.where((e) {
    if (_isTunnelOrVirtualInterface(e.name)) return false;
    return e.addresses.any(
      (address) =>
          !address.isLinkLocal &&
          !address.isLoopback &&
          !address.isMulticast &&
          (address.type == InternetAddressType.IPv4 ||
              address.type == InternetAddressType.IPv6),
    );
  }).toList();
  filterInterfaces.sort((left, right) {
    final leftHasIPv4 = left.addresses.any(
      (address) => address.type == InternetAddressType.IPv4,
    );
    final rightHasIPv4 = right.addresses.any(
      (address) => address.type == InternetAddressType.IPv4,
    );
    if (leftHasIPv4 != rightHasIPv4) return leftHasIPv4 ? -1 : 1;
    return left.index.compareTo(right.index);
  });
  return filterInterfaces;
}

bool _isTunnelOrVirtualInterface(String name) {
  final normalized = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return normalized.startsWith('tun') ||
      normalized.contains('wintun') ||
      normalized.contains('singtun') ||
      normalized.contains('colitu') ||
      normalized.contains('onexray') ||
      normalized.contains('wireguard') ||
      normalized.contains('openvpn') ||
      normalized.contains('vmware') ||
      normalized.startsWith('vethernet');
}
