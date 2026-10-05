import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../data/models/unit_photo.dart';

/// Where a unit's photos come from: files on a desktop till, the gallery or
/// the camera on a phone. The same two plugins the product image field uses,
/// so no new dependency and no new permission prompt.

/// Desktop image_picker has no camera, so the camera button is only offered
/// where it can work rather than failing on press.
bool get unitCameraSupported =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Several pictures at once: a condition record is the front, the back, the
/// screen and the box, and picking them one at a time is how it does not get
/// done.
Future<List<UnitPhotoUpload>> pickUnitPhotoFiles() async {
  final result = await FilePicker.pickFiles(
    type: FileType.image,
    withData: true,
    allowMultiple: true,
  );
  if (result == null) return const [];
  return [
    for (final file in result.files)
      if (file.bytes case final bytes? when bytes.isNotEmpty)
        UnitPhotoUpload(
          filename: file.name,
          bytes: bytes,
          contentType: _contentTypeFor(file.extension ?? ''),
        ),
  ];
}

/// One photo from the camera, already capped in size by the plugin — the
/// server scales it again either way, but a smaller upload is a faster one.
/// Null when the person backed out; throws when there is no camera.
Future<UnitPhotoUpload?> captureUnitPhoto({ImagePicker? picker}) async {
  final photo = await (picker ?? ImagePicker()).pickImage(
    source: ImageSource.camera,
    maxWidth: 1600,
    maxHeight: 1600,
    imageQuality: 85,
  );
  if (photo == null) return null;
  final bytes = await photo.readAsBytes();
  if (bytes.isEmpty) return null;
  final name = photo.name.trim();
  return UnitPhotoUpload(
    filename: name.contains('.')
        ? name
        : 'unit-${DateTime.now().millisecondsSinceEpoch}.jpg',
    bytes: bytes,
    contentType: photo.mimeType ?? 'image/jpeg',
  );
}

String _contentTypeFor(String extension) {
  return switch (extension.toLowerCase()) {
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' || 'heif' => 'image/heic',
    _ => 'image/jpeg',
  };
}
