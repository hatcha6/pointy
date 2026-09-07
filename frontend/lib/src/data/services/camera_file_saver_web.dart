// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:typed_data';

import 'camera_file_saver.dart';

/// Web: hand the bytes to the browser, which owns the destination folder.
///
/// A clip has to be buffered here — there is no streaming save in a browser
/// without a service worker — which is one more reason the camera surfaces are
/// built for the native tills first.
Future<CameraSaveResult> saveCameraClipPlatform({
  required Stream<List<int>> bytes,
  required String filename,
  String? dialogTitle,
}) async {
  final chunks = <List<int>>[];
  await for (final chunk in bytes) {
    chunks.add(chunk);
  }
  return _download(chunks, filename, 'video/mp4');
}

Future<CameraSaveResult> saveCameraStillPlatform({
  required Uint8List bytes,
  required String filename,
  String? dialogTitle,
}) async {
  return _download([bytes], filename, 'image/jpeg');
}

CameraSaveResult _download(
  List<List<int>> parts,
  String filename,
  String contentType,
) {
  if (parts.isEmpty) {
    return const CameraSaveResult.failed();
  }
  final blob = html.Blob(parts, contentType);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = filename
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
  return const CameraSaveResult.saved();
}
