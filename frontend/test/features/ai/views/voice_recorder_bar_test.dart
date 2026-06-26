import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/features/ai/views/voice_recorder_bar.dart';
import 'package:pointy_frontend/src/features/ai/voice_recording.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// A [VoiceRecorder] the test drives directly: PCM chunks are pushed through
/// [controller] to simulate the microphone. (The bar assumes permission was
/// already granted by the host, so it never calls hasPermission.)
class _FakeVoiceRecorder implements VoiceRecorder {
  final StreamController<Uint8List> controller = StreamController<Uint8List>();
  bool started = false;
  bool stopped = false;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<Uint8List>> start() async {
    started = true;
    return controller.stream;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> dispose() async {
    if (!controller.isClosed) {
      await controller.close();
    }
  }
}

Future<void> _pumpBar(
  WidgetTester tester, {
  required VoiceRecorder recorder,
  required void Function(Uint8List, Duration) onSend,
  required VoidCallback onCancel,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      home: Scaffold(
        body: Center(
          child: VoiceRecorderBar(
            recorder: recorder,
            onSend: onSend,
            onCancel: onCancel,
          ),
        ),
      ),
    ),
  );
  // Let start() resolve and the stream subscription attach.
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('starts recording and shows the running timer + actions', (
    tester,
  ) async {
    final recorder = _FakeVoiceRecorder();
    addTearDown(recorder.dispose);

    await _pumpBar(
      tester,
      recorder: recorder,
      onSend: (_, _) {},
      onCancel: () {},
    );

    expect(recorder.started, isTrue);
    expect(find.text('0:00'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);

    // Discard so no periodic timer outlives the test.
    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pumpAndSettle();
  });

  testWidgets('captures PCM and sends a WAV when send is tapped', (
    tester,
  ) async {
    final recorder = _FakeVoiceRecorder();
    addTearDown(recorder.dispose);
    Uint8List? sentBytes;
    Duration? sentDuration;

    await _pumpBar(
      tester,
      recorder: recorder,
      onSend: (bytes, duration) {
        sentBytes = bytes;
        sentDuration = duration;
      },
      onCancel: () {},
    );

    // Feed a chunk of full-scale PCM, then advance the duration ticker once.
    recorder.controller.add(Uint8List.fromList(List<int>.filled(640, 0x7F)));
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(recorder.stopped, isTrue);
    expect(sentBytes, isNotNull);
    expect(ascii.decode(sentBytes!.sublist(0, 4)), 'RIFF');
    // 44-byte header + the 640 PCM bytes we pushed.
    expect(sentBytes!.length, 44 + 640);
    expect(sentDuration, isNotNull);
  });

  testWidgets('discards the recording when cancel is tapped', (tester) async {
    final recorder = _FakeVoiceRecorder();
    addTearDown(recorder.dispose);
    var sendCalls = 0;
    var cancelCalls = 0;

    await _pumpBar(
      tester,
      recorder: recorder,
      onSend: (_, _) => sendCalls++,
      onCancel: () => cancelCalls++,
    );

    recorder.controller.add(Uint8List.fromList(List<int>.filled(64, 5)));
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pumpAndSettle();

    expect(cancelCalls, 1);
    expect(sendCalls, 0);
    expect(recorder.stopped, isTrue);
  });

  testWidgets('tapping send with nothing captured cancels instead', (
    tester,
  ) async {
    final recorder = _FakeVoiceRecorder();
    addTearDown(recorder.dispose);
    var sendCalls = 0;
    var cancelCalls = 0;

    await _pumpBar(
      tester,
      recorder: recorder,
      onSend: (_, _) => sendCalls++,
      onCancel: () => cancelCalls++,
    );

    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(sendCalls, 0);
    expect(cancelCalls, 1);
  });
}
