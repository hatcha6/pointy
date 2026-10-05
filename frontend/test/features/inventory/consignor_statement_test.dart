import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/consignor_statement.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/features/inventory/pdf/consignment_document_content.dart';
import 'package:pointy_frontend/src/features/inventory/view_models/consignor_statement_view_model.dart';
import 'package:pointy_frontend/src/features/inventory/views/consignor_statement_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import 'consignor_statement_fixtures.dart';

AuthorizationCapabilities _capabilities({bool manager = true}) {
  return AuthorizationCapabilities.forUser(
    PosUser(
      id: 1,
      username: 'owner',
      role: manager ? UserRole.manager : UserRole.cashier,
      isActive: true,
      serializedInventoryEnabled: true,
      hasPermissionSnapshot: !manager,
      permissions: manager
          ? const {}
          : const {'inventory.view_consignment_liability'},
    ),
  );
}

Widget _app(Widget child) {
  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: PointyTheme.light(),
    builder: (context, inner) => PointyNavigationRailScope(
      isActive: false,
      controller: PointyNavigationRailController(),
      child: inner ?? const SizedBox.shrink(),
    ),
    home: child,
  );
}

void main() {
  group('ConsignorStatementPage.fromJson', () {
    test('reads the headline, the reminders and every line state', () {
      final page = ConsignorStatementPage.fromJson(statementJson());

      expect(page.statement.consignorName, 'سالم الورفلي');
      expect(page.statement.figures.payable, 13450);
      expect(page.statement.figures.shopCommission, 3350);
      expect(page.statement.reminders.enabled, isTrue);
      expect(page.statement.reminders.everyDays, 30);
      expect(page.lines.map((line) => line.state), [
        'awaiting',
        'awaiting',
        'held',
        'held',
        'paid',
        'returned',
      ]);
      final first = page.lines.first;
      expect(first.lastReminder?.round, 1);
      expect(first.lastReminder?.failed, isFalse);
      expect(page.lines[1].soldOnCredit, isTrue);
      expect(page.lines[2].payoutIsEstimate, isTrue);
      expect(page.hasNext, isFalse);
    });

    test('a commission the server left out stays null, not zero', () {
      final page = ConsignorStatementPage.fromJson(
        statementJson(withCommission: false),
      );

      expect(page.statement.figures.shopCommission, isNull);
    });
  });

  group('ConsignorStatementViewModel', () {
    test('pages, and a failed page keeps the list open for a retry', () async {
      final repository = FakeStatementRepository({
        1: statementJson(hasNext: true),
        2: statementJson(),
      });
      final viewModel = ConsignorStatementViewModel(
        repository,
        consignorId: 42,
      );

      await viewModel.load();
      expect(viewModel.lines, hasLength(6));
      expect(viewModel.hasMore, isTrue);

      repository.failNext = true;
      await viewModel.loadMore();
      expect(viewModel.loadMoreFailed, isTrue);
      expect(viewModel.hasMore, isTrue, reason: 'load-more-dead-end');

      await viewModel.loadMore();
      expect(viewModel.lines, hasLength(12));
      expect(viewModel.hasMore, isFalse);
      expect(repository.calls.map((call) => call.page), [1, 2, 2]);
    });

    test('a filter asks the server for its states', () async {
      final repository = FakeStatementRepository({1: statementJson()});
      final viewModel = ConsignorStatementViewModel(
        repository,
        consignorId: 42,
      );
      await viewModel.load();

      viewModel.setFilter(ConsignorLineFilter.closed);
      await Future<void>.delayed(Duration.zero);

      expect(repository.calls.last.states, ['returned', 'lost']);
    });

    test('pay all pays the awaiting lines, net, on one voucher', () async {
      final repository = FakeStatementRepository({1: statementJson()});
      final viewModel = ConsignorStatementViewModel(
        repository,
        consignorId: 42,
      );
      await viewModel.load();

      viewModel.selectAllAwaiting();
      expect(viewModel.selectedTotal, 13450);
      // Only awaiting lines can be picked.
      viewModel.toggle(viewModel.lines[2]);
      expect(viewModel.selected, {11, 12});

      final payout = await viewModel.disburse();

      expect(payout?.number, 'CP2026100500009');
      expect(repository.disbursed, [11, 12]);
      expect(viewModel.selected, isEmpty);
    });
  });

  group('the printed statement', () {
    test('is the consignor copy: no sale prices, owed now as the total', () {
      final page = ConsignorStatementPage.fromJson(statementJson());

      final content = buildConsignorStatementContent(
        statement: page.statement,
        lines: page.lines,
        printedAt: DateTime(2026, 10, 5, 9, 30),
      );

      expect(content.badge, 'كشف حساب أمانات');
      expect(content.total?.value, contains('13450.00'));
      expect(content.tableFlex, hasLength(content.tableColumns.length));
      expect(content.tableRows, hasLength(6));
      // 12,500 is what the Rolex sold for; under a fixed payout it is the
      // shop's margin and stays off the consignor's copy.
      expect(content.allText.join(' '), isNot(contains('12500')));
      expect(content.allText.join(' '), isNot(contains('3350')));
    });
  });

  group('ConsignorStatementScreen', () {
    testWidgets('leads with what is owed and says the money stays theirs', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final viewModel = ConsignorStatementViewModel(
        FakeStatementRepository({1: statementJson()}),
        consignorId: 42,
      );

      await tester.pumpWidget(
        _app(
          ConsignorStatementScreen(
            viewModel: viewModel,
            capabilities: _capabilities(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('سالم الورفلي'), findsOneWidget);
      expect(
        find.textContaining('ولا يتحول إلى دخل للمحل', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('صرف كل المستحقات'), findsOneWidget);
      expect(find.text('ساعة رولكس ديت جست 36'), findsOneWidget);

      await tester.tap(find.text('ساعة رولكس ديت جست 36'));
      await tester.pumpAndSettle();

      expect(find.text('صرف المستحقات'), findsOneWidget);
    });

    testWidgets('a counter without the payout right cannot pick lines', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final viewModel = ConsignorStatementViewModel(
        FakeStatementRepository({1: statementJson(withCommission: false)}),
        consignorId: 42,
      );

      await tester.pumpWidget(
        _app(
          ConsignorStatementScreen(
            viewModel: viewModel,
            capabilities: _capabilities(manager: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('صرف كل المستحقات'), findsNothing);
      expect(find.text('عمولة المحل'), findsNothing);
      await tester.tap(find.text('ساعة رولكس ديت جست 36'));
      await tester.pumpAndSettle();
      expect(viewModel.selected, isEmpty);
    });
  });
}
