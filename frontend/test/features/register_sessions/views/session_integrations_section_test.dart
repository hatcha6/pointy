import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/register_session_summary.dart';
import 'package:pointy_frontend/src/features/register_sessions/views/session_integrations_section.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

const _none = SessionIntegrationBucketTotals.empty;

SessionIntegrationFigures _figures({
  String provider = 'hdbox',
  SessionIntegrationBucketTotals delivered = _none,
  SessionIntegrationBucketTotals awaiting = _none,
  SessionIntegrationBucketTotals unknown = _none,
  SessionIntegrationBucketTotals refunded = _none,
  SessionIntegrationBucketTotals refundedAfterDelivery = _none,
}) {
  final sold = delivered.amount + awaiting.amount + unknown.amount;
  final cost = delivered.cost + awaiting.cost + unknown.cost;
  return SessionIntegrationFigures(
    provider: provider,
    count: delivered.count + awaiting.count + unknown.count,
    sold: sold,
    cost: cost,
    margin: sold - cost,
    delivered: delivered,
    awaiting: awaiting,
    unknown: unknown,
    refunded: refunded,
    refundedAfterDelivery: refundedAfterDelivery,
  );
}

SessionIntegrationTransaction _transaction(
  int id, {
  String provider = 'hdbox',
  SessionIntegrationBucket bucket = SessionIntegrationBucket.delivered,
  String status = 'confirmed',
  String errorCode = '',
}) {
  return SessionIntegrationTransaction(
    id: id,
    provider: provider,
    orderId: 500 + id,
    receiptNumber: 'R-$id',
    subscriberRef: '2109068034$id',
    optionLabel: 'تجديد شهر',
    price: 30,
    cost: 25,
    status: status,
    bucket: bucket,
    errorCode: errorCode,
  );
}

void main() {
  testWidgets('a shop that resells nothing sees no section', (tester) async {
    await _pump(tester, SessionIntegrations.empty);

    expect(find.byType(SessionIntegrationsSection), findsOneWidget);
    expect(find.text('خدمات الشحن'), findsNothing);
  });

  testWidgets('a clean shift shows the money split and one calm pill', (
    tester,
  ) async {
    final figures = _figures(
      delivered: const SessionIntegrationBucketTotals(
        count: 2,
        amount: 60,
        cost: 50,
      ),
    );
    await _pump(
      tester,
      SessionIntegrations(
        providers: [figures],
        totals: figures,
        transactions: [_transaction(1), _transaction(2)],
      ),
    );

    expect(find.text('خدمات الشحن'), findsOneWidget);
    expect(find.text('HD Box'), findsOneWidget);
    expect(find.text('دفعه الزبائن'), findsOneWidget);
    expect(find.text('حصة المزوّد من رصيد الوكالة'), findsOneWidget);
    expect(find.text('ربح المتجر'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('session_integrations_pill_delivered')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('session_integrations_pill_awaiting')),
      findsNothing,
    );
    // Nothing went astray, so nothing is said about it.
    expect(
      find.byKey(const ValueKey('session_integrations_awaiting')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('session_integrations_unknown')),
      findsNothing,
    );
    // One provider: no "all providers" block repeating the same numbers.
    expect(find.text('كل المزوّدين'), findsNothing);
  });

  testWidgets('every way the money went astray gets its own sentence', (
    tester,
  ) async {
    final figures = _figures(
      delivered: const SessionIntegrationBucketTotals(
        count: 1,
        amount: 30,
        cost: 25,
      ),
      awaiting: const SessionIntegrationBucketTotals(
        count: 1,
        amount: 80,
        cost: 65,
      ),
      unknown: const SessionIntegrationBucketTotals(
        count: 1,
        amount: 45,
        cost: 42.75,
      ),
      refunded: const SessionIntegrationBucketTotals(
        count: 1,
        amount: 30,
        cost: 25,
      ),
      refundedAfterDelivery: const SessionIntegrationBucketTotals(
        count: 1,
        amount: 0,
        cost: 25,
      ),
    );
    await _pump(
      tester,
      SessionIntegrations(providers: [figures], totals: figures),
    );

    expect(
      find.byKey(const ValueKey('session_integrations_awaiting')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('session_integrations_unknown')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('session_integrations_refunded_after_delivery'),
      ),
      findsOneWidget,
    );
    for (final bucket in SessionIntegrationBucket.values) {
      expect(
        find.byKey(ValueKey('session_integrations_pill_${bucket.name}')),
        findsOneWidget,
      );
    }
    // The loss is stated as money, not only as a count.
    expect(find.textContaining('25.00'), findsWidgets);
  });

  testWidgets('several providers are totalled together', (tester) async {
    const delivered = SessionIntegrationBucketTotals(
      count: 1,
      amount: 30,
      cost: 25,
    );
    final hdbox = _figures(delivered: delivered);
    final lnet = _figures(provider: 'lnet', delivered: delivered);
    await _pump(
      tester,
      SessionIntegrations(
        providers: [hdbox, lnet],
        totals: _figures(
          provider: '',
          delivered: const SessionIntegrationBucketTotals(
            count: 2,
            amount: 60,
            cost: 50,
          ),
        ),
      ),
    );

    expect(find.text('HD Box'), findsOneWidget);
    expect(find.text('LNET'), findsOneWidget);
    expect(find.text('كل المزوّدين'), findsOneWidget);
  });

  testWidgets('a transaction opens the sale it was rung up on', (tester) async {
    final figures = _figures(
      awaiting: const SessionIntegrationBucketTotals(
        count: 1,
        amount: 30,
        cost: 25,
      ),
    );
    SessionIntegrationTransaction? opened;
    await _pump(
      tester,
      SessionIntegrations(
        providers: [figures],
        totals: figures,
        transactions: [
          _transaction(
            7,
            bucket: SessionIntegrationBucket.awaiting,
            status: 'pending',
            errorCode: 'insufficient_float',
          ),
        ],
      ),
      onOpenOrder: (transaction) => opened = transaction,
    );

    // Collapsed until asked for: the sentences above already say how much.
    final row = find.byKey(const ValueKey('session_integration_transaction_7'));
    expect(row, findsNothing);
    await tester.tap(find.text('العمليات (1)'));
    await tester.pumpAndSettle();
    expect(row, findsOneWidget);
    // Why it was not performed travels with it.
    expect(find.textContaining('رصيد الوكالة لا يكفي'), findsOneWidget);

    await tester.tap(row);
    expect(opened?.orderId, 507);
  });
}

Future<void> _pump(
  WidgetTester tester,
  SessionIntegrations integrations, {
  ValueChanged<SessionIntegrationTransaction>? onOpenOrder,
}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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
        body: SingleChildScrollView(
          child: SessionIntegrationsSection(
            integrations: integrations,
            onOpenOrder: onOpenOrder,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
