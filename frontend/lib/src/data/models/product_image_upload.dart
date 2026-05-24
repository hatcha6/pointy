import 'dart:typed_data';

class ProductImageUpload {
  const ProductImageUpload({
    required this.filename,
    required this.bytes,
    required this.contentType,
  });

  final String filename;
  final Uint8List bytes;
  final String contentType;
}
