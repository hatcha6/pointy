import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/services/api_error_detail.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';

/// Every 4xx this backend sends carries a reason, and until now almost none of
/// it reached the screen. These pin the shapes DRF actually emits, because the
/// cost of getting this wrong is measured in button presses: 41 on a purchase
/// order save, 21 on a register close, both against a server that answered
/// clearly every time.
void main() {
  PosApiException failure(int status, String body) =>
      PosApiException(message: 'failed', statusCode: status, responseBody: body);

  group('apiErrorDetail', () {
    test('reads a plain detail', () {
      expect(
        apiErrorDetail(
          failure(400, '{"detail":"Register session is already closed."}'),
        ),
        'Register session is already closed.',
      );
    });

    test('flattens per-field lists', () {
      expect(
        apiErrorDetail(failure(400, '{"quantity":["Quantity must be positive."]}')),
        'Quantity must be positive.',
      );
    });

    test('reaches into nested row errors and skips the blank rows', () {
      final detail = apiErrorDetail(
        failure(
          400,
          '{"lines":[{"unit_cost":["Unit cost cannot be negative."]},{}]}',
        ),
      );
      expect(detail, 'Unit cost cannot be negative.');
    });

    test('puts detail first, then the other fields', () {
      final detail = apiErrorDetail(
        failure(400, '{"quantity":["Bad quantity."],"detail":"Nope."}'),
      );
      expect(detail, startsWith('Nope.'));
      expect(detail, contains('Bad quantity.'));
    });

    test('does not repeat the same message twice', () {
      expect(
        apiErrorDetail(failure(400, '{"a":["Same."],"b":["Same."]}')),
        'Same.',
      );
    });

    test('caps how many messages it joins', () {
      final detail = apiErrorDetail(
        failure(400, '{"a":["1"],"b":["2"],"c":["3"],"d":["4"]}'),
        maxParts: 2,
      );
      expect(detail.split(' · '), hasLength(2));
    });

    test('is empty when there is nothing to say', () {
      // Callers fall back to their own wording; a placeholder would be worse
      // than the generic message it replaced.
      expect(apiErrorDetail(failure(400, 'not json at all')), '');
      expect(apiErrorDetail(failure(400, '[]')), '');
      expect(apiErrorDetail(Exception('a plain error')), '');
      expect(apiErrorDetail(null), '');
    });

    test('leaves the machine code out of the readable text', () {
      expect(
        apiErrorDetail(
          failure(
            403,
            '{"code":"attachment_token_expired","detail":"This link has expired."}',
          ),
        ),
        'This link has expired.',
      );
    });
  });

  group('apiErrorCode', () {
    test('reads the code when the response named itself', () {
      expect(
        apiErrorCode(failure(400, '{"code":"register_session_already_closed"}')),
        'register_session_already_closed',
      );
    });

    test('is null when there is none, or when it is not a string', () {
      expect(apiErrorCode(failure(400, '{"detail":"x"}')), isNull);
      expect(apiErrorCode(failure(400, '{"code":7}')), isNull);
      expect(apiErrorCode(Exception('nope')), isNull);
    });
  });

  group('apiStatusCode', () {
    test('surfaces the status for an API failure only', () {
      expect(apiStatusCode(failure(422, '{}')), 422);
      expect(apiStatusCode(Exception('nope')), isNull);
    });
  });
}
