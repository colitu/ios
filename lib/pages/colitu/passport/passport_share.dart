import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:zxing2/qrcode.dart';

import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/passport/colitu_passport.dart';
import 'package:colitu_vpn/colitu/theme/colitu_theme.dart';
import 'package:colitu_vpn/core/tools/file.dart';
import 'package:colitu_vpn/pages/colitu/passport/passport_art.dart';

/// QR matrix of [text] (true = dark module), or null when it does not fit.
List<List<bool>>? qrMatrix(String text) {
  try {
    final matrix = Encoder.encode(text, ErrorCorrectionLevel.m).matrix!;
    return [
      for (var y = 0; y < matrix.height; y++) [for (var x = 0; x < matrix.width; x++) matrix.get(x, y) == 1],
    ];
  } catch (_) {
    return null;
  }
}

/// A QR code drawn with dark modules on the white tile around it.
class PassportQr extends StatelessWidget {
  const PassportQr({super.key, required this.data, required this.size});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final m = qrMatrix(data);
    return SizedBox(
      width: size,
      height: size,
      child: m == null ? null : CustomPaint(painter: _QrPainter(m)),
    );
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter(this.m);

  final List<List<bool>> m;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / m.length;
    final dot = Paint()..color = const Color(0xFF16153A);
    for (var y = 0; y < m.length; y++) {
      for (var x = 0; x < m[y].length; x++) {
        if (m[y][x]) canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell + 0.4, cell + 0.4), dot);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter old) => old.m != m;
}

Future<ui.Image?> _asset(String path) async {
  try {
    final data = await rootBundle.load(path);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    return (await codec.getNextFrame()).image;
  } catch (_) {
    return null;
  }
}

