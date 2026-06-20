import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../data/models/ai_chat.dart';

/// Picks images (gallery/camera) and files, downscales + re-encodes images off
/// the UI isolate, and returns [AiAttachment]s carrying a base64 data URI ready
/// for the relay. Image bytes are kept for an inline thumbnail; file bytes are
/// not (only the data URI travels to the model).
class AiAttachmentPicker {
  AiAttachmentPicker({ImagePicker? imagePicker})
    : _imagePicker = imagePicker ?? ImagePicker();

  final ImagePicker _imagePicker;

  static const int maxImageDimension = 1024;
  static const int jpegQuality = 75;

  Future<AiAttachment?> pickImage({required bool fromCamera}) async {
    final XFile? picked;
    try {
      picked = await _imagePicker.pickImage(
        source: fromCamera ? ImageSource.camera : ImageSource.gallery,
        maxWidth: maxImageDimension.toDouble(),
        maxHeight: maxImageDimension.toDouble(),
        imageQuality: jpegQuality,
      );
    } on Exception {
      // Source unsupported on this platform (e.g. camera on desktop) or denied.
      return null;
    }
    if (picked == null) {
      return null;
    }
    final bytes = await picked.readAsBytes();
    return _imageAttachment(bytes, picked.name);
  }

  Future<List<AiAttachment>> pickFiles() async {
    final FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(allowMultiple: true, withData: true);
    } on Exception {
      return const [];
    }
    if (result == null) {
      return const [];
    }
    final attachments = <AiAttachment>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null) {
        continue;
      }
      final mime = _mimeForExtension(file.extension);
      if (mime.startsWith('image/')) {
        attachments.add(await _imageAttachment(bytes, file.name));
      } else {
        attachments.add(
          AiAttachment(
            kind: AiAttachmentKind.file,
            dataUri: 'data:$mime;base64,${base64Encode(bytes)}',
            name: file.name,
            mime: mime,
          ),
        );
      }
    }
    return attachments;
  }

  Future<AiAttachment> _imageAttachment(Uint8List bytes, String name) async {
    final jpeg = await compute(_encodeDownscaledJpeg, bytes) ?? bytes;
    return AiAttachment(
      kind: AiAttachmentKind.image,
      dataUri: 'data:image/jpeg;base64,${base64Encode(jpeg)}',
      name: _basename(name),
      mime: 'image/jpeg',
      previewBytes: jpeg,
    );
  }

  String _basename(String name) => name.split('/').last.split(r'\').last;
}

/// Decodes, caps the longest edge at [AiAttachmentPicker.maxImageDimension], and
/// re-encodes as JPEG. Returns null when the bytes aren't a decodable image so
/// the caller can fall back to the originals. Runs in a background isolate.
Uint8List? _encodeDownscaledJpeg(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    return null;
  }
  const maxDimension = AiAttachmentPicker.maxImageDimension;
  final oversized =
      decoded.width > maxDimension || decoded.height > maxDimension;
  final resized = oversized
      ? img.copyResize(
          decoded,
          width: decoded.width >= decoded.height ? maxDimension : null,
          height: decoded.height > decoded.width ? maxDimension : null,
        )
      : decoded;
  return Uint8List.fromList(
    img.encodeJpg(resized, quality: AiAttachmentPicker.jpegQuality),
  );
}

String _mimeForExtension(String? extension) {
  switch ((extension ?? '').toLowerCase()) {
    case 'pdf':
      return 'application/pdf';
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    case 'txt':
      return 'text/plain';
    case 'csv':
      return 'text/csv';
    case 'json':
      return 'application/json';
    case 'doc':
      return 'application/msword';
    case 'docx':
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'xls':
      return 'application/vnd.ms-excel';
    case 'xlsx':
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    default:
      return 'application/octet-stream';
  }
}
