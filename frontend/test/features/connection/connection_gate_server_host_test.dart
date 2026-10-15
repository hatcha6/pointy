import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/services/backend_discovery_service.dart';
import 'package:pointy_frontend/src/data/services/connection_coordinator.dart';
import 'package:pointy_frontend/src/data/services/connection_profile_storage.dart';
import 'package:pointy_frontend/src/data/services/connection_status_controller.dart';
import 'package:pointy_frontend/src/data/services/local_server_host.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/connection/view_models/local_server_host_controller.dart';
import 'package:pointy_frontend/src/features/connection/views/connection_gate.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

class _ServerPc extends NoLocalServerHost {
  _ServerPc(this.startOutcome);

  final KeeperStartOutcome startOutcome;
  int setups = 0;
  int restarts = 0;

  @override
  Future<bool> isServerPc() async => true;

  @override
  String get logPath => r'C:\ProgramData\Pointy\logs\keepalive.log';

  @override
  Future<KeeperStartOutcome> startKeeper() async => startOutcome;

  @override
  Future<KeeperSetupOutcome> runSetup() async {
    setups++;
    return KeeperSetupOutcome.cancelled;
  }

  @override
  Future<KeeperSetupOutcome> runKeeperElevated() async {
    restarts++;
    return KeeperSetupOutcome.launched;
  }
}

void main() {
  late ConnectionStatusController status;
  late ConnectionCoordinator coordinator;

  setUp(() {
    status = ConnectionStatusController();
    final client = MockClient((_) async => http.Response('', 404));
    coordinator = ConnectionCoordinator(
      service: PosApiService(client: client, baseUrl: 'http://lan.test/api'),
      discovery: BackendDiscoveryService(
        client: client,
        defaultApiBaseUrl: 'http://lan.test/api',
      ),
      storage: MemoryConnectionProfileStorage(deviceId: 'device-1'),
      status: status,
    );
  });

  tearDown(() {
    coordinator.dispose();
    status.dispose();
  });

  Future<LocalServerHostController> pumpGate(
    WidgetTester tester,
    _ServerPc host,
  ) async {
    final serverHost = LocalServerHostController(
      platform: host,
      pollWhileWaiting: const Duration(hours: 1),
    );
    await tester.runAsync(serverHost.start);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: ConnectionGate(
          controller: status,
          coordinator: coordinator,
          serverHost: serverHost,
          child: const Text('till'),
        ),
      ),
    );
    return serverHost;
  }

  testWidgets('the server PC shows its server starting, not a search', (
    tester,
  ) async {
    final serverHost = await pumpGate(
      tester,
      _ServerPc(KeeperStartOutcome.started),
    );

    expect(find.text('تشغيل خادم المتجر'), findsOneWidget);
    expect(find.text('بدء خدمة التشغيل'), findsOneWidget);

    status.update(ConnectionPhase.connectedLocal);
    await tester.pump();
    expect(find.text('till'), findsOneWidget);
    serverHost.dispose();
  });

  testWidgets('a missing task offers the one-time setup', (tester) async {
    final host = _ServerPc(KeeperStartOutcome.denied);
    final serverHost = await pumpGate(tester, host);

    await tester.tap(find.text('إعداد التشغيل التلقائي'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(host.setups, 1);
    expect(find.textContaining('أُلغي طلب صلاحية المدير'), findsOneWidget);
    serverHost.dispose();
  });

  testWidgets('a stuck start offers the restart', (tester) async {
    final host = _ServerPc(KeeperStartOutcome.started);
    var now = DateTime(2026, 10, 15, 9);
    final serverHost = LocalServerHostController(
      platform: host,
      clock: () => now,
      pollWhileWaiting: const Duration(hours: 1),
    );
    await tester.runAsync(serverHost.start);
    now = now.add(const Duration(minutes: 3));
    await tester.runAsync(serverHost.tick);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: ConnectionGate(
          controller: status,
          coordinator: coordinator,
          serverHost: serverHost,
          child: const Text('till'),
        ),
      ),
    );

    expect(find.textContaining('خدمة تشغيل الخادم لم تبدأ'), findsOneWidget);
    await tester.tap(find.text('إعادة تشغيل الخادم'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(host.restarts, 1);
    expect(find.textContaining('يجري الإعداد'), findsOneWidget);
    serverHost.dispose();
  });

  testWidgets('another server can still be chosen', (tester) async {
    final serverHost = await pumpGate(
      tester,
      _ServerPc(KeeperStartOutcome.started),
    );
    status.update(ConnectionPhase.needsManual);

    await tester.tap(find.text('الاتصال بخادم آخر'));
    await tester.pump();

    expect(find.text('تعذّر العثور على الخادم تلقائيًا'), findsOneWidget);
    serverHost.dispose();
  });
}
