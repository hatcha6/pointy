import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/ai_chat.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/ai_chat_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/ai/view_models/ai_chat_view_model.dart';
import 'package:pointy_frontend/src/features/ai/views/ai_assistant_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/ai_deep_link.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import '../../../shared/fake_app_navigation.dart';

/// Streams one assistant reply (so we can render a deep link in its markdown).
class _ReplyRepo extends AiChatRepository {
  _ReplyRepo(this.reply) : super(PosApiService());

  final String reply;

  @override
  Stream<AiChatEvent> streamChat({
    int? conversationId,
    required String message,
    List<AiAttachment> attachments = const [],
  }) async* {
    yield AiChatDelta(reply);
    yield const AiChatDone(conversationId: 1);
  }

  @override
  Future<Result<AiUsage>> loadUsage() async => Error(Exception('none'));

  @override
  Future<Result<List<AiConversationSummary>>> loadConversations({int page = 1}) async =>
      const Ok([]);
}

void main() {
  testWidgets('tapping a pointy:// link routes via onOpenAiLink', (tester) async {
    AiDeepLink? captured;
    final repo = _ReplyRepo('راجع [المنتج](pointy://product/42) للتأكيد.');
    final viewModel = AiChatViewModel(repo);
    addTearDown(viewModel.dispose);
    const user = PosUser(
      id: 1,
      username: 'manager',
      role: UserRole.manager,
      isActive: true,
      aiAvailable: true,
    );

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
          navigation: FakeAppNavigation(currentUser: user),
          onOpenAiLink: (context, link) async {
            captured = link;
            return true;
          },
        ),
      ),
    );
    await tester.pump();
    await viewModel.sendMessage('hi');
    await tester.pumpAndSettle();

    expect(find.text('المنتج'), findsOneWidget);
    await tester.tap(find.text('المنتج'));
    await tester.pumpAndSettle();

    expect(captured, const AiEntityLink('product', 42));
  });
}
