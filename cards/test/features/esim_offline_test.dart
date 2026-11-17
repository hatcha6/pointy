import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_cards/dev/cards_fixtures.dart';
import 'package:pointy_cards/src/app.dart';
import 'package:pointy_cards/src/data/vault/esim_vault.dart';
import 'package:pointy_cards/src/features/shell/cards_shell.dart';

/// A traveller who has just landed: no network, and an eSIM to install.
void main() {
  final offline = MockClient((_) async => throw http.ClientException('off'));

  Future<void> open(WidgetTester tester, EsimVault vault) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      CardsApp(
        dependencies: fixtureDependencies(client: offline, esimVault: vault),
        home: const CardsShell(initialTab: 1),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('«كروتي» shows the eSIMs this phone holds with no network', (
    tester,
  ) async {
    final vault = MemoryEsimVault();
    await vault.write(
      jsonEncode({
        'owner': fixtureSession.customerId,
        'esims': [
          {
            'iccid': '8901',
            'order_id': 'order-1',
            'title': 'Turkey 1 GB',
            'data': '1 GB',
            'days': 7,
            'destination': 'turkey',
            'destination_name': 'تركيا',
            'country': 'TR',
            'usage': {
              'status': 'ACTIVE',
              'remaining_mb': 512,
              'total_mb': 1024,
            },
            'created_at': '2026-11-01T10:00:00Z',
          },
        ],
      }),
    );
    await open(tester, vault);
    expect(find.byKey(const ValueKey('failed')), findsNothing);
    expect(find.text('لا يوجد اتصال بالإنترنت'), findsOneWidget);
    expect(find.textContaining('تركيا'), findsWidgets);
  });

  testWidgets('with none held, it still says the cards could not be read', (
    tester,
  ) async {
    await open(tester, MemoryEsimVault());
    expect(find.byKey(const ValueKey('failed')), findsOneWidget);
  });
}
