import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';

void main() {
  test('conditional GET revalidates with the stored ETag and replays the body '
      'on 304', () async {
    final sentIfNoneMatch = <String?>[];
    var version = 1;
    final session = PosApiSession(
      client: MockClient((request) async {
        sentIfNoneMatch.add(request.headers['If-None-Match']);
        final etag = 'W/"catalog-v$version-u1"';
        if (request.headers['If-None-Match'] == etag) {
          return http.Response('', 304, headers: {'etag': etag});
        }
        return http.Response(
          jsonEncode({'results': ['v$version']}),
          200,
          headers: {'etag': etag},
        );
      }),
      baseUrl: 'http://pointy.test/api',
    );

    // First fetch: no validator yet, full 200 stored.
    final first = await session.get('products/', conditionalCache: true);
    expect(first.statusCode, 200);
    expect(sentIfNoneMatch.last, isNull);

    // Unchanged: the 304 is replayed as a 200 with the stored body.
    final second = await session.get('products/', conditionalCache: true);
    expect(sentIfNoneMatch.last, 'W/"catalog-v1-u1"');
    expect(second.statusCode, 200);
    expect(session.decodedBody(second), session.decodedBody(first));

    // Catalog changed server-side: stale validator, fresh 200 replaces it.
    version = 2;
    final third = await session.get('products/', conditionalCache: true);
    expect(third.statusCode, 200);
    expect(session.decodedBody(third), {
      'results': ['v2'],
    });
    final fourth = await session.get('products/', conditionalCache: true);
    expect(sentIfNoneMatch.last, 'W/"catalog-v2-u1"');
    expect(session.decodedBody(fourth), session.decodedBody(third));
  });

  test('entries are keyed by full URL including query parameters', () async {
    final session = PosApiSession(
      client: MockClient((request) async {
        final q = request.url.queryParameters['q'] ?? '';
        if (request.headers['If-None-Match'] == 'W/"tag-$q"') {
          return http.Response('', 304, headers: {'etag': 'W/"tag-$q"'});
        }
        return http.Response(
          jsonEncode({'q': q}),
          200,
          headers: {'etag': 'W/"tag-$q"'},
        );
      }),
      baseUrl: 'http://pointy.test/api',
    );

    await session.get('products/', query: {'q': 'a'}, conditionalCache: true);
    final differentQuery = await session.get(
      'products/',
      query: {'q': 'b'},
      conditionalCache: true,
    );
    expect(session.decodedBody(differentQuery), {'q': 'b'});
    final revalidated = await session.get(
      'products/',
      query: {'q': 'a'},
      conditionalCache: true,
    );
    expect(session.decodedBody(revalidated), {'q': 'a'});
  });

  test('logout clears stored validators', () async {
    var requests = 0;
    final session = PosApiSession(
      client: MockClient((request) async {
        requests += 1;
        if (request.headers['If-None-Match'] == 'W/"tag"') {
          return http.Response('', 304, headers: {'etag': 'W/"tag"'});
        }
        return http.Response('{"ok":true}', 200, headers: {'etag': 'W/"tag"'});
      }),
      baseUrl: 'http://pointy.test/api',
    );

    await session.get('products/', conditionalCache: true);
    session.clearAuthState();
    final afterLogout = await session.get('products/', conditionalCache: true);
    // No If-None-Match after logout: the mock returns a full 200.
    expect(afterLogout.statusCode, 200);
    expect(session.decodedBody(afterLogout), {'ok': true});
    expect(requests, 2);
  });

  test('responses without an ETag are never cached', () async {
    final sentIfNoneMatch = <String?>[];
    final session = PosApiSession(
      client: MockClient((request) async {
        sentIfNoneMatch.add(request.headers['If-None-Match']);
        return http.Response('{"ok":true}', 200);
      }),
      baseUrl: 'http://pointy.test/api',
    );

    await session.get('products/', conditionalCache: true);
    await session.get('products/', conditionalCache: true);
    expect(sentIfNoneMatch, [null, null]);
  });
}
