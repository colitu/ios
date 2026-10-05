import 'package:colitu_vpn/colitu/brand/brand_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('COLITU wordmark path spans the shared brand width', () {
    final bounds = buildWordmarkPath(colituGlyphs).getBounds();
    expect(bounds.left, closeTo(0, 1));
    expect(bounds.right, closeTo(colituWordmarkWidth, 1));
    expect(bounds.top, closeTo(0, 1));
    expect(bounds.bottom, closeTo(100, 1));
  });

  test('VPN wordmark path spans the shared brand width', () {
    final bounds = buildWordmarkPath(vpnGlyphs).getBounds();
    expect(bounds.right, closeTo(vpnWordmarkWidth, 2));
    expect(bounds.bottom, closeTo(100, 1));
  });

  test('the O keeps its counter (even-odd fill)', () {
    final path = buildWordmarkPath(colituGlyphs);
    // Centre of the O is a hole; the stroke of the O is filled.
    expect(path.contains(const Offset(149.2 + 70, 50)), isFalse);
    expect(path.contains(const Offset(149.2 + 10, 50)), isTrue);
  });
}
