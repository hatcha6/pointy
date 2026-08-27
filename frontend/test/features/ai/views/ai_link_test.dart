import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
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
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../../../shared/fake_app_navigation.dart';

/// Records externally-launched URLs so a test can assert a web citation opened
/// in the browser instead of routing through the in-app deep-link handler.
class _FakeUrlLauncher extends Fake
    with MockPlatformInterfaceMixin
    implements UrlLauncherPlatform {
  final List<String> launched = [];

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

/// Streams one assistant reply (so we can render a deep link in its markdown, or
/// attach web-search sources via the done event).
class _ReplyRepo extends AiChatRepository {
  _ReplyRepo(this.reply, {this.sources = const [], this.webSearched = false})
    : super(PosApiService());

  final String reply;
  final List<AiSource> sources;
  final bool webSearched;

  @override
  Stream<AiChatEvent> streamChat({
    int? conversationId,
    required String message,
    List<AiAttachment> attachments = const [],
  }) async* {
    yield AiChatDelta(reply);
    yield AiChatDone(
      conversationId: 1,
      sources: sources,
      webSearched: webSearched,
    );
  }

  @override
  Future<Result<AiUsage>> loadUsage() async => Error(Exception('none'));

  @override
  Future<Result<List<AiConversationSummary>>> loadConversations({
    int page = 1,
  }) async => const Ok([]);
}

void main() {
  testWidgets('tapping a pointy:// link routes via onOpenAiLink', (
    tester,
  ) async {
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

  testWidgets('tapping a web source citation opens it externally', (
    tester,
  ) async {
    final fakeLauncher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = fakeLauncher;

    AiDeepLink? captured;
    final repo = _ReplyRepo(
      'حسب [المصدر](https://example.com/news) فإن السعر ارتفع.',
    );
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

    await tester.tap(find.text('المصدر'));
    await tester.pumpAndSettle();

    // A web URL opens externally and does NOT go through the pointy:// handler.
    expect(captured, isNull);
    expect(fakeLauncher.launched, ['https://example.com/news']);
  });

  testWidgets(
    'a web-searched reply shows a sources indicator that opens a sheet',
    (tester) async {
      final fakeLauncher = _FakeUrlLauncher();
      UrlLauncherPlatform.instance = fakeLauncher;

      final repo = _ReplyRepo(
        'ارتفع سعر الذهب اليوم.',
        webSearched: true,
        sources: const [
          AiSource(
            url: 'https://goldprice.org/news',
            title: 'Gold Price Today',
          ),
          AiSource(url: 'https://news.test/gold', title: 'Gold News'),
        ],
      );
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
          ),
        ),
      );
      await tester.pump();
      await viewModel.sendMessage('كم سعر الذهب؟');
      await tester.pumpAndSettle();

      // The "searched the web" favicon indicator is shown next to the copy action.
      final indicator = find.byTooltip('بحث في الويب');
      expect(indicator, findsOneWidget);

      // Tapping it opens a sheet listing the sources; tapping a source opens it.
      await tester.tap(indicator);
      await tester.pumpAndSettle();
      expect(find.text('المصادر'), findsOneWidget);
      expect(find.text('Gold Price Today'), findsOneWidget);

      await tester.tap(find.text('Gold Price Today'));
      await tester.pumpAndSettle();
      expect(fakeLauncher.launched, contains('https://goldprice.org/news'));
    },
  );
}
