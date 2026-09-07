import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/services/surveillance_api_client.dart';

/// Exercises the multipart reader against the shapes a real socket delivers:
/// a frame split across two reads, several frames in one read, and the
/// timestamp header the players depend on.
void main() {
  Uint8List part(
    List<int> body, {
    String boundary = 'pointyframe',
    DateTime? at,
  }) {
    final header = StringBuffer()
      ..write('--$boundary\r\n')
      ..write('Content-Type: image/jpeg\r\n')
      ..write('Content-Length: ${body.length}\r\n');
    if (at != null) {
      header.write('X-Pointy-Frame-Time: ${at.toIso8601String()}\r\n');
    }
    header.write('\r\n');
    return Uint8List.fromList([
      ...utf8.encode(header.toString()),
      ...body,
      ...utf8.encode('\r\n'),
    ]);
  }

  final jpeg = [0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9];

  test('reads a whole frame from one chunk', () {
    final parser = MjpegParser('pointyframe');
    final frames = parser.consume(part(jpeg)).toList();
    expect(frames, hasLength(1));
    expect(frames.single.bytes, equals(jpeg));
  });

  test('reads a frame split across two chunks', () {
    // The case that matters: TCP hands over 8KB at a time, so a 40KB frame
    // arrives in pieces and none of them is a whole part.
    final parser = MjpegParser('pointyframe');
    final whole = part(jpeg);
    final split = whole.length ~/ 2;
    expect(parser.consume(whole.sublist(0, split)).toList(), isEmpty);
    final frames = parser.consume(whole.sublist(split)).toList();
    expect(frames, hasLength(1));
    expect(frames.single.bytes, equals(jpeg));
  });

  test('reads several frames delivered in one chunk', () {
    final parser = MjpegParser('pointyframe');
    final combined = Uint8List.fromList([
      ...part(jpeg),
      ...part(jpeg),
      ...part(jpeg),
    ]);
    expect(parser.consume(combined).toList(), hasLength(3));
  });

  test('carries the frame time so the scrubber can follow the footage', () {
    final moment = DateTime.utc(2026, 9, 7, 14, 3, 11);
    final parser = MjpegParser('pointyframe');
    final frames = parser.consume(part(jpeg, at: moment)).toList();
    expect(frames.single.capturedAt.toUtc(), equals(moment));
  });

  test('a body containing the boundary text is still read by length', () {
    // Read by Content-Length, never by scanning: JPEG entropy data can and does
    // contain any byte sequence, boundary-shaped ones included.
    final tricky = <int>[
      0xFF,
      0xD8,
      ...utf8.encode('--pointyframe'),
      0xFF,
      0xD9,
    ];
    final parser = MjpegParser('pointyframe');
    final frames = parser.consume(part(tricky)).toList();
    expect(frames, hasLength(1));
    expect(frames.single.bytes, equals(tricky));
  });

  test('honours a non-default boundary', () {
    final parser = MjpegParser('otherline');
    final frames = parser.consume(part(jpeg, boundary: 'otherline')).toList();
    expect(frames, hasLength(1));
  });
}
