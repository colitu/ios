import 'dart:ui';

/// COLITU / VPN lettering traced from the brand banner; shared with the
/// website (web/portal/lib/brand-paths.ts) and the Windows app
/// (Styles/ColituBrand.xaml). Glyphs are 100 units tall.
class BrandGlyph {
  const BrandGlyph(this.letter, this.x, this.width, this.data);

  final String letter;
  final double x;
  final double width;
  final String data;
}

const colituGlyphs = <BrandGlyph>[
  BrandGlyph(
    'C',
    0.0,
    129.6,
    'M126.2 99.6L32.4 99.6L27.9 99.1L21.7 97.6L17.9 96.0L12.5 92.7L7.9 88.5L4.0 83.3L1.2 77.1L-0.2 70.4L-0.1 29.6L2.0 21.2L5.4 14.8L10.4 9.1L15.4 5.3L19.2 3.1L23.3 1.5L30.4 -0.1L38.8 -0.4L119.6 -0.3L126.2 -0.3L127.9 0.3L129.1 1.7L129.5 2.9L129.5 18.8L128.9 21.2L127.1 22.6L34.2 22.6L30.5 23.8L26.5 26.7L24.1 30.4L23.1 35.0L23.3 68.3L24.1 71.2L25.6 73.8L27.5 75.8L30.0 77.6L32.5 78.7L36.2 79.2L127.1 79.3L128.8 80.3L129.5 82.1L129.5 95.8L128.7 98.3L127.5 99.3Z',
  ),
  BrandGlyph(
    'O',
    149.2,
    141.2,
    'M109.2 99.6L30.4 99.5L24.6 98.7L20.0 97.2L15.6 95.0L10.4 91.4L5.8 86.4L2.9 81.7L0.7 75.4L-0.2 68.8L-0.3 33.8L0.2 28.3L1.4 22.9L2.8 19.2L7.0 12.5L12.1 7.4L18.8 3.1L25.4 0.7L32.9 -0.3L110.0 -0.2L115.4 0.8L120.4 2.4L128.8 7.4L133.4 12.1L136.0 15.8L138.5 20.8L140.5 27.5L141.0 33.8L141.0 66.7L140.0 75.0L138.9 78.8L135.9 84.6L132.5 88.9L128.5 92.5L124.6 95.1L119.2 97.6L114.6 98.9ZM105.2 79.2L109.4 78.3L113.4 75.8L115.0 74.1L116.3 71.7L117.4 67.5L117.4 33.3L116.8 30.8L115.4 28.1L113.5 25.8L111.2 24.1L108.3 22.8L105.4 22.3L35.4 22.3L32.5 22.7L29.7 23.8L26.9 25.8L24.9 28.3L23.6 31.2L23.1 34.6L23.1 67.5L23.7 70.4L25.0 73.3L29.3 77.5L32.5 78.8L35.4 79.2Z',
  ),
  BrandGlyph(
    'L',
    312.5,
    116.7,
    'M112.9 99.6L29.6 99.4L23.8 98.3L20.4 97.2L15.0 94.4L10.4 91.0L7.1 87.5L3.2 81.7L1.0 76.2L-0.1 70.4L-0.3 3.8L0.5 0.8L2.9 -0.3L19.6 -0.3L21.7 0.2L23.0 1.7L23.4 3.8L23.5 65.0L24.0 67.9L25.0 70.4L28.3 74.7L33.3 77.7L38.3 78.7L114.2 78.9L115.8 80.0L116.4 81.7L116.4 96.2L115.4 98.6Z',
  ),
  BrandGlyph(
    'I',
    452.5,
    23.8,
    'M20.0 99.6L2.5 99.6L0.8 98.8L-0.1 97.1L-0.2 3.3L0.6 0.8L2.5 -0.2L20.4 -0.3L22.5 0.7L23.3 2.5L23.5 96.2L22.5 98.6Z',
  ),
  BrandGlyph(
    'T',
    498.3,
    134.2,
    'M75.4 99.6L58.3 99.6L56.2 98.8L55.3 97.5L55.0 26.7L54.4 23.8L53.3 23.0L52.1 22.8L4.2 22.9L1.7 22.5L0.3 21.2L-0.1 19.6L-0.1 2.9L0.4 1.3L1.2 0.4L4.2 -0.3L121.2 -0.4L130.8 -0.3L132.9 0.8L133.8 2.9L133.9 19.2L133.3 21.2L131.7 22.6L82.5 22.8L80.4 23.0L79.1 24.2L78.7 27.1L78.7 96.2L77.7 98.8Z',
  ),
  BrandGlyph(
    'U',
    652.5,
    133.8,
    'M102.1 99.6L29.6 99.4L23.3 98.3L18.3 96.3L14.2 93.9L9.6 90.3L5.2 85.0L2.8 80.8L1.1 76.2L-0.1 70.0L-0.3 3.3L0.6 0.8L1.7 0.0L3.3 -0.4L19.6 -0.3L21.7 0.2L22.9 1.7L23.3 7.1L23.4 64.6L24.0 67.9L25.0 70.4L28.8 75.1L32.9 77.6L37.5 78.6L84.6 78.7L95.8 78.7L100.4 77.5L103.3 75.8L105.7 73.8L107.6 71.2L108.8 68.8L109.7 63.8L109.7 3.3L110.2 1.2L111.7 0.0L113.3 -0.3L130.0 -0.3L132.5 0.6L133.5 3.3L133.5 67.1L133.0 72.5L131.8 77.5L128.0 85.0L124.6 89.2L120.8 92.5L112.9 97.1L107.5 98.8Z',
  ),
];
const colituWordmarkWidth = 786.3;

