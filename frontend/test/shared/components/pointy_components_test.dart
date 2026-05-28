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
        child: Center(
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
}
