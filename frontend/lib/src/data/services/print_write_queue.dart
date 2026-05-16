import 'dart:async';

class PrintWriteQueue {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _tail = _tail
        .then((_) async {
          try {
            completer.complete(await task());
          } on Object catch (error, stackTrace) {
            completer.completeError(error, stackTrace);
          }
        })
        .catchError((_) {});
    return completer.future;
  }
}

Iterable<List<int>> byteChunks(List<int> bytes, int size) sync* {
  for (var offset = 0; offset < bytes.length; offset += size) {
    final end = offset + size > bytes.length ? bytes.length : offset + size;
    yield bytes.sublist(offset, end);
  }
}