/// The story-sized card (1080 × 1920, Android `sharePassport`): one stamp in
/// its material with "GOLD UNLOCKED", or the whole passport when [stamp] is
/// null; the count, my passport QR and the holder line. PNG bytes.
Future<Uint8List> renderPassportCard({ColituStamp? stamp, required bool premium}) async {
  const w = 1080.0;
  const h = 1920.0;
  final loc = ColituLoc.I;
  final passport = ColituPassport.I;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));
  final filter = Paint()..filterQuality = FilterQuality.high;

  void image(ui.Image? img, Rect dst, [Paint? paint]) {
    if (img == null) return;
    canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), dst, paint ?? filter);
  }

  void text(String value, double baseline, double size, Color color, {FontWeight weight = FontWeight.w500, double spacing = 0}) {
    // Long titles shrink to fit the card.
    var fontSize = size;
    while (true) {
      final builder =
          ui.ParagraphBuilder(
              ui.ParagraphStyle(textAlign: TextAlign.center, maxLines: 1, fontFamily: ColituText.family, fontSize: fontSize),
            )
            ..pushStyle(
              ui.TextStyle(
                color: color,
                fontFamily: ColituText.family,
                fontSize: fontSize,
                fontWeight: weight,
                letterSpacing: spacing * fontSize,
              ),
            )
            ..addText(value);
      final paragraph = builder.build()..layout(const ui.ParagraphConstraints(width: 100000));
      if (paragraph.maxIntrinsicWidth > w - 120 && fontSize > 40) {
        fontSize -= 4;
        continue;
      }
      final box = builder.build()..layout(const ui.ParagraphConstraints(width: w));
      canvas.drawParagraph(box, Offset(0, baseline - box.alphabeticBaseline));
      return;
    }
  }

  image(await _asset(passportShareBgAsset), const Rect.fromLTWH(0, 0, w, h));
  final total = ColituPassport.stamps.length;
  text('COLITU PASSPORT', 170, 40, const Color(0xFFC4B5FD), spacing: 0.35);
  if (stamp != null) {
    final progress = passport.progressOf(stamp.code);
    final level = progress.level;
    final art = levelAsset(stamp.code, level);
    final paint = Paint()..filterQuality = FilterQuality.high;
    if (art == null && level != null && level != StampLevel.diamond) {
      paint.colorFilter = ColorFilter.matrix(materialMatrix(level));
    }
    image(await _asset(art ?? stampAsset(stamp.code)), const Rect.fromLTRB(170, 250, 910, 990), paint);
    final headline = level != null
        ? loc.format('passport.r.levelUnlocked', {'level': levelName(level)})
        : loc.format('passport.r.unlocked', {'country': loc.countryName(stamp.code)});
    text(headline.toUpperCase(), 1120, 96, const Color(0xFFF4F3FA), weight: FontWeight.w700, spacing: 0.02);
    text(
      '${loc.countryName(stamp.code)} · ${loc.format('passport.stampNo', {'n': stampNumber(stamp)})}',
      1200,
      46,
      level != null ? levelColor(level) : ColituColors.lilac,
    );
  } else {
    final cover = await _asset(coverAsset(passport.goals.activeCover(premium)));
    if (cover != null) {
      const height = 820.0;
      final width = height * cover.width / cover.height;
      image(cover, Rect.fromLTWH((w - width) / 2, 240, width, height));
    }
    text(loc['passport.complete'].toUpperCase(), 1200, 88, const Color(0xFFF4F3FA), weight: FontWeight.w700);
  }
  // Collection box: "9 / 10 · country stamps collected".
  final box = RRect.fromRectAndRadius(const Rect.fromLTRB(120, 1320, 960, 1560), const Radius.circular(48));
  canvas
    ..drawRRect(box, Paint()..color = const Color(0x5A3A2F8F))
    ..drawRRect(
      box,
      Paint()
        ..color = const Color(0x669F8CFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  text('${passport.count} / $total', 1440, 92, const Color(0xFFF4F3FA), weight: FontWeight.w700);
  text(loc['passport.s.collected'].toUpperCase(), 1510, 34, const Color(0xFFC4B5FD), spacing: 0.12);
  final m = qrMatrix(passport.social.myDuelLink());
  if (m != null) {
    const side = 170.0;
    final cell = side / m.length;
    const left = (w - side) / 2;
    const top = 1590.0;
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTRB(left - 14, top - 14, left + side + 14, top + side + 14), const Radius.circular(18)),
      Paint()..color = Colors.white,
    );
    final dot = Paint()..color = const Color(0xFF16153A);
    for (var y = 0; y < m.length; y++) {
      for (var x = 0; x < m[y].length; x++) {
        if (m[y][x]) canvas.drawRect(Rect.fromLTWH(left + x * cell, top + y * cell, cell, cell), dot);
      }
    }
  }
  text(identityLine(), 1820, 34, const Color(0xFFC4B5FD));
  text(loc['passport.s.cta'], 1872, 34, const Color(0xFFA9ADC2));

  final picture = recorder.endRecording();
  final rendered = await picture.toImage(w.toInt(), h.toInt());
  final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

/// The text that goes with the card in the share sheet.
String passportShareText(ColituStamp? stamp) {
  final loc = ColituLoc.I;
  final passport = ColituPassport.I;
  if (stamp == null) {
    return loc.format('passport.shareText', {'n': passport.count, 'total': ColituPassport.stamps.length});
  }
  final level = passport.progressOf(stamp.code).level;
  final country = loc.countryName(stamp.code);
  return level != null
      ? loc.format('passport.shareLevelText', {'country': country, 'level': levelName(level)})
      : loc.format('passport.shareStampText', {'country': country});
}

/// Renders the card and opens the system share sheet.
Future<void> sharePassport(BuildContext context, {ColituStamp? stamp, required bool premium}) async {
  final box = context.findRenderObject() as RenderBox?;
  final origin = box != null && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;
  final bytes = await renderPassportCard(stamp: stamp, premium: premium);
  ColituPassport.I.weekly.bump(ExpeditionGoal.share);
  final dir = await FileTool.makeCacheDir();
  final path = p.join(dir, 'colitu-passport.png');
  await File(path).writeAsBytes(bytes);
  try {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, mimeType: 'image/png')],
        text: passportShareText(stamp),
        sharePositionOrigin: origin,
      ),
    );
  } catch (error) {
    debugPrint('Passport share: $error');
  } finally {
    await FileTool.deleteDirIfExists(dir);
  }
}
