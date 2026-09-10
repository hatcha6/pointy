import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/data/services/surveillance_api_client.dart';
import 'package:pointy_frontend/src/features/cameras/widgets/mjpeg_view.dart';

/// The guard against the 2026-09-08 retry loop.
///
/// A shop switched its cameras on, the DVR did not answer, and the tile
/// reconnected on a flat three-second timer forever: 18,160 failed requests in
/// three days, each burning a six-second connect timeout on a thread the tills
/// share. A tile that cannot reach its camera has to get quieter and then stop.
void main() {
  /// Counts connection attempts; every one fails, like an unplugged recorder.
  ({Widget widget, ValueGetter<int> attempts}) failingView({
    Object? error,
    int maxAttempts = 3,
    Duration delay = const Duration(seconds: 1),
    void Function(VoidCallback retry)? captureRetry,
  }) {
    var attempts = 0;
    final widget = MaterialApp(
      home: MjpegView(
        frames: () {
          attempts++;
          return Stream<CameraFrame>.error(
            error ?? StateError('recorder unreachable'),
          );
        },
        reconnectDelay: delay,
        maxReconnectDelay: const Duration(seconds: 8),
        maxReconnectAttempts: maxAttempts,
        errorBuilder: (context, _, retry) {
          captureRetry?.call(retry);
          return const Text('failed');
        },
      ),
    );
    return (widget: widget, attempts: () => attempts);
  }

  testWidgets('waiting doubles between attempts instead of staying flat', (
    tester,
  ) async {
    final view = failingView(maxAttempts: 3);
    await tester.pumpWidget(view.widget);
    await tester.pump();
    expect(view.attempts(), 1, reason: 'the first connection');

    // First retry lands one second later, not before.
    await tester.pump(const Duration(milliseconds: 900));
    expect(view.attempts(), 1, reason: 'still inside the first backoff');
    await tester.pump(const Duration(milliseconds: 200));
    expect(view.attempts(), 2);

    // Second retry waits twice as long: a flat timer would have fired by now.
    await tester.pump(const Duration(milliseconds: 1100));
    expect(view.attempts(), 2, reason: 'the wait must have doubled');
    await tester.pump(const Duration(milliseconds: 1000));
    expect(view.attempts(), 3);

    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('the tile gives up rather than retrying forever', (tester) async {
    final view = failingView(maxAttempts: 2);
    await tester.pumpWidget(view.widget);
    await tester.pump();

    // Far longer than every backoff in the ladder put together.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 10));
    }

    expect(
      view.attempts(),
      lessThanOrEqualTo(3),
      reason: 'one connection plus maxReconnectAttempts retries, then silence',
    );
    expect(find.text('failed'), findsOneWidget);
  });

  testWidgets('a server cooldown is honoured over our own backoff', (
    tester,
  ) async {
    final view = failingView(
      maxAttempts: 3,
      delay: const Duration(seconds: 1),
      error: const PosApiException(
        message: 'cooling down',
        statusCode: 503,
        responseBody: '{"code":"recorder_cooling_down","retry_after":5}',
      ),
    );
    await tester.pumpWidget(view.widget);
    await tester.pump();
    expect(view.attempts(), 1);

    // Our own backoff would have retried at one second; the server asked for
    // five, and the server is the one being protected.
    await tester.pump(const Duration(seconds: 2));
    expect(view.attempts(), 1, reason: 'must wait the full retry_after');
    await tester.pump(const Duration(seconds: 4));
    expect(view.attempts(), 2);

    await tester.pump(const Duration(seconds: 60));
  });

  testWidgets('a permanent refusal is not retried at all', (tester) async {
    // A recorder with no still-image endpoint answers 501 however often it is
    // asked. Spending the whole retry ladder on it rebuilds the loop the ladder
    // exists to stop.
    final view = failingView(
      maxAttempts: 5,
      error: const PosApiException(
        message: 'no snapshot endpoint',
        statusCode: 501,
        responseBody: '{"detail":"This recorder has no still-image endpoint."}',
      ),
    );
    await tester.pumpWidget(view.widget);
    await tester.pump();
    expect(view.attempts(), 1);

    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 20));
    }

    expect(view.attempts(), 1, reason: 'asked once, never again');
    expect(find.text('failed'), findsOneWidget);
  });

  testWidgets('a cooling-down 503 is still retried', (tester) async {
    // The breaker's own answer must stay recoverable — it is temporary by
    // construction, and says so with Retry-After.
    final view = failingView(
      maxAttempts: 3,
      error: const PosApiException(
        message: 'cooling down',
        statusCode: 503,
        responseBody: '{"code":"recorder_cooling_down","retry_after":2}',
      ),
    );
    await tester.pumpWidget(view.widget);
    await tester.pump();
    expect(view.attempts(), 1);

    await tester.pump(const Duration(seconds: 3));
    expect(view.attempts(), 2);

    await tester.pump(const Duration(seconds: 60));
  });

  testWidgets('retry dials again after the tile has given up', (tester) async {
    VoidCallback? retry;
    final view = failingView(
      maxAttempts: 1,
      captureRetry: (callback) => retry = callback,
    );
    await tester.pumpWidget(view.widget);
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));

    final settled = view.attempts();
    await tester.pump(const Duration(seconds: 60));
    expect(view.attempts(), settled, reason: 'nothing retries on its own now');

    expect(retry, isNotNull, reason: 'the error state must offer a way back');
    retry!();
    await tester.pump();
    expect(view.attempts(), settled + 1);

    await tester.pump(const Duration(seconds: 30));
  });
}
