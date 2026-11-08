import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/shared/art_image.dart';

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.green, BlendMode.src);
  final image = await recorder.endRecording().toImage(4, 4);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

void main() {
  const under = ColoredBox(key: Key('under'), color: Colors.red);

  Widget framed(ImageProvider image) => Directionality(
    textDirection: TextDirection.rtl,
    child: Center(
      child: SizedBox(
        width: 160,
        height: 100,
        child: ArtPicture(image: image, under: under),
      ),
    ),
  );

  testWidgets('art in memory is painted in the first frame, placeholder-free', (
    tester,
  ) async {
    final bytes = await tester.runAsync(_png);
    final image = MemoryImage(bytes!);
    await tester.runAsync(() {
      final done = Completer<void>();
      image
          .resolve(ImageConfiguration.empty)
          .addListener(ImageStreamListener((_, _) => done.complete()));
      return done.future;
    });

    await tester.pumpWidget(framed(image));

    expect(find.byKey(const Key('under')), findsNothing);
    final raw = tester.widget<RawImage>(find.byType(RawImage));
    expect(raw.image, isNotNull);
  });

  testWidgets('art not yet in memory shows what stands under it', (
    tester,
  ) async {
    final bytes = await tester.runAsync(_png);
    final fresh = MemoryImage(Uint8List.fromList([...bytes!]), scale: 2);

    await tester.pumpWidget(framed(fresh));

    expect(find.byKey(const Key('under')), findsOneWidget);
  });

  testWidgets('art that fails shows what stands under it', (tester) async {
    final broken = MemoryImage(Uint8List.fromList(const [1, 2, 3]));

    await tester.pumpWidget(framed(broken));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(find.byKey(const Key('under')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
