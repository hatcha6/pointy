import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_image_picker.dart';

/// Fake that returns a preset photo without touching platform channels.
class _FakeImagePicker extends ImagePicker {
  _FakeImagePicker(this._photo);

  final XFile? _photo;
  int calls = 0;
  ImageSource? lastSource;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    calls++;
    lastSource = source;
    return _photo;
  }
}

CatalogRepository _stubRepository() {
  return CatalogRepository(
    PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((_) async => http.Response('{}', 404)),
    ),
  );
}

Widget _harness({
  required ImagePicker imagePicker,
  required ValueChanged<ProductImageSelection?> onChanged,
}) {
  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: ProductImageField(
        catalogRepository: _stubRepository(),
        initialSearchQuery: 'قهوة',
        selection: null,
        onChanged: onChanged,
        imagePicker: imagePicker,
      ),
    ),
  );
}

void main() {
  testWidgets(
    'camera capture sets an uploaded image selection from the photo',
    (tester) async {
      final picker = _FakeImagePicker(
        XFile.fromData(
          Uint8List.fromList([1, 2, 3, 4]),
          name: 'snap.jpg',
          mimeType: 'image/jpeg',
        ),
      );
      ProductImageSelection? selection;

      await tester.pumpWidget(
        _harness(imagePicker: picker, onChanged: (value) => selection = value),
      );
      await tester.pump();

      final cameraButton = find.widgetWithText(OutlinedButton, 'التقاط صورة');
      expect(cameraButton, findsOneWidget);

      await tester.tap(cameraButton);
      await tester.pumpAndSettle();

      expect(picker.calls, 1);
      expect(picker.lastSource, ImageSource.camera);
      expect(selection, isA<UploadedProductImageSelection>());
      final upload = selection!.upload!;
      expect(upload.bytes, [1, 2, 3, 4]);
      expect(upload.contentType, 'image/jpeg');
      // A real camera filename is used when present, otherwise a generated
      // `camera-<timestamp>.jpg` fallback — both must carry a usable extension.
      expect(upload.filename, endsWith('.jpg'));
    },
  );

  testWidgets('cancelling the camera leaves the selection unchanged', (
    tester,
  ) async {
    final picker = _FakeImagePicker(null); // user backed out
    var changeCount = 0;
    ProductImageSelection? selection;

    await tester.pumpWidget(
      _harness(
        imagePicker: picker,
        onChanged: (value) {
          changeCount++;
          selection = value;
        },
      ),
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(OutlinedButton, 'التقاط صورة'));
    await tester.pumpAndSettle();

    expect(picker.calls, 1);
    expect(changeCount, 0);
    expect(selection, isNull);
  });
}
