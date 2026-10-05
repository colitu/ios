import 'package:flutter/services.dart';
import 'package:colitu_vpn/core/tools/platform.dart';

class ClipboardImage {
  const ClipboardImage({
    required this.dataUrl,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
  });

  final String dataUrl;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
}

class ClipboardImageService {
  static const _channel = MethodChannel('colitu/pasteboard');

  Future<ClipboardImage?> readImage() async {
    if (!AppPlatform.isIOS) return null;
    final data = await _channel.invokeMapMethod<String, Object?>('readImage');
    if (data == null) return null;
    final dataUrl = data['dataUrl'] as String? ?? '';
    if (dataUrl.isEmpty) return null;
    final size = data['sizeBytes'];
    return ClipboardImage(
      dataUrl: dataUrl,
      fileName: data['fileName'] as String? ?? 'clipboard-image.png',
      mimeType: data['mimeType'] as String? ?? 'image/png',
      sizeBytes: size is num ? size.toInt() : 0,
    );
  }
}
