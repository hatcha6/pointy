import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/camera.dart';
import 'package:pointy_frontend/src/data/repositories/surveillance_repository.dart';
import 'package:pointy_frontend/src/data/services/lan_interfaces.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/cameras/ftp_setup_state.dart';
import 'package:pointy_frontend/src/features/cameras/view_models/camera_settings_view_model.dart';
import 'package:pointy_frontend/src/features/cameras/view_models/ftp_setup_view_model.dart';
import 'package:pointy_frontend/src/features/cameras/views/camera_settings_page.dart';
import 'package:pointy_frontend/src/features/cameras/views/ftp_setup_pages.dart';

/// FTP upload setups on the client: reading what the server sends, saying
/// where a setup stands, telling the server which address the installer saw,
/// and the screens an installer reads the credentials off.
final _now = DateTime.utc(2026, 9, 27, 12);

Map<String, Object?> _ftpJson({
  String? password = 'k7m2p9x4w3tq',
  bool running = true,
  bool accepting = true,
  String refusing = '',
  String? lastUpload,
  String? lastLogin,
  int failed = 0,
  String? failedAt,
  String? failedPeer,
  String host = '192.168.1.10',
  List<Map<String, Object?>> unknown = const [],
  String ingestError = '',
  String? ingestErrorAt,
}) {
  return {
    'username': 'cam1234',
    'password': password,
    'host': host,
    'server': {
      'running': running,
      'port': 21,
      'passive_ports': '30000-30019',
      'accepting': accepting,
      'refusing_reason': refusing,
      'recent_unknown_logins': unknown,
    },
    'last_login_at': lastLogin,
    'last_login_peer': lastLogin == null ? '' : '192.168.1.108',
    'last_upload_at': lastUpload,
    'last_upload_peer': '192.168.1.108',
    'last_upload_name': 'a.jpg',
    'failed_login_count': failed,
    'failed_login_at': failedAt,
    'failed_login_peer': failedPeer ?? (failed > 0 ? '192.168.1.66' : ''),
    'files_received': 12,
    'files_kept': 3,
    'files_discarded': 9,
    'files_unreadable': 0,
    'last_ingest_error': ingestError,
    'last_ingest_error_at': ingestErrorAt,
  };
}

Recorder _ftpRecorder({
  Map<String, Object?>? ftp,
  List<Object?> cameras = const [],
}) {
  return Recorder.fromJson({
    'id': 7,
    'name': 'المخزن',
    'connection': 'ftp',
    'brand': 'auto',
    'host': '',
    'status': 'ok',
    'cameras': cameras,
    'ftp':
        ftp ??
        _ftpJson(
          lastUpload: _now
              .subtract(const Duration(minutes: 2))
              .toIso8601String(),
        ),
  });
}

class _FakeRepository extends SurveillanceRepository {
  _FakeRepository({this.address = '192.168.1.10'}) : super(PosApiService());

  Recorder? recorder;
  final String? address;
  final List<String> addressesSent = [];
  int passwordsRegenerated = 0;
  RecorderDraft? saved;

  @override
  Future<String?> ftpServerAddress() async => address;

  @override
  Future<Result<Recorder>> setFtpAddress(int id, String host) async {
    addressesSent.add(host);
    final json = _ftpJson(host: host);
    recorder = _ftpRecorder(ftp: json);
    return Ok(recorder!);
  }

  @override
  Future<Result<Recorder>> regenerateFtpPassword(int id) async {
    passwordsRegenerated++;
    recorder = _ftpRecorder(ftp: _ftpJson(password: 'newpassword2'));
    return Ok(recorder!);
  }

  @override
  Future<Result<Recorder>> loadRecorder(int id) async => Ok(recorder!);

  @override
  Future<Result<Recorder>> saveRecorder(RecorderDraft draft) async {
    saved = draft;
    recorder = _ftpRecorder();
    return Ok(recorder!);
  }

  @override
  Future<Result<List<Recorder>>> loadRecorders() async => Ok([?recorder]);

  @override
  Future<Result<List<Camera>>> loadCameras({bool enabledOnly = false}) async {
    return Ok(recorder?.cameras ?? const []);
  }

  @override
  Future<Result<SurveillanceStatus>> loadStatus() async {
    return const Ok(SurveillanceStatus());
  }
}

Widget _app(Widget home) {
  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  );
}

