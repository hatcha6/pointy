import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/models/search_miss.dart';
import 'package:pointy_frontend/src/data/services/api_error_detail.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/data/services/search_miss_api_client.dart';

const _lan = 'http://lan.test/api';

http.Response _json(Object body, int statusCode) {
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

const _row = {
  'id': 7,
  'term': 'كاتشب575',
  'normalized': 'كاتشب 575',
  'surface': 'pos',
  'count': 12,
  'last_seen_at': '2026-09-29T08:30:00Z',
  'status': 'open',
  'product': null,
  'product_name': null,
  'resolved_at': null,
};

SearchMissApiClient _client(
  List<http.Request> seen,
  http.Response Function(http.Request request) answer,
) {
  return SearchMissApiClient(
    PosApiSession(
      client: MockClient((request) async {
        seen.add(request);
        return answer(request);
      }),
      baseUrl: _lan,
    ),
  );
}

void main() {
  test('reads a page of the worklist for a status', () async {
    final seen = <http.Request>[];
    final client = _client(
      seen,
      (_) => _json({
        'count': 51,
        'next': '$_lan/search-misses/?page=3&status=all',
        'previous': null,
        'results': [_row],
      }, 200),
    );

    final page = await client.fetchPage(page: 2, filter: SearchMissFilter.all);

    expect(seen.single.method, 'GET');
    expect(seen.single.url.path, '/api/search-misses/');
    expect(seen.single.url.queryParameters, {'page': '2', 'status': 'all'});
    expect(page.hasMore, isTrue);
    final row = page.misses.single;
    expect(row.id, 7);
    expect(row.term, 'كاتشب575');
    expect(row.normalized, 'كاتشب 575');
    expect(row.surface, SearchMissSurface.pos);
    expect(row.count, 12);
    expect(row.lastSeenAt, DateTime.utc(2026, 9, 29, 8, 30).toLocal());
    expect(row.status, SearchMissStatus.open);
    expect(row.productId, isNull);
    expect(row.productName, isNull);
  });

  test('resolves with the product id and reads the row back', () async {
    final seen = <http.Request>[];
    final client = _client(
      seen,
      (_) => _json({
        ..._row,
        'status': 'resolved',
        'product': 42,
        'product_name': 'كاتشب هاينز',
        'resolved_at': '2026-09-29T09:00:00Z',
      }, 200),
    );

    final row = await client.resolve(7, productId: 42);

    expect(seen.single.method, 'POST');
    expect(seen.single.url.path, '/api/search-misses/7/resolve/');
    expect(jsonDecode(seen.single.body), {'product': 42});
    expect(row.status, SearchMissStatus.resolved);
    expect(row.productId, 42);
    expect(row.productName, 'كاتشب هاينز');
  });

  test('dismisses and reopens by id', () async {
    final seen = <http.Request>[];
    final client = _client(
      seen,
      (request) => _json({
        ..._row,
        'status': request.url.path.contains('dismiss') ? 'dismissed' : 'open',
      }, 200),
    );

    expect((await client.dismiss(7)).status, SearchMissStatus.dismissed);
    expect((await client.reopen(7)).status, SearchMissStatus.open);
    expect(seen.map((request) => request.url.path), [
      '/api/search-misses/7/dismiss/',
      '/api/search-misses/7/reopen/',
    ]);
  });

  test('a refused product keeps the body that says which field', () async {
    final client = _client(
      [],
      (_) => _json({
        'product': ['A product a feature owns keeps the names it was given.'],
      }, 400),
    );

    await expectLater(
      client.resolve(7, productId: 1),
      throwsA(
        isA<PosApiException>()
            .having((error) => error.statusCode, 'statusCode', 400)
            .having(
              (error) => apiErrorHasField(error, 'product'),
              'names product',
              isTrue,
            ),
      ),
    );
  });
}
