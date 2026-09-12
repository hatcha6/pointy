import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/intl.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/dashboard_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/dashboard/view_models/dashboard_view_model.dart';
import 'package:pointy_frontend/src/features/dashboard/views/dashboard_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';

import '../../shared/fake_app_navigation.dart';

/// The payment-mix donut and its value/volume switch.
///
/// Cash is most of the money and cards are a bigger share of the *transactions*
/// than of the takings — which is the whole reason the switch exists, and what
/// these numbers are shaped to prove.
Map<String, Object?> _dashboardJson() => {
  'generated_at': '2026-09-12T09:00:00Z',
  'period': {'days': 30},
  'sections': {
    'payments': {
      'summary': {
        'total': '10000.00',
        'commission_total': '0',
        'payment_count': 100,
      },
      'methods': [
        {'method': 'cash', 'total': '9000.00', 'commission': '0', 'count': 40},
        {'method': 'card', 'total': '1000.00', 'commission': '0', 'count': 60},
      ],
    },
  },
};

PosUser _manager() => PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'display_name': 'مدير',
  'email': '',
  'role': 'manager',
  'permissions': <String>[],
  'is_active': true,
  'ai_available': false,
  'surveillance_enabled': false,
});

Future<void> _pump(WidgetTester tester) async {
  configureCurrencySymbol('د.ل', code: 'LYD');
  final apiService = PosApiService(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/dashboard/')) {
        return http.Response(
          jsonEncode(_dashboardJson()),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('', 404);
    }),
  );
  final viewModel = DashboardViewModel(
    DashboardRepository(apiService),
    canRequestAiDigest: () => false,
  );
  addTearDown(viewModel.dispose);
  final user = _manager();

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
      home: DashboardScreen(
        viewModel: viewModel,
        capabilities: AuthorizationCapabilities.forUser(user),
        navigation: FakeAppNavigation(currentUser: user),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// The slice percentages are painted onto the chart's canvas, so the legend and
// the donut's centre are what a widget test can actually read — which is also
// what carries the exact figures for the reader.
final NumberFormat _arabic = NumberFormat.decimalPattern('ar');

/// Scoped to the mix card: the separate "طرق الدفع" list on the same dashboard
/// prints the very same money figures.
Finder _inMixCard(String title, Finder matching) {
  return find.descendant(
    of: find.ancestor(of: find.text(title), matching: find.byType(Card)).first,
    matching: matching,
  );
}

void main() {
  testWidgets('opens on value, with the takings under the donut', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await _pump(tester);

    final title = l10n.dashboardPaymentMixTitle;
    expect(find.text(l10n.dashboardPaymentMixTotalValue), findsOneWidget);
    expect(_inMixCard(title, find.text('9000.00 د.ل')), findsOneWidget);
    expect(_inMixCard(title, find.text('1000.00 د.ل')), findsOneWidget);
  });

  testWidgets('switching to volume re-splits the same methods by count', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await _pump(tester);

    await tester.tap(find.text(l10n.dashboardPaymentMixByCount));
    await tester.pumpAndSettle();

    // 40 of 100 payments were cash, against 90% of the money: the same two
    // methods telling the opposite story, which is the point of the switch.
    final title = l10n.dashboardPaymentMixTitle;
    expect(find.text(l10n.dashboardPaymentMixTotalCount), findsOneWidget);
    expect(_inMixCard(title, find.text(_arabic.format(40))), findsOneWidget);
    expect(_inMixCard(title, find.text(_arabic.format(60))), findsOneWidget);
    // The legend restates every figure in the selected unit, so the money
    // figures must be gone rather than sitting under a count-shaped chart.
    expect(_inMixCard(title, find.text('9000.00 د.ل')), findsNothing);
  });
}
