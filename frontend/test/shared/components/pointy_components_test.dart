import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}

Future<void> _pumpSurface(
  WidgetTester tester, {
  required double width,
  required Widget child,
}) async {
  await tester.pumpWidget(
    MaterialApp(
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
