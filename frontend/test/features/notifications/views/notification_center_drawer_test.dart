import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/business_alert.dart';
import 'package:pointy_frontend/src/data/repositories/business_alert_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/notifications/view_models/notification_center_view_model.dart';
import 'package:pointy_frontend/src/features/notifications/views/notification_center_host.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() {
  testWidgets('opens an RTL smart notification drawer from the app bar bell', (
    tester,
  ) async {
    final viewModel = NotificationCenterViewModel(
      _FakeBusinessAlertRepository(
        const BusinessAlertLoadResult(
          digest: BusinessAlertDigest(
            alerts: [
              BusinessAlert(
                id: '1',
                code: 'inventory.out_of_stock',
                type: BusinessAlertType.outOfStock,
                category: BusinessAlertCategory.inventory,
                severity: BusinessAlertSeverity.critical,
                sortScore: 10,
                isHidden: false,
                count: 1,
                primaryLabel: 'قهوة البيت',
                quantity: 0,
                threshold: 5,
              ),
            ],
          ),
        ),
      ),
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: NotificationCenterHost(
            viewModel: viewModel,
            child: const PointyScaffold(
              appBar: PointyAppBar(title: Text('الصفحة')),
              body: Text('المحتوى'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('تنبيه ذكي واحد'), findsOneWidget);

    await tester.tap(find.byTooltip('تنبيه ذكي واحد'));
    await tester.pumpAndSettle();

    expect(find.byType(Drawer), findsOneWidget);
    expect(find.text('التنبيهات الذكية'), findsOneWidget);
    expect(find.text('منتجات نافدة تحتاج إجراء'), findsOneWidget);
    expect(find.text('قهوة البيت: المتاح 0، حد الطلب 5'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.byType(Drawer))),
      TextDirection.rtl,
    );
  });
}

class _FakeBusinessAlertRepository extends BusinessAlertRepository {
  _FakeBusinessAlertRepository(this.result) : super(PosApiService());

  final BusinessAlertLoadResult result;

  @override
  Future<Result<BusinessAlertLoadResult>> loadAlerts() async {
    return Ok(result);
  }

  @override
  Future<Result<BusinessAlert>> dismissAlert(String id) async {
    return Ok(result.digest.alerts.first.copyWith(isHidden: true));
  }
}
