import 'dart:typed_data';

/// Web has no filesystem to seek in: `file_picker` hands the whole file over as
/// bytes there, so the uploader slices those directly and never reaches this.
Future<Uint8List> readFileRange(String path, int start, int end) {
  throw UnsupportedError('Reading a file by path is not available on the web.');
}
