import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';

void main() {
  test('every response names the backend release', () async {
    var release = '0.7.9';
    final session = PosApiSession(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'ok': true}),
          200,
          headers: {'x-pointy-server-version': release},
        ),
      ),
      baseUrl: 'http://pointy.test/api',
    );
    final seen = <String?>[];
    session.serverVersion.addListener(
      () => seen.add(session.serverVersion.value),
    );

    await session.get('anything/');
    await session.get('anything/');
    release = '0.8.0';
    await session.get('anything/');

    expect(session.serverVersion.value, '0.8.0');
    expect(seen, ['0.7.9', '0.8.0'], reason: 'only a change is news');
  });

  test('a 304 still carries it, so an idle poll notices an update', () async {
    var calls = 0;
    final session = PosApiSession(
      client: MockClient((_) async {
        calls += 1;
        if (calls == 1) {
          return http.Response(
            jsonEncode({'versions': {}}),
            200,
            headers: {'etag': 'W/"v"', 'x-pointy-server-version': '0.7.9'},
          );
        }
        return http.Response(
          '',
          304,
          headers: {'etag': 'W/"v"', 'x-pointy-server-version': '0.8.0'},
        );
      }),
      baseUrl: 'http://pointy.test/api',
    );

    await session.get('state/', conditionalCache: true);
    await session.get('state/', conditionalCache: true);

    expect(session.serverVersion.value, '0.8.0');
  });

  test('an older backend that sends nothing leaves it unknown', () async {
    final session = PosApiSession(
      client: MockClient(
        (_) async => http.Response(jsonEncode({'ok': true}), 200),
      ),
      baseUrl: 'http://pointy.test/api',
    );

    await session.get('anything/');

    expect(session.serverVersion.value, isNull);
  });
}
