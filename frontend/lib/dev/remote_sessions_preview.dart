// Dev-only preview harness for «الجلسات عن بُعد», the remote sessions section
// on «إعداداتي» and on a user's page in user management.
//
// Renders the section with a fake repository and no backend. Run with:
//
//   make frontend-remote-sessions-preview
//
// Screens: board (default) | own | user | empty | error | dark
//
// `?screen=board` lays out phone and wide frames side by side, for a single
// overview screenshot. See AGENTS.md ("UI preview harness"). Not part of the
// shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/remote_session.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/users/view_models/remote_sessions_view_model.dart';
import 'package:pointy_frontend/src/features/users/views/remote_sessions_section.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

String _screen() => Uri.base.queryParameters['screen'] ?? 'board';

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    final dark = _screen() == 'dark';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: dark ? PointyTheme.dark() : PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: const _PreviewRouter(),
    );
  }
}

class _PreviewRouter extends StatelessWidget {
  const _PreviewRouter();

  @override
  Widget build(BuildContext context) {
    return switch (_screen()) {
      'own' => _surface(_fixtures, isOwn: true),
      'user' => _surface(_fixtures, isOwn: false, canRevoke: false),
      'empty' => _surface(const [], isOwn: true),
      'error' => _surface(null, isOwn: true),
      'dark' => _surface(_fixtures, isOwn: true),
      _ => const _Board(),
    };
  }
}

Widget _surface(
  List<RemoteSession>? sessions, {
  required bool isOwn,
  bool canRevoke = true,
}) {
  return Scaffold(
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        RemoteSessionsSection(
          viewModel: RemoteSessionsViewModel(_FakeRepository(sessions)),
          canRevoke: canRevoke,
          isOwn: isOwn,
        ),
      ],
    ),
  );
}

class _Board extends StatelessWidget {
  const _Board();

  @override
  Widget build(BuildContext context) {
    Widget frame(double width, Widget child) => SizedBox(
      width: width,
      height: 900,
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: Size(width, 900),
          padding: EdgeInsets.zero,
          viewInsets: EdgeInsets.zero,
        ),
        child: child,
      ),
    );
    return Scaffold(
      body: SingleChildScrollView(
        child: Wrap(
          spacing: 24,
          runSpacing: 24,
          children: [
            frame(390, _surface(_fixtures, isOwn: true)),
            frame(820, _surface(_fixtures, isOwn: false)),
            frame(390, _surface(const [], isOwn: true)),
            frame(390, _surface(null, isOwn: true)),
          ],
        ),
      ),
    );
  }
}

final _now = DateTime.now().toUtc();

final _fixtures = [
  RemoteSession(
    id: 3,
    status: RemoteSessionStatus.active,
    deviceName: '',
    platform: 'iphone',
    browser: 'safari',
    ipAddress: '41.208.71.12',
    createdAt: _now.subtract(const Duration(hours: 3)),
    lastSeenAt: _now.subtract(const Duration(minutes: 4)),
    expiresAt: _now.add(const Duration(days: 13, hours: 21)),
    endedAt: null,
    endedByName: '',
    isCurrent: true,
  ),
  RemoteSession(
    id: 2,
    status: RemoteSessionStatus.active,
    deviceName: 'حاسوب البيت',
    platform: 'windows',
    browser: 'chrome',
    ipAddress: '2a02:9b0:4021::17',
    createdAt: _now.subtract(const Duration(days: 2)),
    lastSeenAt: _now.subtract(const Duration(hours: 20)),
    expiresAt: _now.add(const Duration(days: 12)),
    endedAt: null,
    endedByName: '',
    isCurrent: false,
  ),
  RemoteSession(
    id: 1,
    status: RemoteSessionStatus.revoked,
    deviceName: '',
    platform: 'android',
    browser: 'samsung',
    ipAddress: '102.164.97.3',
    createdAt: _now.subtract(const Duration(days: 9)),
    lastSeenAt: _now.subtract(const Duration(days: 8)),
    expiresAt: _now.add(const Duration(days: 5)),
    endedAt: _now.subtract(const Duration(days: 8)),
    endedByName: 'أحمد المالك',
    isCurrent: false,
  ),
];

class _FakeRepository extends UserRepository {
  _FakeRepository(this.sessions) : super(PosApiService());

  /// Null answers every read with an error.
  final List<RemoteSession>? sessions;

  @override
  Future<Result<List<RemoteSession>>> loadRemoteSessions({int? userId}) async {
    final list = sessions;
    return list == null ? Error(Exception('offline')) : Ok(list);
  }

  @override
  Future<Result<RemoteSession>> revokeRemoteSession(
    int id, {
    int? userId,
  }) async {
    final session = sessions!.firstWhere((item) => item.id == id);
    return Ok(session.copyWith(status: RemoteSessionStatus.revoked));
  }
}
