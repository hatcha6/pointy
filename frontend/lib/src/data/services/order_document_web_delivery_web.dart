@JS()
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'order_document_action.dart';

class OrderDocumentWebDelivery {
  const OrderDocumentWebDelivery();

  String get deliveryChannel {
    return _isMobilePlatform ? 'native_share_sheet' : 'file_save_dialog';
  }

  Future<OrderDocumentActionStatus> deliverPdf({
    required Uint8List bytes,
    required String filename,
    String? subject,
  }) async {
    if (bytes.isEmpty) {
      return OrderDocumentActionStatus.failed;
    }

    if (_isMobilePlatform) {
      final shareStatus = await _shareWithNativeSheet(
        bytes: bytes,
        filename: filename,
        subject: subject,
      );
      if (shareStatus != null) {
        return shareStatus;
      }
      return _downloadPdf(bytes: bytes, filename: filename);
    }

    final saveStatus = await _saveWithPicker(bytes: bytes, filename: filename);
    if (saveStatus != null) {
      return saveStatus;
    }
    return _downloadPdf(bytes: bytes, filename: filename);
  }

  bool get _isMobilePlatform {
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return true;
    }
    final userAgent = web.window.navigator.userAgent.toLowerCase();
    return userAgent.contains('android') ||
        userAgent.contains('iphone') ||
        userAgent.contains('ipad') ||
        userAgent.contains('ipod') ||
        userAgent.contains('mobile');
  }

  Future<OrderDocumentActionStatus?> _shareWithNativeSheet({
    required Uint8List bytes,
    required String filename,
    String? subject,
  }) async {
    if (!web.window.navigator.hasProperty('share'.toJS).toDart) {
      return null;
    }

    final file = web.File(
      [_pdfBlob(bytes)].toJS,
      filename,
      web.FilePropertyBag(type: _pdfMimeType),
    );
    final shareData = web.ShareData(
      files: [file].toJS,
      title: subject ?? filename,
      text: subject ?? filename,
    );
    if (web.window.navigator.hasProperty('canShare'.toJS).toDart &&
        !web.window.navigator.canShare(shareData)) {
      return null;
    }

    try {
      await web.window.navigator.share(shareData).toDart;
      return OrderDocumentActionStatus.completed;
    } on Object catch (error) {
      return _isCancelError(error)
          ? OrderDocumentActionStatus.canceled
          : OrderDocumentActionStatus.failed;
    }
  }

  Future<OrderDocumentActionStatus?> _saveWithPicker({
    required Uint8List bytes,
    required String filename,
  }) async {
    if (!web.window.hasProperty('showSaveFilePicker'.toJS).toDart) {
      return null;
    }

    try {
      final handle = await web.window
          .callMethod<JSPromise<web.FileSystemFileHandle>>(
            'showSaveFilePicker'.toJS,
            _SaveFilePickerOptions(
              suggestedName: filename,
              types: [_pdfAcceptType()].toJS,
            ),
          )
          .toDart;
      final writable = await handle.createWritable().toDart;
      await writable.write(_pdfBlob(bytes)).toDart;
      await writable.close().toDart;
      return OrderDocumentActionStatus.completed;
    } on Object catch (error) {
      return _isCancelError(error)
          ? OrderDocumentActionStatus.canceled
          : OrderDocumentActionStatus.failed;
    }
  }

  OrderDocumentActionStatus _downloadPdf({
    required Uint8List bytes,
    required String filename,
  }) {
    try {
      final blob = _pdfBlob(bytes);
      final url = web.URL.createObjectURL(blob);
      final link = web.HTMLAnchorElement()
        ..href = url
        ..download = filename
        ..style.display = 'none';
      web.document.body?.append(link);
      link.click();
      link.remove();
      web.URL.revokeObjectURL(url);
      return OrderDocumentActionStatus.completed;
    } on Object {
      return OrderDocumentActionStatus.failed;
    }
  }

  web.Blob _pdfBlob(Uint8List bytes) {
    return web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: _pdfMimeType));
  }

  _FilePickerAcceptType _pdfAcceptType() {
    final accept = JSObject()
      ..setProperty(_pdfMimeType.toJS, ['.pdf'.toJS].toJS);
    return _FilePickerAcceptType(description: 'PDF', accept: accept);
  }

  bool _isCancelError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('aborterror') || message.contains('cancel');
  }
}

const _pdfMimeType = 'application/pdf';

extension type _SaveFilePickerOptions._(JSObject _) implements JSObject {
  external factory _SaveFilePickerOptions({
    String suggestedName,
    JSArray<_FilePickerAcceptType> types,
  });
}

extension type _FilePickerAcceptType._(JSObject _) implements JSObject {
  external factory _FilePickerAcceptType({String description, JSObject accept});
}
