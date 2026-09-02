import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/ai_chat.dart';
import 'package:pointy_frontend/src/features/ai/ui/ai_surface_action.dart';
import 'package:pointy_frontend/src/features/ai/ui/ai_surface_host.dart';
import 'package:pointy_frontend/src/features/ai/ui/ai_surface_view.dart';
import 'package:pointy_frontend/src/features/ai/ui/pointy_ai_catalog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

AiUiSurface _surface(
  List<Map<String, dynamic>> components, {
  String id = 's1',
  Map<String, Object?> data = const <String, Object?>{},
}) => AiUiSurface(surfaceId: id, components: components, data: data);

Widget _host(AiSurfaceHost host, AiUiSurface surface) {
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
    home: Scaffold(
      body: SingleChildScrollView(
        child: AiSurfaceView(host: host, surface: surface),
      ),
    ),
  );
}

void main() {
  group('catalog', () {
    test('every item has a unique name and example data', () {
      final names = PointyAiCatalog.itemNames;
      expect(names.toSet().length, names.length);
      for (final item in PointyAiCatalog.items) {
        expect(
          item.exampleData,
          isNotEmpty,
          reason: '${item.name} needs example data for the catalog board',
        );
      }
    });
  });

  group('AiSurfaceHost', () {
    late AiSurfaceHost host;

    setUp(() => host = AiSurfaceHost());
    tearDown(() => host.dispose());

    test('a surface is live only after it is applied', () {
      expect(host.isLive('s1'), isFalse);
      host.apply(
        _surface([
          {'id': 'root', 'component': 'Text', 'text': 'hi'},
        ]),
      );
      expect(host.isLive('s1'), isTrue);
    });

    test('reset drops every surface, so cards never cross conversations', () {
      host.apply(
        _surface([
          {'id': 'root', 'component': 'Text', 'text': 'hi'},
        ]),
      );
      host.reset();
      expect(host.isLive('s1'), isFalse);
    });

    test('re-applying the same id replaces it rather than stacking', () {
      final components = [
        {'id': 'root', 'component': 'Text', 'text': 'hi'},
      ];
      host.apply(_surface(components));
      host.apply(_surface(components));
      expect(host.isLive('s1'), isTrue);
    });

    test('reads the surface data model back for a submit', () {
      host.apply(
        _surface(
          [
            {'id': 'root', 'component': 'Text', 'text': 'hi'},
          ],
          data: {
            'order': {'quantity': 5},
          },
        ),
      );
      expect(host.dataFor('s1'), containsPair('order', {'quantity': 5}));
    });
  });

  group('AiSurfaceAction', () {
    test('routes by the name prefix', () {
      expect(
        AiSurfaceAction.parse(name: 'navigate:x', surfaceId: 's').kind,
        AiSurfaceActionKind.navigate,
      );
      expect(
        AiSurfaceAction.parse(name: 'ask:x', surfaceId: 's').kind,
        AiSurfaceActionKind.ask,
      );
      expect(
        AiSurfaceAction.parse(name: 'submit:x', surfaceId: 's').kind,
        AiSurfaceActionKind.submit,
      );
    });

    test('an unprefixed name is unknown rather than guessed at', () {
      expect(
        AiSurfaceAction.parse(name: 'doSomething', surfaceId: 's').kind,
        AiSurfaceActionKind.unknown,
      );
    });
  });

  group('rendering', () {
    testWidgets('renders text, metrics and a table from A2UI', (tester) async {
      final host = AiSurfaceHost();
      addTearDown(host.dispose);
      final surface = _surface([
        {
          'id': 'root',
          'component': 'Column',
          'children': ['t', 'm', 'tbl'],
        },
        {'id': 't', 'component': 'Text', 'text': 'ملخص المبيعات'},
        {
          'id': 'm',
          'component': 'MetricGrid',
          'metrics': [
            {'label': 'المبيعات', 'value': 1200, 'kind': 'money'},
          ],
        },
        {
          'id': 'tbl',
          'component': 'Table',
          'columns': [
            {'key': 'name', 'label': 'الصنف'},
            {'key': 'qty', 'label': 'الكمية', 'kind': 'number', 'total': true},
          ],
          'rows': [
            {'name': 'شاي', 'qty': 4},
            {'name': 'سكر', 'qty': 6},
          ],
        },
      ]);
      host.apply(surface);
      await tester.pumpWidget(_host(host, surface));
      await tester.pumpAndSettle();

      expect(find.text('ملخص المبيعات'), findsOneWidget);
      expect(find.text('المبيعات'), findsOneWidget);
      expect(find.text('شاي'), findsOneWidget);
      // The marked column is summed; the label column is not.
      expect(find.text('10'), findsOneWidget);
    });

    testWidgets('a tap emits a routed action', (tester) async {
      final host = AiSurfaceHost();
      addTearDown(host.dispose);
      final actions = <AiSurfaceAction>[];
      host.actions.listen(actions.add);

      final surface = _surface([
        {
          'id': 'root',
          'component': 'Button',
          'label': 'افتح',
          'action': {
            'event': {
              'name': 'navigate:product',
              'context': {'link': 'pointy://product/7'},
            },
          },
        },
      ]);
      host.apply(surface);
      await tester.pumpWidget(_host(host, surface));
      await tester.pumpAndSettle();

      await tester.tap(find.text('افتح'));
      await tester.pump();

      expect(actions, hasLength(1));
      expect(actions.single.kind, AiSurfaceActionKind.navigate);
      expect(actions.single.link, 'pointy://product/7');
    });

    testWidgets('a submit carries the edited data model back', (tester) async {
      final host = AiSurfaceHost();
      addTearDown(host.dispose);
      final actions = <AiSurfaceAction>[];
      host.actions.listen(actions.add);

      final surface = _surface(
        [
          {
            'id': 'root',
            'component': 'Form',
            'child': 'qty',
            'submitLabel': 'أرسل',
            'action': {
              'event': {'name': 'submit:reorder'},
            },
          },
          {
            'id': 'qty',
            'component': 'NumberField',
            'label': 'الكمية',
            'value': {'path': '/order/quantity'},
          },
        ],
        data: {
          'order': {'quantity': 3},
        },
      );
      host.apply(surface);
      await tester.pumpWidget(_host(host, surface));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '9');
      await tester.pump();
      await tester.tap(find.text('أرسل'));
      await tester.pump();

      expect(actions, hasLength(1));
      final submitted = actions.single;
      expect(submitted.kind, AiSurfaceActionKind.submit);
      expect((submitted.data['order'] as Map)['quantity'], 9);
    });

    testWidgets('an unapplied surface renders nothing rather than an error', (
      tester,
    ) async {
      final host = AiSurfaceHost();
      addTearDown(host.dispose);
      final surface = _surface([
        {'id': 'root', 'component': 'Text', 'text': 'hi'},
      ]);
      await tester.pumpWidget(_host(host, surface));
      await tester.pumpAndSettle();
      expect(find.text('hi'), findsNothing);
    });
  });
}
