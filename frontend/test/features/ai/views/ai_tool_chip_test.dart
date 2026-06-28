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

/// Streams a single tool round (start → done with inputs + a result preview),
/// then a short reply — so the tappable, inspectable chip renders.
class _ToolRepo extends AiChatRepository {
  _ToolRepo() : super(PosApiService());

  @override
  Stream<AiChatEvent> streamChat({
    int? conversationId,
    required String message,
    List<AiAttachment> attachments = const [],
  }) async* {
    yield const AiChatToolActivity(
      name: 'match_invoice_products',
      label: 'مطابقة منتجات الفاتورة',
      phase: 'start',
    );
    yield const AiChatToolActivity(
      name: 'match_invoice_products',
      label: 'مطابقة منتجات الفاتورة',
      phase: 'done',
      ok: true,
      arguments: {
        'lines': [
          {'name': 'بطارية متنقلة'},
        ],
      },
      output: '{"ok": true, "supplier": {"name": "الوفاق"}}',
    );
    yield AiChatDelta('تم');
    yield const AiChatDone(conversationId: 1);
  }

  @override
  Future<Result<AiUsage>> loadUsage() async => Error(Exception('none'));

  @override
  Future<Result<List<AiConversationSummary>>> loadConversations({int page = 1}) async =>
      const Ok([]);
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

Future<void> _pump(WidgetTester tester, AiChatViewModel viewModel) async {
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
      home: AiAssistantScreen(viewModel: viewModel, navigation: _FakeNavigation()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('tapping a tool chip opens the inspector with its inputs + output', (
    tester,
  ) async {
    final viewModel = AiChatViewModel(_ToolRepo());
    addTearDown(viewModel.dispose);

    await _pump(tester, viewModel);
    await viewModel.sendMessage('أنشئ أمر شراء من الفاتورة');
    await tester.pumpAndSettle();

    // The read chip rendered with its label and the tap-to-inspect affordance.
    final chip = find.text('يستعلم عن مطابقة منتجات الفاتورة');
    expect(chip, findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);

    await tester.tap(find.ancestor(of: chip, matching: find.byType(InkWell)).first);
    await tester.pumpAndSettle();

    // The inspector sheet shows both sections and the tool's actual output.
    expect(find.text('المدخلات'), findsOneWidget);
    expect(find.text('النتيجة'), findsOneWidget);
    expect(find.textContaining('الوفاق'), findsWidgets);
  });
}
