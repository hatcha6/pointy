import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/services/backend_discovery_service.dart';
import 'package:pointy_frontend/src/data/services/connection_coordinator.dart';
import 'package:pointy_frontend/src/data/services/connection_profile_storage.dart';
import 'package:pointy_frontend/src/data/services/connection_status_controller.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/connection/views/connection_gate.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() {
  late ConnectionStatusController status;

  ConnectionCoordinator coordinatorFor({required bool searchesLan}) {
    final client = MockClient((_) async => http.Response('', 404));
    final coordinator = ConnectionCoordinator(
      service: PosApiService(client: client, baseUrl: 'http://lan.test/api'),
      discovery: BackendDiscoveryService(
        client: client,
        defaultApiBaseUrl: 'http://lan.test/api',
      ),
      storage: MemoryConnectionProfileStorage(deviceId: 'device-1'),
      status: status,
      searchesLan: searchesLan,
    );
    addTearDown(coordinator.dispose);
    return coordinator;
  }

  Future<AppLocalizations> pump(
    WidgetTester tester,
    ConnectionCoordinator coordinator,
  ) async {
    status.update(ConnectionPhase.needsManual);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: ConnectionGate(
          controller: status,
          coordinator: coordinator,
          child: const Text('till'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.of(tester.element(find.byType(ConnectionGate)))!;
  }

  setUp(() => status = ConnectionStatusController());
  tearDown(() => status.dispose());

  testWidgets('the address screen offers the relay, and the way back', (
    tester,
  ) async {
    final l10n = await pump(tester, coordinatorFor(searchesLan: true));

    expect(find.text(l10n.connectionManualFieldLabel), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('connect_via_relay_button')));
    await tester.pumpAndSettle();

    // A device that never reached a shop is asked which one.
    expect(find.text(l10n.connectionRemoteFieldLabel), findsOneWidget);
    await tester.tap(find.text(l10n.connectionRemoteSearchLanButton));
    await tester.pumpAndSettle();
    expect(find.text(l10n.connectionManualFieldLabel), findsOneWidget);
  });

  testWidgets('a malformed installation ID is refused on the form', (
    tester,
  ) async {
    final l10n = await pump(tester, coordinatorFor(searchesLan: false));

    // No shop network to search: the relay form is all there is.
    expect(find.text(l10n.connectionManualFieldLabel), findsNothing);
    expect(find.text(l10n.connectionRemoteSearchLanButton), findsNothing);
    await tester.enterText(find.byType(TextField), 'not-an-id');
    await tester.tap(find.text(l10n.connectionRemoteConnectButton));
    await tester.pumpAndSettle();
    expect(find.text(l10n.connectionRemoteNotFound), findsOneWidget);
  });
}
