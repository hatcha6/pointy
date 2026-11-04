import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/services/backend_discovery_service.dart';
import 'package:pointy_frontend/src/data/services/connection_coordinator.dart';
import 'package:pointy_frontend/src/data/services/connection_profile_storage.dart';
import 'package:pointy_frontend/src/data/services/connection_status_controller.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/connection/installation_id_text.dart';
import 'package:pointy_frontend/src/features/connection/views/connection_gate.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() {
  late ConnectionStatusController status;

  late List<http.Request> requests;

  /// The system clipboard as the app reads it: [text], or a refusal (null
  /// [text] with [refuse]), as Safari answers when its Paste bubble is
  /// dismissed.
  void clipboard(WidgetTester tester, String? text, {bool refuse = false}) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method != 'Clipboard.getData') {
          return null;
        }
        if (refuse) {
          throw PlatformException(code: 'denied');
        }
        return text == null ? null : {'text': text};
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  ConnectionCoordinator coordinatorFor({required bool searchesLan}) {
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response('', 404);
    });
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

  setUp(() {
    status = ConnectionStatusController();
    requests = [];
  });
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

  test('an installation ID is found anywhere in what was copied', () {
    const id = '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d';
    expect(installationIdIn(id), id);
    expect(installationIdIn(' رقم التثبيت: ${id.toUpperCase()}\n'), id);
    expect(installationIdIn('x${id}0'), isNull, reason: 'part of a longer run');
    expect(installationIdIn('0a1b2c3d-4e5f'), isNull);
    expect(installationIdIn(''), isNull);
    expect(installationIdIn(null), isNull);
  });

  testWidgets('an ID on the clipboard is used on the first tap of the field', (
    tester,
  ) async {
    const id = '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d';
    clipboard(tester, 'رقم التثبيت: ${id.toUpperCase()}');
    final l10n = await pump(tester, coordinatorFor(searchesLan: false));

    expect(find.text(l10n.connectionRemotePasteButton), findsOneWidget);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    expect(find.text(id), findsOneWidget);
    // Straight to the shop it names, no button to press.
    expect(
      requests.map((r) => r.headers['X-Pointy-Relay-Installation']),
      contains(id),
    );
    expect(find.text(l10n.connectionRemotePasteButton), findsNothing);
  });

  testWidgets('with no ID on the clipboard, the paste button says so', (
    tester,
  ) async {
    clipboard(tester, 'shopping list');
    final l10n = await pump(tester, coordinatorFor(searchesLan: false));

    // The quiet read on the first tap finds nothing and leaves the field be.
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.text(l10n.connectionRemoteClipboardHasNoId), findsNothing);
    expect(requests, isEmpty);

    await tester.tap(find.text(l10n.connectionRemotePasteButton));
    await tester.pumpAndSettle();
    expect(find.text(l10n.connectionRemoteClipboardHasNoId), findsOneWidget);
    expect(requests, isEmpty);

    // Typing clears the hint and hides the button.
    await tester.enterText(find.byType(TextField), '0a1b');
    await tester.pump();
    expect(find.text(l10n.connectionRemoteClipboardHasNoId), findsNothing);
    expect(find.text(l10n.connectionRemotePasteButton), findsNothing);
  });

  testWidgets('a refused clipboard read is the same as an empty one', (
    tester,
  ) async {
    clipboard(tester, null, refuse: true);
    final l10n = await pump(tester, coordinatorFor(searchesLan: false));

    await tester.tap(find.text(l10n.connectionRemotePasteButton));
    await tester.pumpAndSettle();
    expect(find.text(l10n.connectionRemoteClipboardHasNoId), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the paste button pastes and connects in one tap', (
    tester,
  ) async {
    const id = '6ec0bd7f-11c0-43da-975e-2a8ad9ebae0b';
    clipboard(tester, null);
    final l10n = await pump(tester, coordinatorFor(searchesLan: false));
    // Copied after the field was first tapped.
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    clipboard(tester, id);

    await tester.tap(find.text(l10n.connectionRemotePasteButton));
    await tester.pumpAndSettle();
    expect(find.text(id), findsOneWidget);
    expect(
      requests.map((r) => r.headers['X-Pointy-Relay-Installation']),
      contains(id),
    );
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
