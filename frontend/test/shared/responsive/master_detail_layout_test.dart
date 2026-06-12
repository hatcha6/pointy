import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';

void main() {
  Future<void> pumpAtWidth(
    WidgetTester tester,
    double width, {
    Widget? detailPane,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MasterDetailLayout(
            listPaneBuilder: (context, isDualPane) =>
                Text(isDualPane ? 'list-dual' : 'list-compact'),
            placeholder: const Text('placeholder'),
            detailPane: detailPane,
          ),
        ),
      ),
    );
  }

  group('MasterDetailLayout', () {
    testWidgets('shows only the list below the dual-pane breakpoint', (
      tester,
    ) async {
      await pumpAtWidth(tester, 390);

      expect(find.text('list-compact'), findsOneWidget);
      expect(find.text('placeholder'), findsNothing);
    });

    testWidgets('shows list and placeholder side by side at desktop width', (
      tester,
    ) async {
      await pumpAtWidth(tester, 1366);

      expect(find.text('list-dual'), findsOneWidget);
      expect(find.text('placeholder'), findsOneWidget);
    });

    testWidgets('renders the detail pane instead of the placeholder', (
      tester,
    ) async {
      await pumpAtWidth(
        tester,
        1366,
        detailPane: const Text('detail', key: ValueKey('detail')),
      );
      await tester.pumpAndSettle();

      expect(find.text('detail'), findsOneWidget);
      expect(find.text('placeholder'), findsNothing);
    });

    testWidgets('reports dual-pane availability from the viewport width', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1024, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      late bool isDual;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              isDual = MasterDetailLayout.isDualPane(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(isDual, isTrue);
    });
  });
}
