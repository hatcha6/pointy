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
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

/// Records the message handed to [streamChat] so the auto-send path can be
/// asserted, and terminates the stream immediately so the screen settles.
class _RecordingRepo extends AiChatRepository {
  _RecordingRepo() : super(PosApiService());

  String? sentMessage;

  @override
  Future<Result<List<AiConversationSummary>>> loadConversations({
    int page = 1,
  }) async => const Ok([]);

  @override
  Future<Result<AiUsage>> loadUsage() async => Error(Exception('none'));

  @override
  Stream<AiChatEvent> streamChat({
    int? conversationId,
    required String message,
    List<AiAttachment> attachments = const [],
  }) async* {
    sentMessage = message;
    yield const AiChatDone(conversationId: 1, messageId: 2, userMessageId: 1);
  }
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
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}

Future<void> _pump(
  WidgetTester tester,
  AiChatViewModel viewModel, {
  String? initialPrompt,
  bool autoSend = false,
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
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: AiAssistantScreen(
        viewModel: viewModel,
        navigation: _FakeNavigation(),
        initialPrompt: initialPrompt,
        autoSendInitialPrompt: autoSend,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a seed prompt pre-fills the composer without sending it', (
    tester,
  ) async {
    final repo = _RecordingRepo();
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await _pump(tester, viewModel, initialPrompt: 'لماذا انخفضت المبيعات؟');

    // The question is waiting in the input, ready to tweak — nothing was sent.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'لماذا انخفضت المبيعات؟');
    expect(repo.sentMessage, isNull);
    expect(viewModel.hasMessages, isFalse);
  });

  testWidgets('autoSend fires the seed prompt immediately', (tester) async {
    final repo = _RecordingRepo();
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await _pump(
      tester,
      viewModel,
      initialPrompt: 'اقترح إعادة الطلب',
      autoSend: true,
    );

    // It went straight to the model and shows as a sent turn.
    expect(repo.sentMessage, 'اقترح إعادة الطلب');
    expect(viewModel.hasMessages, isTrue);
    // The composer is left empty, not pre-filled, since the turn was sent.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, isEmpty);
  });

  testWidgets('no seed prompt leaves the screen blank (drawer-launched case)', (
    tester,
  ) async {
    final repo = _RecordingRepo();
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);

    await _pump(tester, viewModel);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, isEmpty);
    expect(repo.sentMessage, isNull);
    expect(viewModel.hasMessages, isFalse);
  });
}
