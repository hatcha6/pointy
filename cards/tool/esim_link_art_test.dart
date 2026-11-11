// Draws what the relay needs to picture an eSIM link (cards.dftr.ly/esim/…)
// in a chat app's preview: the eSIM card as the app paints it, and every flag
// as a disc. Run after the flags or the card's look change:
//
//   flutter test tool/esim_link_art_test.dart
//
// It writes relay/internal/cardsweb/assets/esim/{card.png,flags/xx.png}; the
// relay lays a destination's flag over the card (cardsweb/esim_banner.go).
// The flags come out as full-colour PNGs (2 MB together): reduce them to a
// palette before committing (Pillow: quantize(96), optimize) to keep the
// relay's binary small.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/shared/esim_card_art.dart';

const _out = '../relay/internal/cardsweb/assets/esim';

Future<void> _save(WidgetTester tester, GlobalKey key, String path) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path)..createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _font = 'packages/pointy_brand/IBMPlexSansArabic';

void main() {
  setUpAll(() async {
    // The app's own font: the test font draws "eSIM" as blocks.
    final font = FontLoader(_font);
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      font.addFont(
        rootBundle.load(
          'packages/pointy_brand/assets/fonts/IBMPlexSansArabic-$weight.ttf',
        ),
      );
    }
    await font.load();
  });

  testWidgets('the eSIM card and the flags', (tester) async {
    tester.view.physicalSize = const Size(704, 440);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();

    // The card with a globe where a flag goes, as an Arabic page lays it out.
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.rtl,
        child: RepaintBoundary(
          key: key,
          child: const DefaultTextStyle(
            style: TextStyle(fontFamily: _font),
            child: SizedBox(
              width: 704,
              height: 440,
              child: EsimCardArt(name: '', country: ''),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    await _save(tester, key, '$_out/card.png');

    final codes = [
      for (final file in Directory('assets/flags').listSync())
        if (file.path.endsWith('.svg'))
          file.uri.pathSegments.last.replaceAll('.svg', ''),
    ]..sort();
    for (final code in codes) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: key,
              child: EsimFlag(key: ValueKey(code), country: code, width: 320),
            ),
          ),
        ),
      );
      await _settle(tester);
      await _save(tester, key, '$_out/flags/$code.png');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
