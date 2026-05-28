import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() {
  testWidgets('PointyScaffold preserves drawer opening from app bar leading', (
    tester,
  ) async {
    await _pumpShell(
      tester,
      child: PointyScaffold(
        drawer: const Drawer(child: Text('القائمة')),
        appBar: PointyAppBar(
          title: const Text('المنتجات'),
          leading: Builder(
            builder: (context) {
              return IconButton(
                tooltip: 'القائمة',
                onPressed: Scaffold.of(context).openDrawer,
                icon: const Icon(Icons.menu),
              );
            },
          ),
        ),
        body: const Text('المحتوى'),
      ),
    );

    expect(find.text('المحتوى'), findsOneWidget);

    await tester.tap(find.byTooltip('القائمة'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(Drawer), findsOneWidget);
  });

  testWidgets(
    'PointyAppBar supports high-focus style and stable loading slot',
    (tester) async {
      await _pumpShell(
        tester,
        child: const PointyScaffold(
          appBar: PointyAppBar(
            title: Text('نقطة البيع'),
            style: PointyAppBarStyle.highFocus,
            isLoading: true,
            actions: [Icon(Icons.sync)],
          ),
          body: SizedBox.shrink(),
        ),
      );

      final appBar = tester.widget<AppBar>(find.byType(AppBar));

      expect(appBar.backgroundColor, PointyColors.darkTopBar);
      expect(appBar.foregroundColor, PointyColors.surface);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.sync), findsOneWidget);
    },
  );
}

Future<void> _pumpShell(WidgetTester tester, {required Widget child}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: PointyTheme.light(),
      home: Directionality(textDirection: TextDirection.rtl, child: child),
    ),
  );
}
