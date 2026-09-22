import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_zxing/flutter_zxing.dart' as zxing;

import 'snapshot_decoder.dart';

/// The still is read, decoded and deleted; only the answer comes back.
Future<SnapshotDecode> decodeSnapshotPlatform(
  String path, {
  required int maxSize,
}) async {
  try {
    final (value, symbology, error) = await compute(_decodeStill, (
      path: path,
      maxSize: maxSize,
    ));
    if (error != null) return SnapshotDecode.failed(error);
    if (value == null) return const SnapshotDecode.blank();
    return SnapshotDecode.read(value: value, symbology: symbology ?? 'unknown');
  } on Object catch (error) {
    // Spawning the worker failed, or it died. Either way this still is lost,
    // and the loop's job is to ask for another one.
    return SnapshotDecode.failed(error);
  } finally {
    _discard(path);
  }
}

/// Runs in a worker isolate. Only primitives cross the port, so nothing here
/// depends on an exception type surviving the trip.
Future<(String?, String?, String?)> _decodeStill(
  ({String path, int maxSize}) request,
) async {
  try {
    final code = await zxing.zx.readBarcodeImagePathString(
      request.path,
      _params(request.maxSize),
    );
    final text = code.text?.trim();
    if (!code.isValid || text == null || text.isEmpty) {
      return (null, null, null);
    }
    return (text, zxingSymbologyName(code.format), null);
  } on Object catch (error) {
    return (null, null, error.toString());
  }
}

/// What the lab learned, as decoder settings.
///
/// `tryRotate` and `tryHarder` are both on because a cashier puts an item down
/// however it lands: with `tryHarder` off, a tilted EAN-13 sat unread for 14.7
/// seconds — 59 consecutive failed attempts while sharp and still — because
/// the linear scanner sweeps a few rows along one axis and nothing crossed the
/// bars. Off the UI isolate, what that costs is a worker's milliseconds.
zxing.DecodeParams _params(int maxSize) => zxing.DecodeParams(
  format: zxing.Format.any,
  tryHarder: true,
  tryRotate: true,
  tryInverted: true,
  maxNumberOfSymbols: 1,
  // `flutter_zxing` shrinks every image to 768px on its longest edge before
  // looking at it, and that default is the wrong end of the trade here. A
  // still comes off the camera at its FULL sensor resolution — `camera_windows`
  // picks the photo media type with no height cap at all
  // (`FindBaseMediaTypesForSource` passes `0xffffffff`), so the preset only
  // ever constrained the preview. An EAN-13 that occupies a fifth of a 1080p
  // frame is ~380px of the 768 it is being squeezed into, which leaves under
  // two pixels per narrow bar: below what zxing can resolve, so the read fails
  // no matter how hard it tries.
  maxSize: maxSize,
);

/// zxing's format is a bitmask; the wedge policy speaks names, because that is
/// what every other source reports and it must judge them all by the same
/// rule. An unmapped format falls through to the least trusted class, which
/// costs a slower scan rather than a wrong one.
String zxingSymbologyName(int? format) => switch (format) {
  zxing.Format.qrCode => 'QRCode',
  zxing.Format.microQRCode => 'MicroQRCode',
  zxing.Format.dataMatrix => 'DataMatrix',
  zxing.Format.aztec => 'Aztec',
  zxing.Format.pdf417 => 'PDF417',
  zxing.Format.ean13 => 'EAN13',
  zxing.Format.ean8 => 'EAN8',
  zxing.Format.upca => 'UPCA',
  zxing.Format.upce => 'UPCE',
  zxing.Format.code128 => 'Code128',
  zxing.Format.code93 => 'Code93',
  zxing.Format.code39 => 'Code39',
  zxing.Format.itf => 'ITF',
  zxing.Format.codabar => 'Codabar',
  _ => 'unknown',
};

void _discard(String path) {
  try {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  } on Object {
    // A still we cannot delete is not worth failing a scan over; the next one
    // will be along in a moment.
  }
}
