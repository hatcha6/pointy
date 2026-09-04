import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'migration_file_range_stub.dart'
    if (dart.library.io) 'migration_file_range_io.dart';

import '../models/migration.dart';
import 'migration_api_client.dart';

/// Live state of one upload, for the progress bar.
class MigrationUploadProgress {
  const MigrationUploadProgress({
    required this.sentBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
  });

  final int sentBytes;
  final int totalBytes;
  final double bytesPerSecond;

  double get fraction =>
      totalBytes <= 0 ? 0 : (sentBytes / totalBytes).clamp(0.0, 1.0);

  /// Time left at the current rate, or null while the rate is not yet
  /// meaningful — a made-up estimate is worse than none.
  Duration? get remaining {
    if (bytesPerSecond <= 0 || totalBytes <= sentBytes) return null;
    final seconds = (totalBytes - sentBytes) / bytesPerSecond;
    if (!seconds.isFinite || seconds > 86400) return null;
    return Duration(seconds: seconds.round());
  }
}

/// Raised when a caller cancels an upload in flight.
class MigrationUploadCancelled implements Exception {
  const MigrationUploadCancelled();

  @override
  String toString() => 'Upload cancelled';
}

/// Sends a database file to the server in resumable chunks.
///
/// The file is gigabytes and the network is a shop's Wi-Fi, so this is built
/// around the assumption that the transfer *will* be interrupted:
///
/// * Bytes are read a chunk at a time from the file on disk, never all at once.
///   A 1.5 GB `Uint8List` is not a thing to ask a till for.
/// * The server's `received_bytes` is the only authority on where the file ends.
///   Every chunk is sent with the offset it belongs at, and if the server
///   disagrees we adopt *its* number and continue from there. Appending blind
///   after a half-delivered request would corrupt the database in a way nothing
///   downstream could detect.
/// * A failed chunk is retried a few times with a backoff before giving up, and
///   giving up still leaves a resumable upload behind rather than a dead one.
class MigrationUploader {
  MigrationUploader(this._client);

  final MigrationApiClient _client;

  static const _maxAttemptsPerChunk = 4;
  static const _retryBackoff = Duration(seconds: 2);

  bool _cancelled = false;

  void cancel() => _cancelled = true;

  /// Uploads [file], resuming an existing [source] when one is given.
  ///
  /// Calls [onProgress] as bytes land. Returns the source once every byte is in;
  /// the caller then calls [MigrationApiClient.completeUpload] to start
  /// preparation.
  Future<MigrationSource> upload(
    PlatformFile file, {
    MigrationSource? resuming,
    void Function(MigrationUploadProgress)? onProgress,
  }) async {
    _cancelled = false;
    final totalBytes = file.size;

    MigrationSource source;
    int chunkSize;
    if (resuming != null && resuming.isUploading) {
      source = resuming;
      chunkSize = MigrationUploadConfig.fallback.chunkSize;
    } else {
      final ticket = await _client.beginUpload(
        filename: file.name,
        sizeBytes: totalBytes,
      );
      source = ticket.source;
      chunkSize = ticket.chunkSize;
    }

    var offset = source.receivedBytes;
    final reader = _MigrationFileReader(file);
    final stopwatch = Stopwatch()..start();
    var bytesThisSession = 0;

    void report() {
      final elapsed = stopwatch.elapsedMicroseconds / 1e6;
      onProgress?.call(
        MigrationUploadProgress(
          sentBytes: offset,
          totalBytes: totalBytes,
          bytesPerSecond: elapsed > 0.5 ? bytesThisSession / elapsed : 0,
        ),
      );
    }

    report();
    try {
      while (offset < totalBytes) {
        if (_cancelled) throw const MigrationUploadCancelled();
        final end = math.min(offset + chunkSize, totalBytes);
        final bytes = await reader.read(offset, end);
        if (bytes.isEmpty) {
          throw Exception('Could not read the file past byte $offset.');
        }

        final result = await _sendWithRetries(source.id, offset, bytes);
        if (result.conflicted) {
          // The server knows where the file really ends. Believe it.
          offset = result.receivedBytes;
          continue;
        }
        bytesThisSession += result.receivedBytes - offset;
        offset = result.receivedBytes;
        report();
      }
    } finally {
      await reader.close();
    }

    return await _client.fetchSource(source.id);
  }

  Future<MigrationChunkResult> _sendWithRetries(
    int sourceId,
    int offset,
    Uint8List bytes,
  ) async {
    Object? lastError;
    for (var attempt = 1; attempt <= _maxAttemptsPerChunk; attempt++) {
      if (_cancelled) throw const MigrationUploadCancelled();
      try {
        return await _client.uploadChunk(
          sourceId: sourceId,
          offset: offset,
          bytes: bytes,
        );
      } on Exception catch (error) {
        lastError = error;
        if (attempt < _maxAttemptsPerChunk) {
          await Future<void>.delayed(_retryBackoff * attempt);
        }
      }
    }
    throw Exception('$lastError');
  }
}

/// Reads byte ranges out of a picked file.
///
/// `file_picker` hands back either a path (desktop and mobile) or the whole
/// file in memory (web, which has no other option). Where there is a path we
/// seek, so memory stays flat no matter how big the database is.
class _MigrationFileReader {
  _MigrationFileReader(this._file);

  final PlatformFile _file;

  Future<Uint8List> read(int start, int end) async {
    final bytes = _file.bytes;
    if (bytes != null) {
      return Uint8List.sublistView(bytes, start, math.min(end, bytes.length));
    }
    final path = _file.path;
    if (path == null) {
      throw Exception('The picked file has neither a path nor its contents.');
    }
    return readFileRange(path, start, end);
  }

  Future<void> close() async {}
}
