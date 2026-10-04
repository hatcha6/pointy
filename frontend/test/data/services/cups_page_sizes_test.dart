import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/services/cups_page_sizes.dart';

/// `lpoptions -l` lines as CUPS 2.4 prints them, from label queues set up the
/// three ways a till can have one (presets with custom sizes, presets that
/// include the label, inch presets only — each left on a 4 x 6 default, which
/// is what the XP-235B's queue was on), and the real HPRT LPQ80 queue.
const _customQueue =
    'PageSize/Media Size: Custom.WIDTHxHEIGHT *w288h432 w288h288 w288h216 '
    'w288h144 w216h144 w144h72 w142h85 w113h71 w162h113\n'
    'Resolution/Resolution: *203dpi\n'
    'ColorModel/Color Mode: *Gray\n';
const _presetQueue =
    'PageSize/Media Size: *w288h432 w288h288 w288h216 w288h144 w216h144 '
    'w144h72 w142h85 w113h71 w162h113\n'
    'Resolution/Resolution: *203dpi\n';
const _inchQueue =
    'PageSize/Media Size: *w288h432 w288h288 w288h216 w288h144 w216h144 '
    'w144h72\n'
    'Resolution/Resolution: *203dpi\n';
const _lpq80Queue =
    'PageSize/PageSize: Custom.WIDTHxHEIGHT *Roll80mm\n'
    'Resolution/Resolution: *203x203dpi\n'
    'PaperSaveBottom/Paper Save Bottom: 0 *1\n';

void main() {
  group('reading a queue', () {
    test('finds the sizes, the default and whether any size goes', () {
      final custom = CupsPageSizes.parse(_customQueue)!;
      expect(custom.acceptsCustom, isTrue);
      expect(custom.defaultChoice, 'w288h432');
      expect(custom.choices, contains('w142h85'));
      expect(custom.choices, isNot(contains('Custom.WIDTHxHEIGHT')));

      final presets = CupsPageSizes.parse(_presetQueue)!;
      expect(presets.acceptsCustom, isFalse);
      expect(presets.defaultChoice, 'w288h432');

      final lpq80 = CupsPageSizes.parse(_lpq80Queue)!;
      expect(lpq80.acceptsCustom, isTrue);
      expect(lpq80.defaultChoice, 'Roll80mm');
    });

    test('says nothing for a queue with no page sizes', () {
      expect(CupsPageSizes.parse('Resolution/Resolution: *203dpi\n'), isNull);
      expect(CupsPageSizes.parse(''), isNull);
    });
  });

  group('naming a 50 x 30 mm sticker', () {
    test('over a saved 4 x 6 default, as itself when any size goes', () {
      // `media` alone lost to the saved `PageSize=w288h432` that CUPS adds to
      // every job: the driver was told the label is 4 x 6 in.
      expect(cupsPageOptions(CupsPageSizes.parse(_customQueue), 50, 30), [
        '-o',
        'media=Custom.50x30mm',
        '-o',
        'PageSize=Custom.50x30mm',
      ]);
    });

    test('as the driver\'s own matching size when that is all it takes', () {
      expect(cupsPageOptions(CupsPageSizes.parse(_presetQueue), 50, 30), [
        '-o',
        'media=w142h85',
        '-o',
        'PageSize=w142h85',
      ]);
    });

    test('never as a custom size a driver cannot take', () {
      // A `PageSize=Custom.…` the driver cannot mark is dropped, and the saved
      // 4 x 6 default comes straight back — worse than not saying it.
      final options = cupsPageOptions(CupsPageSizes.parse(_inchQueue), 50, 30);
      expect(options, ['-o', 'media=Custom.50x30mm']);
    });

    test('as media alone when the queue cannot be read', () {
      expect(cupsPageOptions(null, 50, 30), ['-o', 'media=Custom.50x30mm']);
    });

    test('an offset run-up is a page no preset has', () {
      // 3 mm of run-up makes the page 53 mm wide: on a preset-only driver
      // there is nothing to call it, which is why the offset never took.
      final sizes = CupsPageSizes.parse(_presetQueue)!;
      expect(sizes.choiceFor(53, 30), isNull);
      final mismatch = sizes.mismatchFor(53, 30);
      expect(mismatch.requestedWidthMm, 53);
      expect(mismatch.printedWidthMm, closeTo(101.6, 0.01));
      expect(mismatch.printedHeightMm, closeTo(152.4, 0.01));
    });
  });

  test('a default named without a size is reported without one', () {
    final sizes = const CupsPageSizes(
      choices: ['Roll80mm'],
      acceptsCustom: false,
      defaultChoice: 'Roll80mm',
    );
    final mismatch = sizes.mismatchFor(40, 25);
    expect(mismatch.knowsPrintedSize, isFalse);
  });

  group('the size a keyword names', () {
    test('reads points, inches and millimetres', () {
      final w288h432 = cupsPageSizeMm('w288h432')!;
      expect(w288h432.widthMm, closeTo(101.6, 0.01));
      expect(w288h432.heightMm, closeTo(152.4, 0.01));
      expect(cupsPageSizeMm('4x6')!.heightMm, closeTo(152.4, 0.01));
      expect(cupsPageSizeMm('4x6in')!.widthMm, closeTo(101.6, 0.01));
      expect(cupsPageSizeMm('50x30mm')!.widthMm, 50);
      expect(cupsPageSizeMm('Label60x40')!.heightMm, 40);
    });

    test('leaves a name that is only a name alone', () {
      expect(cupsPageSizeMm('Roll80mm'), isNull);
      expect(cupsPageSizeMm('Letter'), isNull);
    });
  });
}
