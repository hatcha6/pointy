/// One id that follows an action from the tap to the row.
///
/// `trace_id` was empty on all 417,527 rows of the last field export, so
/// nothing recorded anywhere could be connected to anything else: a slow
/// checkout on the till and the request that served it were two unrelated
/// facts. The client is the only party that can mint it, because it is the only
/// one present before the request exists.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';

void main() {
  late List<Map<String, String>> sent;
  late List<ApiRequestPerformance> recorded;

  PosApiSession sessionThatAnswers({int status = 200}) {
    final session = PosApiSession(
      client: MockClient((request) async {
        sent.add(request.headers);
        return http.Response('{"ok":true}', status);
      }),
      baseUrl: 'http://pointy.test/api',
    );
    session.performanceRecorder = recorded.add;
    return session;
  }

  setUp(() {
    sent = [];
    recorded = [];
  });

  group('every request can be followed to the row it produced', () {
    test('a request carries a trace id even before anyone signs in', () async {
      final session = sessionThatAnswers();

      await session.get('shop-settings/');

      expect(sent.single['X-Request-ID'], isNotEmpty);
    });

    test('two requests are two traces', () async {
      final session = sessionThatAnswers();

      await session.get('shop-settings/');
      await session.get('products/');

      expect(sent, hasLength(2));
      expect(sent.first['X-Request-ID'], isNot(sent.last['X-Request-ID']));
    });

    test('the id reported with the timing is the id that went out', () async {
      // The join has to work from either side. If the client recorded one id
      // and sent another, `frontend.http_request` and the backend's own row
      // would both carry a trace and still never meet.
      final session = sessionThatAnswers();

      await session.get('shop-settings/');

      expect(recorded.single.traceId, sent.single['X-Request-ID']);
    });

    test('a request that failed still reports its trace', () async {
      // A timeout proves nothing about what the server did. The id is the only
      // way to tell "the till gave up and the sale was never recorded" from
      // "the till gave up and the sale went through anyway".
      final session = PosApiSession(
        client: MockClient((request) async {
          sent.add(request.headers);
          throw http.ClientException('connection reset');
        }),
        baseUrl: 'http://pointy.test/api',
      );
      session.performanceRecorder = recorded.add;

      await expectLater(
        session.get('shop-settings/'),
        throwsA(isA<Exception>()),
      );

      expect(recorded.single.traceId, isNotEmpty);
      expect(recorded.single.traceId, sent.single['X-Request-ID']);
    });
  });

  group('a request says which drawer it belongs to', () {
    test('the open register session rides on every request', () async {
      // The client is the one that knows. A cashier can close the drawer
      // between an action and the row being written, so asking the database
      // afterwards answers about then rather than about the action.
      final session = sessionThatAnswers();
      session.describeRegisterSession('482');

      await session.get('shop-settings/');

      expect(sent.single['X-Pointy-Register-Session'], '482');
    });

    test('no open drawer means no header, not an empty one', () async {
      final session = sessionThatAnswers();

      await session.get('shop-settings/');

      expect(sent.single.containsKey('X-Pointy-Register-Session'), isFalse);
    });

    test('closing the drawer stops the header', () async {
      final session = sessionThatAnswers();
      session.describeRegisterSession('482');
      await session.get('shop-settings/');

      session.describeRegisterSession(null);
      await session.get('shop-settings/');

      expect(sent.first['X-Pointy-Register-Session'], '482');
      expect(sent.last.containsKey('X-Pointy-Register-Session'), isFalse);
    });
  });
}
