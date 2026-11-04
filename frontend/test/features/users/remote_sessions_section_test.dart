import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/remote_session.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/users/view_models/remote_sessions_view_model.dart';
import 'package:pointy_frontend/src/features/users/views/remote_sessions_section.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// A sign-in from outside the shop used to leave no trace an owner could see
/// or act on. Each one is now a row on «إعداداتي» and on the person's page in
/// user management: what device, from where, until when — and a way to end it.
void main() {
  Map<String, Object?> session({
    int id = 12,
    String status = 'active',
    String deviceName = '',
    bool isCurrent = false,
    String endedBy = '',
  }) => {
    'id': id,
    'status': status,
    'device_name': deviceName,
    'platform': 'iphone',
    'browser': 'safari',
    'ip_address': '203.0.113.9',
    'created_at': '2026-10-28T09:15:00Z',
    'last_seen_at': '2026-10-29T08:00:00Z',
    'expires_at': '2026-11-11T09:15:00Z',
    'ended_at': status == 'active' ? null : '2026-10-29T10:00:00Z',
    'end_reason': status == 'active' ? '' : status,
    'ended_by_name': endedBy,
    'is_current': isCurrent,
  };

  testWidgets('a phone stacks the facts and puts the end button at the foot', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pump(
      tester,
      _Backend([session()]),
      isOwn: true,
      canRevoke: true,
      sized: false,
    );
    final address = tester.getTopLeft(find.text('العنوان'));
    final signedIn = tester.getTopLeft(find.text('الدخول'));
    expect(signedIn.dy, greaterThan(address.dy), reason: 'one fact per line');
    expect(
      tester.getTopLeft(find.text('إنهاء')).dy,
      greaterThan(signedIn.dy),
      reason: 'the end button sits below the facts',
    );
    expect(tester.takeException(), isNull);
  });

  test('a session reads from the wire, unknown values falling back', () {
    final parsed = RemoteSession.fromJson(session(status: 'signed_out'));
    expect(parsed.status, RemoteSessionStatus.signedOut);
    expect(parsed.isActive, isFalse);
    expect(parsed.ipAddress, '203.0.113.9');
    expect(
      RemoteSession.fromJson({'id': 1, 'status': 'mystery'}).status,
      RemoteSessionStatus.revoked,
    );
    expect(RemoteSession.listFromJson({'not': 'a list'}), isEmpty);
  });

  testWidgets('one person\'s own sessions: what, where, until when', (
    tester,
  ) async {
    final backend = _Backend([
      session(isCurrent: true),
      session(id: 11, status: 'revoked', endedBy: 'المالك'),
    ]);
    await _pump(tester, backend, isOwn: true, canRevoke: true);

    expect(backend.paths, ['/api/auth/remote-sessions/']);
    expect(find.text('الجلسات عن بُعد'), findsOneWidget);
    expect(find.text('آيفون · سفاري'), findsNWidgets(2));
    expect(find.text('نشطة'), findsOneWidget);
    expect(find.text('هذا الجهاز'), findsOneWidget);
    expect(find.text('أُنهيت'), findsOneWidget);
    expect(find.textContaining('203.0.113.9'), findsNWidgets(2));
    expect(find.text('أنهاها'), findsOneWidget);
    expect(find.text('المالك'), findsOneWidget);
    // A live session says when it was last used and when it ends, in words.
    expect(find.text('آخر نشاط'), findsOneWidget);
    expect(find.text('تنتهي'), findsOneWidget);
    // Only a live session can be ended.
    expect(find.text('إنهاء'), findsOneWidget);
  });

  testWidgets('ending a session asks first, then ends it at the shop', (
    tester,
  ) async {
    final backend = _Backend([session(deviceName: 'هاتف المدير')]);
    await _pump(tester, backend, userId: 4, isOwn: false, canRevoke: true);

    await tester.tap(find.text('إنهاء'));
    await tester.pumpAndSettle();
    expect(find.textContaining('«هاتف المدير»'), findsOneWidget);

    await tester.tap(find.text('إنهاء الجلسة'));
    await tester.pumpAndSettle();

    expect(backend.paths, [
      '/api/users/4/remote-sessions/',
      '/api/users/4/remote-sessions/12/revoke/',
    ]);
    expect(find.text('أُنهيت'), findsOneWidget);
    expect(find.text('إنهاء'), findsNothing);
    expect(find.text('أُنهيت الجلسة وسُجِّل خروج الجهاز.'), findsOneWidget);
  });

  testWidgets('cancelling the question changes nothing', (tester) async {
    final backend = _Backend([session()]);
    await _pump(tester, backend, isOwn: true, canRevoke: true);

    await tester.tap(find.text('إنهاء'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();

    expect(backend.paths, ['/api/auth/remote-sessions/']);
    expect(find.text('نشطة'), findsOneWidget);
  });

  testWidgets('ending your own current session warns it signs you out', (
    tester,
  ) async {
    final backend = _Backend([session(isCurrent: true)]);
    await _pump(tester, backend, isOwn: true, canRevoke: true);

    await tester.tap(find.text('إنهاء'));
    await tester.pumpAndSettle();
    expect(find.textContaining('سيُسجَّل خروجك من هذا الجهاز'), findsOneWidget);
  });

  testWidgets('a refused end says so and leaves the session live', (
    tester,
  ) async {
    final backend = _Backend([session()])..refuseRevoke = true;
    await _pump(tester, backend, isOwn: true, canRevoke: true);

    await tester.tap(find.text('إنهاء'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إنهاء الجلسة'));
    await tester.pumpAndSettle();

    expect(find.text('تعذّر إنهاء الجلسة. حاول مرة أخرى.'), findsOneWidget);
    expect(find.text('نشطة'), findsOneWidget);
    expect(find.text('إنهاء'), findsOneWidget);
  });

  testWidgets('someone who may only view users sees no end button', (
    tester,
  ) async {
    final backend = _Backend([session()]);
    await _pump(tester, backend, userId: 4, isOwn: false, canRevoke: false);

    expect(find.text('نشطة'), findsOneWidget);
    expect(find.text('إنهاء'), findsNothing);
  });

  testWidgets('nothing to show, and a failed read, each say so', (
    tester,
  ) async {
    await _pump(tester, _Backend([]), isOwn: true, canRevoke: true);
    expect(find.text('لا توجد جلسات عن بُعد'), findsOneWidget);

    final failing = _Backend([])..failList = true;
    await _pump(tester, failing, isOwn: true, canRevoke: true);
    expect(find.text('تعذّر تحميل الجلسات عن بُعد.'), findsOneWidget);

    failing.failList = false;
    failing.sessions = [session()];
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();
    expect(find.text('نشطة'), findsOneWidget);
  });

  testWidgets('fits a phone without overflowing', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final backend = _Backend([
      session(isCurrent: true, deviceName: 'هاتف المدير الشخصي الجديد'),
      session(id: 11, status: 'remote_sign_in_disabled', endedBy: 'المالك'),
    ]);
    await _pump(tester, backend, isOwn: true, canRevoke: true, sized: false);
    expect(tester.takeException(), isNull);
    expect(find.text('أُوقف الدخول عن بُعد'), findsOneWidget);
  });
}

class _Backend {
  _Backend(this.sessions);

  List<Map<String, Object?>> sessions;
  bool failList = false;
  bool refuseRevoke = false;
  final List<String> paths = [];

  late final PosApiService service = PosApiService(
    baseUrl: 'http://pointy.test/api',
    client: MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.path.endsWith('/revoke/')) {
        if (refuseRevoke) {
          return http.Response('{"detail":"no"}', 503);
        }
        final id = int.parse(request.url.pathSegments.reversed.elementAt(2));
        final ended = {
          ...sessions.firstWhere((item) => item['id'] == id),
          'status': 'revoked',
          'ended_at': '2026-10-29T10:00:00Z',
        };
        return _json(ended);
      }
      if (failList) {
        return http.Response('{"detail":"down"}', 503);
      }
      return _json(sessions);
    }),
  );
}

http.Response _json(Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<void> _pump(
  WidgetTester tester,
  _Backend backend, {
  int? userId,
  required bool isOwn,
  required bool canRevoke,
  bool sized = true,
}) async {
  if (sized) {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }
  final viewModel = RemoteSessionsViewModel(
    UserRepository(backend.service),
    userId: userId,
  );
  addTearDown(viewModel.dispose);
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      locale: const Locale('ar'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: RemoteSessionsSection(
            viewModel: viewModel,
            canRevoke: canRevoke,
            isOwn: isOwn,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
