import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/dashboard_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/dashboard/view_models/dashboard_view_model.dart';
import 'package:pointy_frontend/src/features/dashboard/views/dashboard_screen.dart';

import '../../shared/fake_app_navigation.dart';

const _brief = 'مبيعاتك ثابتة لكن سبعة أصناف أوشكت على النفاد.';
const _lowStockExplainer = 'أعد طلب السكر والحليب قبل النفاد.';

Map<String, Object?> _dashboardJson() => {
  'generated_at': '2026-06-28T09:00:00Z',
  'period': {'days': 30},
  'sections': {
    'sales': {
      'summary': {'net_sales': '1000.00', 'order_count': 20},
      'registers': {'variance_count': 0},
    },
    'inventory': {
      'summary': {'product_count': 10, 'low_stock_count': 7},
      'low_stock_items': [
        {'product_name': 'سكر', 'product_id': 1, 'variant_id': 1},
      ],
    },
  },
};

Map<String, Object?> _digestJson() => {
  'brief': _brief,
  'explainers': {'low_stock': _lowStockExplainer},
  'generated_at': '2026-06-28T09:01:00Z',
};

PosUser _aiManager({bool aiAvailable = true}) => PosUser.fromJson({
  'id': 1,
  'username': 'manager',
  'display_name': 'مدير',
  'email': '',
  'role': 'manager',
  'permissions': const <String>[],
  'is_active': true,
  'ai_available': aiAvailable,
});

Future<void> _pump(
  WidgetTester tester, {
  required PosUser user,
  Map<String, Object?>? digestJson,
  int digestStatus = 200,
  void Function(String? seedPrompt, bool autoSend)? onOpenAiChat,
}) async {
  final apiService = PosApiService(
    client: MockClient((request) async {
      final path = request.url.path;
      if (path.contains('dashboard-digest')) {
        if (digestStatus != 200 || digestJson == null) {
          return http.Response('{"detail":"no"}', digestStatus);
        }
        return http.Response(
          jsonEncode(digestJson),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (path.endsWith('/dashboard/')) {
        return http.Response(
          jsonEncode(_dashboardJson()),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('', 404);
    }),
  );
  final viewModel = DashboardViewModel(DashboardRepository(apiService));
  addTearDown(viewModel.dispose);

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
      home: DashboardScreen(
        viewModel: viewModel,
        capabilities: AuthorizationCapabilities.forUser(user),
        navigation: FakeAppNavigation(
          currentUser: user,
          onOpenAiChat: onOpenAiChat,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the AI brief headline and a per-card explainer', (
    tester,
  ) async {
    await _pump(tester, user: _aiManager(), digestJson: _digestJson());

    expect(find.text(_brief), findsOneWidget);
    expect(find.text(_lowStockExplainer), findsOneWidget);
  });

  testWidgets('tapping the brief auto-sends the briefing prompt', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    String? seed;
    bool? autoSend;
    await _pump(
      tester,
      user: _aiManager(),
      digestJson: _digestJson(),
      onOpenAiChat: (prompt, send) {
        seed = prompt;
        autoSend = send;
      },
    );

    await tester.tap(find.text(_brief));
    await tester.pump();

    expect(seed, l10n.aiDailyBriefSeed);
    expect(autoSend, isTrue);
  });

  testWidgets(
    'tapping an explainer opens the chat seeded with the card topic',
    (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      String? seed;
      bool? autoSend;
      await _pump(
        tester,
        user: _aiManager(),
        digestJson: _digestJson(),
        onOpenAiChat: (prompt, send) {
          seed = prompt;
          autoSend = send;
        },
      );

      await tester.ensureVisible(find.text(_lowStockExplainer));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_lowStockExplainer));
      await tester.pump();

      expect(seed, l10n.aiDigestElaborate(l10n.dashboardLowStockTitle));
      expect(autoSend, isFalse);
    },
  );

  testWidgets('shows no inline AI text when the digest is empty', (
    tester,
  ) async {
    await _pump(
      tester,
      user: _aiManager(),
      digestJson: {'brief': '', 'explainers': {}, 'generated_at': null},
    );

    expect(find.text(_brief), findsNothing);
    expect(find.text(_lowStockExplainer), findsNothing);
  });

  testWidgets('shows nothing when the shop has no AI entitlement (403)', (
    tester,
  ) async {
    await _pump(
      tester,
      user: _aiManager(aiAvailable: false),
      digestStatus: 403,
    );

    expect(find.text(_brief), findsNothing);
    expect(find.text(_lowStockExplainer), findsNothing);
  });
}
