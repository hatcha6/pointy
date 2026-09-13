import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/core/server_state.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';

PosApiSession _sessionStamping(Map<String, String> headers) => PosApiSession(
  client: MockClient(
    (_) async => http.Response(jsonEncode({'ok': true}), 200, headers: headers),
  ),
  baseUrl: 'http://pointy.test/api',
);

void main() {
  test('every response feeds the state vector', () async {
    // The header rides on all API traffic, so a till learns what changed from
    // whatever it was already doing.
    final session = _sessionStamping({
      'x-pointy-state': 'catalog=812,catalog_defs=77,settings=37',
    });

    await session.get('anything/');

    expect(session.serverState.versionOf(ServerStateDomain.catalog), '812');
    expect(session.serverState.versionOf(ServerStateDomain.catalogDefs), '77');
    expect(session.serverState.versionOf(ServerStateDomain.settings), '37');
    expect(session.catalogVersionToken, '812');
  });

  test(
    'an older backend sending only the legacy headers still works',
    () async {
      // compat/win8 and any client-side upgrade that outruns the backend.
      final session = _sessionStamping({
        'x-pointy-catalog-version': '5',
        'x-pointy-discounts-version': '2',
      });

      await session.get('anything/');

      expect(session.catalogVersionToken, '5');
      expect(session.discountsVersionToken, '2');
    },
  );

  test(
    'the vector wins over the legacy headers when both are present',
    () async {
      // They come from one read server-side and cannot disagree; if they ever
      // did, the richer one is the source of truth.
      final session = _sessionStamping({
        'x-pointy-state': 'catalog=9,discounts=4',
        'x-pointy-catalog-version': '9',
        'x-pointy-discounts-version': '4',
      });

      await session.get('anything/');

      expect(session.catalogVersionToken, '9');
      expect(session.discountsVersionToken, '4');
    },
  );

  test('a backend that publishes nothing leaves the tokens null', () async {
    final session = _sessionStamping(const {});

    await session.get('anything/');

    expect(session.catalogVersionToken, isNull);
    expect(session.discountsVersionToken, isNull);
  });

  test('signing out forgets the vector', () async {
    // Counters belong to one session. Carrying them across would make the next
    // vector look unchanged when in truth we know nothing.
    final session = _sessionStamping({'x-pointy-state': 'catalog=3'});
    await session.get('anything/');
    expect(session.catalogVersionToken, '3');

    session.clearAuthState();
    expect(session.catalogVersionToken, isNull);
  });

  test(
    'purgeCachedResponses drops stored bodies but keeps the session',
    () async {
      // What a permissions change triggers: data read under permissions the user
      // no longer has must not survive to be shown, and an If-None-Match against
      // it would even be answered 304.
      var serves = 0;
      final session = PosApiSession(
        client: MockClient((request) async {
          serves++;
          if (request.headers['If-None-Match'] == 'W/"tag"') {
            return http.Response('', 304, headers: {'etag': 'W/"tag"'});
          }
          return http.Response(
            jsonEncode({'secret': 'payroll'}),
            200,
            headers: {'etag': 'W/"tag"'},
          );
        }),
        baseUrl: 'http://pointy.test/api',
      );

      await session.get('reports/', conditionalCache: true);
      await session.get('reports/', conditionalCache: true);
      expect(
        serves,
        2,
        reason: 'second call revalidated against the stored body',
      );

      session.purgeCachedResponses();
      final afterPurge = await session.get('reports/', conditionalCache: true);
      expect(afterPurge.statusCode, 200);
      expect(
        session.decodedBody(afterPurge),
        {'secret': 'payroll'},
        reason: 'refetched in full rather than replayed from the purged cache',
      );
    },
  );
}