void main() {
  group('models', () {
    test('an FTP recorder carries its credentials and server', () {
      final recorder = _ftpRecorder();
      expect(recorder.isFtp, isTrue);
      expect(recorder.ftp!.username, 'cam1234');
      expect(recorder.ftp!.password, 'k7m2p9x4w3tq');
      expect(recorder.ftp!.server.port, 21);
      expect(recorder.ftp!.server.passivePorts, '30000-30019');
      expect(recorder.displayName, 'المخزن');
    });

    test('a recorder from an older backend is a direct one', () {
      final recorder = Recorder.fromJson({'id': 1, 'host': '10.0.0.5'});
      expect(recorder.isFtp, isFalse);
      expect(recorder.ftp, isNull);
    });

    test('a camera is live unless the server says it is not', () {
      expect(Camera.fromJson({'id': 1}).supportsLive, isTrue);
      expect(
        Camera.fromJson({'id': 1, 'supports_live': false}).supportsLive,
        isFalse,
      );
      expect(Camera.fromJson({'id': 1}).hasFootage, isNull);
      expect(
        Camera.fromJson({'id': 1, 'has_footage': true}).hasFootage,
        isTrue,
      );
    });

    test('an FTP draft sends no address, port or login of its own', () {
      const draft = RecorderDraft(
        name: 'المخزن',
        connection: RecorderConnection.ftp,
        host: 'stale',
        password: 'stale',
        ftpHost: '192.168.1.10',
      );
      expect(draft.toJson(), {
        'connection': 'ftp',
        'name': 'المخزن',
        'is_enabled': true,
        'ftp_host': '192.168.1.10',
      });
    });

    test('a direct draft says it is direct', () {
      expect(
        const RecorderDraft(host: '10.0.0.5').toJson()['connection'],
        'direct',
      );
    });

    test('only a private LAN address is offered to a DVR', () {
      expect(lanIpv4HostOf('http://192.168.1.10:8000/api'), '192.168.1.10');
      expect(lanIpv4HostOf('http://10.0.0.2:8000/api'), '10.0.0.2');
      expect(
        lanIpv4HostOf('https://env-9493505.tip2.libyanspider.cloud/api'),
        isNull,
      );
      expect(lanIpv4HostOf('http://127.0.0.1:8000/api'), isNull);
    });
  });

  group('ftpSetupStatusOf', () {
    FtpSetupStatus statusFor(Map<String, Object?> json) {
      return ftpSetupStatusOf(FtpAccountInfo.fromJson(json), now: _now);
    }

    String ago(Duration duration) => _now.subtract(duration).toIso8601String();

    test('a server that is not running outranks everything', () {
      final status = statusFor(
        _ftpJson(running: false, failed: 3, failedAt: ago(Duration.zero)),
      );
      expect(status.health, FtpSetupHealth.serverDown);
    });

    test('a refusing server says why', () {
      expect(
        statusFor(_ftpJson(accepting: false, refusing: 'disk_floor')).health,
        FtpSetupHealth.refusingDisk,
      );
      expect(
        statusFor(_ftpJson(accepting: false, refusing: 'inbox_full')).health,
        FtpSetupHealth.refusingInbox,
      );
    });

    test(
      'a wrong password after the last good login is named with its address',
      () {
        final status = statusFor(
          _ftpJson(
            lastLogin: ago(const Duration(hours: 1)),
            failed: 2,
            failedAt: ago(const Duration(minutes: 1)),
          ),
        );
        expect(status.health, FtpSetupHealth.wrongPassword);
        expect(status.peer, '192.168.1.66');
      },
    );

    test('an old failure followed by a good login is not a problem', () {
      final status = statusFor(
        _ftpJson(
          lastLogin: ago(const Duration(minutes: 1)),
          lastUpload: ago(const Duration(minutes: 1)),
          failed: 1,
          failedAt: ago(const Duration(hours: 2)),
        ),
      );
      expect(status.health, FtpSetupHealth.receiving);
    });

    test('from waiting, to logged in, to receiving, to stale', () {
      expect(statusFor(_ftpJson()).health, FtpSetupHealth.waiting);
      expect(
        statusFor(_ftpJson(lastLogin: ago(const Duration(minutes: 1)))).health,
        FtpSetupHealth.loggedIn,
      );
      expect(
        statusFor(_ftpJson(lastUpload: ago(const Duration(minutes: 5)))).health,
        FtpSetupHealth.receiving,
      );
      expect(
        statusFor(_ftpJson(lastUpload: ago(const Duration(days: 2)))).health,
        FtpSetupHealth.stale,
      );
    });

    test('only recent unknown usernames are mentioned', () {
      final status = statusFor(
        _ftpJson(
          unknown: [
            {
              'username': 'admin',
              'peer': '192.168.1.108',
              'at': ago(const Duration(minutes: 2)),
            },
            {
              'username': 'old',
              'peer': '192.168.1.9',
              'at': ago(const Duration(hours: 3)),
            },
          ],
        ),
      );
      expect(status.unknownLogins.map((login) => login.username), ['admin']);
    });

    test(
      'an unreadable-upload complaint older than the last good upload is dropped',
      () {
        final current = statusFor(
          _ftpJson(
            lastUpload: ago(const Duration(minutes: 5)),
            ingestError: 'not a JPEG picture',
            ingestErrorAt: ago(const Duration(minutes: 5)),
          ),
        );
        expect(current.ingestError, 'not a JPEG picture');
        final stale = statusFor(
          _ftpJson(
            lastUpload: ago(const Duration(minutes: 5)),
            ingestError: 'not a JPEG picture',
            ingestErrorAt: ago(const Duration(days: 1)),
          ),
        );
        expect(stale.ingestError, isEmpty);
      },
    );
  });

  group('FtpSetupViewModel', () {
    test('tells the server the address this device is showing', () async {
      final repository = _FakeRepository(address: '192.168.1.44');
      final viewModel = FtpSetupViewModel(
        repository,
        recorder: _ftpRecorder(),
        refreshInterval: const Duration(hours: 1),
      );
      await viewModel.start();
      expect(repository.addressesSent, ['192.168.1.44']);
      expect(viewModel.serverAddress, '192.168.1.44');
      viewModel.dispose();
    });

    test('does not resend an address the server already has', () async {
      final repository = _FakeRepository(address: '192.168.1.10');
      final viewModel = FtpSetupViewModel(
        repository,
        recorder: _ftpRecorder(),
        refreshInterval: const Duration(hours: 1),
      );
      await viewModel.start();
      expect(repository.addressesSent, isEmpty);
      viewModel.dispose();
    });

    test(
      'someone who cannot see the password does not change the address',
      () async {
        final repository = _FakeRepository(address: '192.168.1.44');
        final viewModel = FtpSetupViewModel(
          repository,
          recorder: _ftpRecorder(ftp: _ftpJson(password: null)),
          refreshInterval: const Duration(hours: 1),
        );
        await viewModel.start();
        expect(viewModel.canManage, isFalse);
        expect(repository.addressesSent, isEmpty);
        viewModel.dispose();
      },
    );

    test('over the relay the stored address is shown', () async {
      final repository = _FakeRepository(address: null);
      final viewModel = FtpSetupViewModel(
        repository,
        recorder: _ftpRecorder(),
        refreshInterval: const Duration(hours: 1),
      );
      await viewModel.start();
      expect(viewModel.serverAddress, '192.168.1.10');
      viewModel.dispose();
    });

    test('a new password replaces the old one on screen', () async {
      final repository = _FakeRepository();
      final viewModel = FtpSetupViewModel(
        repository,
        recorder: _ftpRecorder(),
        refreshInterval: const Duration(hours: 1),
      );
      expect(await viewModel.regeneratePassword(), isTrue);
      expect(viewModel.account!.password, 'newpassword2');
      expect(repository.passwordsRegenerated, 1);
      viewModel.dispose();
    });
  });

  group('screens', () {
    testWidgets('the connection choice returns what was picked', (
      tester,
    ) async {
      RecorderConnection? picked;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    picked = await showRecorderConnectionChoice(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('رفع التسجيلات عبر FTP'));
      await tester.pumpAndSettle();
      expect(picked, RecorderConnection.ftp);
    });

    testWidgets('the credentials are shown in full, left to right, with copy', (
      tester,
    ) async {
      final recorder = _ftpRecorder();
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: SingleChildScrollView(
              child: FtpConnectionBody(
                recorder: recorder,
                account: recorder.ftp!,
                status: ftpSetupStatusOf(recorder.ftp!, now: _now),
                serverAddress: '192.168.1.10',
                canManage: true,
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('192.168.1.10'), findsOneWidget);
      expect(find.textContaining('cam1234'), findsOneWidget);
      expect(find.textContaining('k7m2p9x4w3tq'), findsOneWidget);
      expect(find.byTooltip('نسخ'), findsNWidgets(4));
      expect(find.text('كلمة مرور جديدة'), findsOneWidget);
    });

    testWidgets('a server that cannot tell devices apart names no address', (
      tester,
    ) async {
      // A Windows server: every DVR arrives through one forwarded address, so
      // the server records none rather than the forward's own.
      final recorder = _ftpRecorder(
        ftp: _ftpJson(
          failed: 2,
          failedAt: _now.subtract(const Duration(minutes: 1)).toIso8601String(),
          failedPeer: '',
          unknown: [
            {'username': 'admin', 'peer': '', 'at': _now.toIso8601String()},
          ],
        ),
      );
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: SingleChildScrollView(
              child: FtpConnectionBody(
                recorder: recorder,
                account: recorder.ftp!,
                status: ftpSetupStatusOf(recorder.ftp!, now: _now),
                serverAddress: '192.168.1.10',
                canManage: true,
              ),
            ),
          ),
        ),
      );
      expect(find.text('جهاز يحاول الدخول بكلمة مرور خاطئة.'), findsOneWidget);
      expect(
        find.textContaining('جهاز حاول الدخول باسم مستخدم غير معروف'),
        findsOneWidget,
      );
      expect(find.textContaining('جهاز على'), findsNothing);
    });

    testWidgets(
      'without the right the password is withheld and cannot be reset',
      (tester) async {
        final recorder = _ftpRecorder(ftp: _ftpJson(password: null));
        await tester.pumpWidget(
          _app(
            Scaffold(
              body: SingleChildScrollView(
                child: FtpConnectionBody(
                  recorder: recorder,
                  account: recorder.ftp!,
                  status: ftpSetupStatusOf(recorder.ftp!, now: _now),
                  serverAddress: null,
                  canManage: false,
                ),
              ),
            ),
          ),
        );
        expect(find.text('لا تملك صلاحية عرض كلمة المرور.'), findsOneWidget);
        expect(
          find.text('افتح هذه الصفحة من جهاز داخل المحل ليظهر عنوان الخادم.'),
          findsOneWidget,
        );
        expect(find.text('كلمة مرور جديدة'), findsNothing);
      },
    );

    testWidgets('adding an FTP setup goes from a name to its credentials', (
      tester,
    ) async {
      final repository = _FakeRepository();
      final viewModel = CameraSettingsViewModel(
        repository,
        sweep: () async => const [],
      );
      await tester.pumpWidget(
        _app(
          CameraSettingsPage(
            viewModel: viewModel,
            enableSurveillance: false,
            onToggleEnabled: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.add).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('رفع التسجيلات عبر FTP'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'المخزن');
      await tester.tap(find.text('إنشاء بيانات الدخول'));
      await tester.pumpAndSettle();

      expect(repository.saved!.connection, RecorderConnection.ftp);
      expect(repository.saved!.name, 'المخزن');
      expect(repository.saved!.ftpHost, '192.168.1.10');
      expect(find.text('بيانات اتصال FTP'), findsOneWidget);
      expect(find.textContaining('k7m2p9x4w3tq'), findsOneWidget);
      // Leave the page so its refresh timer is cancelled.
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(find.text('بيانات اتصال FTP'), findsNothing);
    });

    testWidgets('an archive-only camera offers no stream quality to pick', (
      tester,
    ) async {
      final repository = _FakeRepository()
        ..recorder = _ftpRecorder(
          cameras: [
            {
              'id': 3,
              'recorder': 7,
              'channel': 1,
              'display_name': 'الكاشير',
              'covers_checkout': true,
              'supports_live': false,
            },
          ],
        );
      final viewModel = CameraSettingsViewModel(
        repository,
        sweep: () async => const [],
      );
      await tester.pumpWidget(
        _app(
          CameraSettingsPage(
            viewModel: viewModel,
            enableSurveillance: true,
            onToggleEnabled: (_) async {},
            archiveRetentionDays: 30,
            onArchiveRetentionChanged: (_) async => true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('مدة حفظ لقطات الفواتير'), findsOneWidget);
      await tester.tap(find.text('الكاشير'));
      await tester.pumpAndSettle();
      expect(find.textContaining('بلا بث مباشر'), findsOneWidget);
      expect(find.byType(SegmentedButton<CameraQuality>), findsNothing);
    });
  });
}
