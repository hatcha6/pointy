import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/analytics_event.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/analytics_repository.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/activity_log/view_models/activity_log_view_model.dart';
import 'package:pointy_frontend/src/features/activity_log/views/activity_log_event_presenter.dart';
import 'package:pointy_frontend/src/features/activity_log/views/activity_log_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() {
  testWidgets('activity log renders event timeline and details in Arabic', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1280, 820)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = _FakeActivityLogApiService();
    final viewModel = ActivityLogViewModel(
      AnalyticsRepository(service),
      UserRepository(service),
      clock: () => DateTime(2026, 5, 20, 12),
    );
    addTearDown(viewModel.dispose);
    ActivityLogDrillDownTarget? openedTarget;

    await tester.pumpWidget(
      _TestApp(
        child: ActivityLogScreen(
          viewModel: viewModel,
          currentUser: _manager,
          capabilities: AuthorizationCapabilities.forUser(_manager),
          onOpenPos: () {},
          onOpenCatalog: () {},
          onOpenCategories: () {},
          onOpenPurchasing: () {},
          onOpenContacts: () {},
          onOpenRegisterSessions: () {},
          onOpenDeviceSettings: () {},
          onOpenTarget: (context, target) async {
            openedTarget = target;
          },
          onLogout: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('سجل نشاط المستخدمين'), findsOneWidget);
    expect(find.text('اكتملت عملية بيع'), findsWidgets);
    expect(find.textContaining('إيصال'), findsWidgets);
    expect(find.textContaining('cashier'), findsWidgets);
    expect(find.text('مخاطر 82'), findsWidgets);
    expect(service.lastQuery?['activity_scope'], 'reviewable');
    expect(service.lastQuery?['action'], isNull);
    expect(service.lastQuery?['ordering'], '-occurred_at');

    await tester.tap(find.byTooltip('فتح الفاتورة').first);
    await tester.pumpAndSettle();

    expect(openedTarget?.type, ActivityLogDrillDownType.saleOrder);
    expect(openedTarget?.id, 42);
  });
}

class _TestApp extends StatelessWidget {
  const _TestApp({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
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
      home: child,
    );
  }
}

class _FakeActivityLogApiService extends PosApiService {
  Map<String, String>? lastQuery;

  @override
  Future<AnalyticsEventPage> fetchAnalyticsEvents({
    required AnalyticsEventQuery query,
    int page = 1,
  }) async {
    lastQuery = query.toQueryParameters(page: page);
    return AnalyticsEventPage(
      events: [
        AnalyticsEventRecord(
          id: 1,
          clientEventId: 'event-1',
          eventType: AnalyticsEventType.fraudSignal,
          name: 'sales.checkout.completed',
          severity: AnalyticsEventSeverity.warning,
          source: AnalyticsEventSource.backend,
          occurredAt: DateTime.utc(2026, 5, 20, 9, 30),
          receivedBy: 2,
          receivedByUsername: 'cashier',
          entityType: 'sale_order',
          entityId: '42',
          riskScore: 82,
          attributes: {'receipt_number': 'INV-42', 'register_session_id': 7},
          metrics: {'total': 25.5},
        ),
      ],
      hasMore: false,
      totalCount: 1,
    );
  }

  @override
  Future<PosUserPage> fetchUsers({int page = 1}) async {
    return const PosUserPage(users: [_cashier], hasMore: false);
  }
}

const _manager = PosUser(
  id: 1,
  username: 'manager',
  displayName: 'مدير',
  role: UserRole.manager,
  isActive: true,
);

const _cashier = PosUser(
  id: 2,
  username: 'cashier',
  displayName: 'Cashier',
  role: UserRole.cashier,
  isActive: true,
);
