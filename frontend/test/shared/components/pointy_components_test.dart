import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() {
  for (final width in [390.0, 768.0, 1366.0]) {
    testWidgets('state components render localized content at width $width', (
      tester,
    ) async {
      await _pumpSurface(
        tester,
        width: width,
        child: const Column(
          children: [
            Expanded(
              child: PointyEmptyState(
                icon: Icons.inventory_2_outlined,
                title: 'لا توجد منتجات',
                message: 'أضف منتجًا أو غيّر الفلاتر الحالية.',
              ),
            ),
            Expanded(
              child: PointyErrorState(
                title: 'تعذر تحميل البيانات',
                message: 'تحقق من الاتصال وحاول مرة أخرى.',
              ),
            ),
            PointyLoadingArea(label: 'جاري التحميل'),
          ],
        ),
      );

      expect(find.text('لا توجد منتجات'), findsOneWidget);
      expect(find.text('تعذر تحميل البيانات'), findsOneWidget);
      expect(find.text('جاري التحميل'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  }

  testWidgets('PointySectionHeader keeps long Arabic text constrained', (
    tester,
  ) async {
    await _pumpSurface(
      tester,
      width: 390,
      child: PointySectionHeader(
        title: 'عنوان طويل جدًا لقسم تشغيلي داخل شاشة إدارة المنتجات',
        subtitle: 'وصف طويل يوضح الحالة الحالية بدون أن يزاحم أزرار الإجراء.',
        actions: [
          FilledButton(onPressed: () {}, child: const Text('حفظ')),
          OutlinedButton(onPressed: () {}, child: const Text('إلغاء')),
        ],
      ),
    );

    expect(find.textContaining('عنوان طويل'), findsOneWidget);
    expect(find.text('حفظ'), findsOneWidget);
    expect(find.text('إلغاء'), findsOneWidget);
  });

  testWidgets('PointyMetricTile and footer keep stable action sizing', (
    tester,
  ) async {
    await _pumpSurface(
      tester,
      width: 1366,
      child: PointyStickyActionFooter(
        summary: const PointyMetricTile(
          label: 'الإجمالي',
          value: '١٢٣٤٥٦٧٨٩٠ ر.س',
          subtitle: 'شامل كل البنود الحالية',
          icon: Icons.receipt_long_outlined,
        ),
        secondaryActions: [
          OutlinedButton(onPressed: () {}, child: const Text('حفظ كمسودة')),
        ],
        primaryAction: FilledButton(
          onPressed: () {},
          child: const Text('تأكيد'),
        ),
      ),
    );

    expect(find.text('الإجمالي'), findsOneWidget);
    expect(find.text('حفظ كمسودة'), findsOneWidget);
    expect(find.text('تأكيد'), findsOneWidget);
    expect(
      tester.getSize(find.widgetWithText(FilledButton, 'تأكيد')).height,
      PointyDimensions.primaryActionHeight,
    );
  });

  testWidgets('PointyMetricGrid adapts reusable metric tiles', (tester) async {
    await _pumpSurface(
      tester,
      width: 430,
      child: const PointyMetricGrid(
        minTileWidth: 180,
        maxColumns: 4,
        metrics: [
          PointyMetricGridItem(
            label: 'صافي المبيعات',
            value: '١٢٣٫٠٠',
            subtitle: 'أعلى من أمس',
            icon: Icons.payments_outlined,
          ),
          PointyMetricGridItem(
            label: 'عدد الطلبات',
            value: '٨',
            icon: Icons.receipt_long_outlined,
          ),
        ],
      ),
    );

    expect(find.text('صافي المبيعات'), findsOneWidget);
    expect(find.text('أعلى من أمس'), findsOneWidget);
    expect(find.text('عدد الطلبات'), findsOneWidget);

    final tiles = find.byType(PointyMetricTile);
    final firstTileSize = tester.getSize(tiles.at(0));
    final secondTileSize = tester.getSize(tiles.at(1));
    expect(firstTileSize.width, secondTileSize.width);
    expect(firstTileSize.height, secondTileSize.height);
    expect(
      firstTileSize.height,
      greaterThanOrEqualTo(PointyDimensions.metricTileMinHeight),
    );
  });

  testWidgets('PointyDetailSection renders reusable label-value rows', (
    tester,
  ) async {
    await _pumpSurface(
      tester,
      width: 390,
      child: const PointyDetailSection(
        title: 'تفاصيل المنتج',
        icon: Icons.inventory_2_outlined,
        child: Column(
          children: [
            PointyDetailRow(label: 'الباركود', value: '1234567890'),
            Divider(height: 20),
            PointyDetailRow(label: 'الحالة', value: 'متوفر'),
          ],
        ),
      ),
    );

    expect(find.text('تفاصيل المنتج'), findsOneWidget);
    expect(find.text('الباركود'), findsOneWidget);
    expect(find.text('1234567890'), findsOneWidget);
    expect(find.text('متوفر'), findsOneWidget);
  });

  testWidgets('PointyDetailSection can reserve stable chart height', (
    tester,
  ) async {
    await _pumpSurface(
      tester,
      width: 390,
      child: const PointyDetailSection(
        title: 'مخطط المبيعات',
        icon: Icons.show_chart,
        minHeight: 220,
        child: Text('لا توجد بيانات'),
      ),
    );

    expect(find.text('مخطط المبيعات'), findsOneWidget);
    expect(find.text('لا توجد بيانات'), findsOneWidget);
    expect(tester.getSize(find.byType(Card)).height, greaterThanOrEqualTo(220));
  });

  testWidgets('PointyInlineMessage renders semantic feedback rows', (
    tester,
  ) async {
    await _pumpSurface(
      tester,
      width: 390,
      child: const Column(
        children: [
          PointyInlineMessage.error(message: 'تعذر تنفيذ العملية.'),
          SizedBox(height: 8),
          PointyInlineMessage.success(
            message: 'تم حفظ التغييرات.',
            compact: true,
          ),
        ],
      ),
    );

    expect(find.text('تعذر تنفيذ العملية.'), findsOneWidget);
    expect(find.text('تم حفظ التغييرات.'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
  });

  testWidgets('PointyDataList renders reusable rows and actions', (
    tester,
  ) async {
    var tapped = false;

    await _pumpSurface(
      tester,
      width: 480,
      child: SizedBox(
        height: 360,
        child: Column(
          children: [
            const PointyFilterSummaryBar(
              items: [
                PointyFilterSummaryItem(
                  label: 'هذا الشهر',
                  icon: Icons.filter_alt_outlined,
                  selected: true,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: PointyDataList<String>(
                items: const ['طلب شراء 1001'],
                onLoadMore: () async {},
                hasMore: false,
                isLoadingInitial: false,
                isLoadingMore: false,
                emptyBuilder: (context) => const PointyEmptyState(
                  icon: Icons.inbox_outlined,
                  title: 'لا توجد سجلات',
                ),
                itemBuilder: (context, item) {
                  return PointyDataRow(
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: item,
                    subtitle: 'المورد الرئيسي • ٣ بنود',
                    badges: const [
                      PointyStatusPill(
                        label: 'مكتمل',
                        icon: Icons.check_circle_outline,
                      ),
                    ],
                    trailing: const Text('١٢٥٫٠٠'),
                    onTap: () => tapped = true,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.text('هذا الشهر'), findsOneWidget);
    expect(find.text('طلب شراء 1001'), findsOneWidget);
    expect(find.text('مكتمل'), findsOneWidget);

    await tester.tap(find.text('طلب شراء 1001'));
    expect(tapped, isTrue);
  });

  testWidgets('PointyDataList handles loading, error, and empty states', (
    tester,
  ) async {
    await _pumpSurface(
      tester,
      width: 390,
      child: SizedBox(
        height: 240,
        child: PointyDataList<String>(
          items: const [],
          onLoadMore: () async {},
          hasMore: false,
          isLoadingInitial: true,
          isLoadingMore: false,
          emptyBuilder: (context) => const PointyEmptyState(
            icon: Icons.inbox_outlined,
            title: 'لا توجد سجلات',
          ),
          itemBuilder: (context, item) => Text(item),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await _pumpSurface(
      tester,
      width: 390,
      child: SizedBox(
        height: 240,
        child: PointyDataList<String>(
          items: const [],
          onLoadMore: () async {},
          hasMore: false,
          isLoadingInitial: false,
          isLoadingMore: false,
          hasError: true,
          errorBuilder: (context) =>
              const PointyErrorState(title: 'تعذر تحميل السجلات'),
          emptyBuilder: (context) => const PointyEmptyState(
            icon: Icons.inbox_outlined,
            title: 'لا توجد سجلات',
          ),
          itemBuilder: (context, item) => Text(item),
        ),
      ),
    );
    expect(find.text('تعذر تحميل السجلات'), findsOneWidget);

    await _pumpSurface(
      tester,
      width: 390,
      child: SizedBox(
        height: 240,
        child: PointyDataList<String>(
          items: const [],
          onLoadMore: () async {},
          hasMore: false,
          isLoadingInitial: false,
          isLoadingMore: false,
          emptyBuilder: (context) => const PointyEmptyState(
            icon: Icons.inbox_outlined,
            title: 'لا توجد سجلات',
          ),
          itemBuilder: (context, item) => Text(item),
        ),
      ),
    );
    expect(find.text('لا توجد سجلات'), findsOneWidget);
  });

  testWidgets('Phase 7 settings and permission surfaces preserve Arabic text', (
    tester,
  ) async {
    var tapped = false;

    await _pumpSurface(
      tester,
      width: 480,
      child: PointySettingsSection(
        children: [
          PointySettingsTile(
            icon: Icons.storefront_outlined,
            title: 'هوية المتجر',
            subtitle: 'الفرع الرئيسي',
            onTap: () => tapped = true,
          ),
        ],
      ),
    );

    expect(find.text('هوية المتجر'), findsOneWidget);
    expect(find.text('الفرع الرئيسي'), findsOneWidget);
    await tester.tap(find.text('هوية المتجر'));
    expect(tapped, isTrue);

    await _pumpSurface(
      tester,
      width: 390,
      child: const PointyPermissionDeniedView(
        title: 'غير مصرح',
        message: 'لا تملك صلاحية الوصول إلى هذه الصفحة.',
      ),
    );

    expect(find.text('غير مصرح'), findsOneWidget);
    expect(find.text('لا تملك صلاحية الوصول إلى هذه الصفحة.'), findsOneWidget);
  });

  testWidgets('PointyNavigationSurface keeps drawer destinations selectable', (
    tester,
  ) async {
    var selected = -1;
    var loggedOut = false;

    await _pumpSurface(
      tester,
      width: 390,
      child: PointyNavigationSurface(
        selectedIndex: 0,
        onDestinationSelected: (index) => selected = index,
        userLabel: 'مدير المتجر',
        roleLabel: 'مدير',
        destinations: const [
          NavigationDrawerDestination(
            icon: Icon(Icons.dashboard_outlined),
            label: Text('لوحة التحكم'),
          ),
          NavigationDrawerDestination(
            icon: Icon(Icons.point_of_sale_outlined),
            label: Text('نقطة البيع'),
          ),
        ],
        logoutTile: ListTile(
          title: const Text('تسجيل الخروج'),
          onTap: () => loggedOut = true,
        ),
      ),
    );

    expect(find.byType(NavigationDrawer), findsOneWidget);
    expect(find.text('مدير المتجر'), findsOneWidget);
    expect(find.text('لوحة التحكم'), findsOneWidget);

    await tester.tap(find.text('نقطة البيع'));
    expect(selected, 1);

    await tester.tap(find.text('تسجيل الخروج'));
    expect(loggedOut, isTrue);
  });

  testWidgets('PointyDestructiveConfirmationDialog returns confirmation', (
    tester,
  ) async {
    bool? confirmed;

    await _pumpSurface(
      tester,
      width: 390,
      child: Builder(
        builder: (context) {
          return FilledButton(
            onPressed: () async {
              confirmed = await showDialog<bool>(
                context: context,
                builder: (context) {
                  return const PointyDestructiveConfirmationDialog(
                    title: 'حذف العنصر',
                    message: 'لا يمكن التراجع عن هذا الإجراء.',
                    confirmLabel: 'حذف',
                  );
                },
              );
            },
            child: const Text('فتح التأكيد'),
          );
        },
      ),
    );

    await tester.tap(find.text('فتح التأكيد'));
    await tester.pumpAndSettle();

    expect(find.text('حذف العنصر'), findsOneWidget);
    expect(find.text('لا يمكن التراجع عن هذا الإجراء.'), findsOneWidget);

    await tester.tap(find.text('حذف'));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });
}

Future<void> _pumpSurface(
  WidgetTester tester, {
  required double width,
  required Widget child,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Material(
          child: Center(
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    ),
  );
}
