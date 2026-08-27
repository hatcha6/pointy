import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pointy_frontend/src/data/services/api_session.dart';

/// A chat bubble that spins forever is what an unbounded stream looks like.
/// The AI request travels client -> backend -> relay -> model; any hop can go
/// quiet, and nothing here used to have a deadline or leave a trace.
void main() {
  late List<ApiRequestPerformance> recorded;

  PosApiSession sessionWith(http.Client client) {
    return PosApiSession(baseUrl: 'http://localhost:8000/api/', client: client)
      ..performanceRecorder = recorded.add;
  }

  setUp(() => recorded = <ApiRequestPerformance>[]);

  test('a server that never answers gives up instead of hanging', () async {
    final session = sessionWith(
      _StubClient((_) => Completer<http.StreamedResponse>().future),
    );

    await expectLater(
      session
          .openEventStream(
            'ai/chat/',
            connectTimeout: const Duration(milliseconds: 50),
          )
          .toList(),
      throwsA(
        isA<PosApiException>().having(
          (e) => e.message,
          'message',
          contains('timed out'),
        ),
      ),
    );
    expect(recorded.single.errorMessage, 'stream connect timed out');
  });

  test('a stream that goes quiet mid-turn is closed', () async {
    // The shape a dropped connection takes when no FIN arrives — routine on a
    // shop's link — which left the socket open and the app waiting forever.
    final controller = StreamController<List<int>>();
    addTearDown(controller.close);
    final session = sessionWith(
      _StubClient((_) async => http.StreamedResponse(controller.stream, 200)),
    );

    final events = <SseEvent>[];
    final done = Completer<Object?>();
    session
        .openEventStream(
          'ai/chat/',
          idleTimeout: const Duration(milliseconds: 80),
        )
        .listen(
          events.add,
          // The stream closes right after erroring, so both callbacks fire.
          onError: (Object e) {
            if (!done.isCompleted) done.complete(e);
          },
          onDone: () {
            if (!done.isCompleted) done.complete(null);
          },
        );

    controller.add(utf8.encode('event: delta\ndata: {"text":"hi"}\n\n'));
    final error = await done.future;

    expect(events, hasLength(1));
    expect(
      error,
      isA<PosApiException>().having(
        (e) => e.message,
        'message',
        contains('went quiet'),
      ),
    );
  });

  test('a healthy stream yields its events and is recorded', () async {
    final session = sessionWith(
      _StubClient(
        (_) async => http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode(
              'event: ping\ndata: {}\n\n'
              'event: delta\ndata: {"text":"hello"}\n\n'
              'event: done\ndata: {}\n\n',
            ),
          ),
          200,
        ),
      ),
    );

    final events = await session.openEventStream('ai/chat/').toList();

    expect(events.map((e) => e.event), ['ping', 'delta', 'done']);
    // Streams used to bypass the recorder entirely: not one AI call appeared in
    // 10,079 recorded requests, so a chat that never answered left no trace.
    expect(recorded.single.path, 'ai/chat/');
    expect(recorded.single.statusCode, 200);
    expect(recorded.single.responseSizeBytes, greaterThan(0));
  });

  test('a rejected stream still reports its status', () async {
    final session = sessionWith(
      _StubClient(
        (_) async => http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode('{"detail":"nope"}')),
          500,
        ),
      ),
    );

    await expectLater(
      session.openEventStream('ai/chat/').toList(),
      throwsA(
        isA<PosApiException>().having((e) => e.statusCode, 'status', 500),
      ),
    );
    expect(recorded.single.statusCode, 500);
  });
}

class _StubClient extends http.BaseClient {
  _StubClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}
