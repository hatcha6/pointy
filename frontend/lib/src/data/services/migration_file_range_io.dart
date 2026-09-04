import 'dart:io';
import 'dart:typed_data';

/// Reads bytes `[start, end)` out of a file without loading the rest.
///
/// The whole point of the chunked uploader: a shop's legacy database can be
/// several gigabytes, and holding it in memory to send it is not something a
/// till has the headroom for. `RandomAccessFile` seeks instead.
Future<Uint8List> readFileRange(String path, int start, int end) async {
  final handle = await File(path).open();
  try {
    await handle.setPosition(start);
    return await handle.read(end - start);
  } finally {
    await handle.close();
  }
}
