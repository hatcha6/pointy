import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/ai_chat.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/ai_chat_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/ai/view_models/ai_chat_view_model.dart';
import 'package:pointy_frontend/src/features/ai/views/ai_assistant_screen.dart';
import 'package:pointy_frontend/src/features/ai/voice_recording.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

class _EmptyRepo extends AiChatRepository {
  _EmptyRepo() : super(PosApiService());

  @override
  Future<Result<List<AiConversationSummary>>> loadConversations({
    int page = 1,
  }) async => const Ok([]);

  @override
  Future<Result<AiUsage>> loadUsage() async => Error(Exception('none'));
}

class _FakeNavigation implements AppNavigation {
  @override
  PosUser get currentUser => const PosUser(
    id: 1,
    username: 'manager',
    role: UserRole.manager,
    isActive: true,
    aiAvailable: true,
  );

  @override
  AuthorizationCapabilities get capabilities =>
      AuthorizationCapabilities.forUser(currentUser);

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}

class _FakeVoiceRecorder implements VoiceRecorder {
  _FakeVoiceRecorder({this.permission = true});

  final bool permission;
  final StreamController<Uint8List> controller = StreamController<Uint8List>();

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<Stream<Uint8List>> start() async => controller.stream;

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!controller.isClosed) {
      await controller.close();
    }
  }
}

Future<void> _pump(
  WidgetTester tester,
  AiChatViewModel viewModel,
  VoiceRecorder recorder,
) async {
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
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: AiAssistantScreen(
        viewModel: viewModel,
        navigation: _FakeNavigation(),
        voiceRecorder: recorder,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('mic shows when empty; send arrow takes over while typing', (
    tester,
  ) async {
    final viewModel = AiChatViewModel(_EmptyRepo());
    addTearDown(viewModel.dispose);
    final recorder = _FakeVoiceRecorder();
    addTearDown(recorder.dispose);

    await _pump(tester, viewModel, recorder);

    // Resting state: the mic is the trailing action, no send arrow yet.
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsNothing);

    // Typing flips the trailing action to send.
    await tester.enterText(find.byType(TextField), 'مرحبا');
    await tester.pump();
    expect(find.byIcon(Icons.mic_rounded), findsNothing);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);

    // Clearing brings the mic back.
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsNothing);
  });

  testWidgets('tapping the mic swaps the input for the recorder bar', (
    tester,
  ) async {
    final viewModel = AiChatViewModel(_EmptyRepo());
    addTearDown(viewModel.dispose);
    final recorder = _FakeVoiceRecorder();
    addTearDown(recorder.dispose);

    await _pump(tester, viewModel, recorder);

    await tester.tap(find.byIcon(Icons.mic_rounded));
    // Recording mode runs a periodic timer, so we can't pumpAndSettle. Step the
    // permission check + setState, then advance past the 180ms AnimatedSwitcher
    // so the old input row (with its TextField) finishes leaving.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // The recorder bar is now showing: a discard (trash) action appeared and the
    // text field is gone.
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    // Discard to leave recording mode cleanly (cancels the timer).
    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('denied mic permission shows a notice and stays in text mode', (
    tester,
  ) async {
    final viewModel = AiChatViewModel(_EmptyRepo());
    addTearDown(viewModel.dispose);
    final recorder = _FakeVoiceRecorder(permission: false);
    addTearDown(recorder.dispose);

    await _pump(tester, viewModel, recorder);

    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pumpAndSettle();

    // No recorder bar: the input row stays, and a permission notice is shown.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.aiAssistantMicPermissionDenied), findsOneWidget);
  });
}