const vpnGlyphs = <BrandGlyph>[
  BrandGlyph(
    'V',
    0.0,
    158.5,
    'M89.2 98.7L80.0 99.9L69.2 99.2L66.2 97.7L62.3 93.8L34.9 55.4L-1.4 1.5L0.0 0.7L16.9 0.3L21.5 0.4L24.6 1.8L70.3 67.7L76.9 76.7L78.5 77.1L80.5 75.4L88.1 64.6L121.3 15.4L132.3 0.8L135.4 -0.1L156.9 0.6L158.4 1.5L94.5 93.8Z',
  ),
  BrandGlyph(
    'P',
    178.5,
    143.1,
    'M20.0 98.7L3.1 99.2L-0.3 98.5L-0.8 50.8L0.0 47.4L109.2 46.7L113.8 44.7L117.4 41.5L119.3 36.9L119.2 30.8L116.9 26.6L113.8 23.8L106.2 20.9L1.5 20.7L0.0 20.3L-0.7 18.5L-0.7 3.1L0.0 0.8L6.2 0.1L55.4 -0.2L115.4 0.8L121.5 2.6L127.7 5.9L137.5 15.4L140.5 21.5L142.2 27.7L142.2 40.0L140.6 46.2L137.5 52.3L130.8 59.0L123.1 63.5L112.3 66.8L23.1 67.0L21.5 67.7L20.9 69.2L20.7 96.9Z',
  ),
  BrandGlyph(
    'N',
    341.6,
    144.6,
    'M141.5 99.1L118.5 99.2L113.8 97.5L72.3 64.0L24.6 27.2L23.1 27.3L22.3 29.2L22.1 96.9L21.3 98.5L18.5 99.2L0.0 98.7L-0.8 95.4L-0.8 20.0L-0.8 3.1L0.0 0.4L23.1 0.2L27.7 1.2L90.8 51.4L116.9 71.3L120.0 72.3L120.8 69.2L121.0 1.5L123.1 0.1L140.0 0.5L142.9 1.5L143.8 10.8L143.8 93.8L143.1 98.4Z',
  ),
];
const vpnWordmarkWidth = 486.2;

/// Builds one [Path] for a glyph list; the brand paths only use M, L and Z
/// commands, so no general SVG parser is needed.
Path buildWordmarkPath(List<BrandGlyph> glyphs) {
  final path = Path()..fillType = PathFillType.evenOdd;
  final token = RegExp(r'([MLZ])|(-?\d+(?:\.\d+)?)');
  for (final glyph in glyphs) {
    String? command;
    final numbers = <double>[];
    for (final match in token.allMatches(glyph.data)) {
      final letter = match.group(1);
      if (letter != null) {
        if (letter == 'Z') path.close();
        command = letter;
        numbers.clear();
        continue;
      }
      numbers.add(double.parse(match.group(2)!));
      if (numbers.length == 2) {
        final x = glyph.x + numbers[0];
        final y = numbers[1];
        if (command == 'M') {
          path.moveTo(x, y);
          command = 'L';
        } else {
          path.lineTo(x, y);
        }
        numbers.clear();
      }
    }
  }
  return path;
}
