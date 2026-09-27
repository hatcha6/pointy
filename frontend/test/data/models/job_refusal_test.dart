import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/job_refusal.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';

PosApiException _badRequest(String body) {
  return PosApiException(
    message: 'refused',
    statusCode: 400,
    responseBody: body,
  );
}

void main() {
  test('a refusal for want of a drawer is one the app can act on', () {
    final refusal = jobRefusalFromException(
      _badRequest(
        '{"code": "register_session_required", '
        '"detail": "No open register session for this request owner."}',
      ),
    );

    expect(refusal?.kind, JobRefusalKind.registerSessionRequired);
  });

  test('a backend from before the code still reads as a drawer refusal', () {
    // Tills update from the shop's server, but not in lockstep with it.
    final refusal = jobRefusalFromException(
      _badRequest(
        '{"detail": "No open register session for this request owner."}',
      ),
    );

    expect(refusal?.kind, JobRefusalKind.registerSessionRequired);
  });

  test('an uncoded refusal about something else stays unexplained', () {
    expect(
      jobRefusalFromException(
        _badRequest('{"detail": "Job is already in this stage."}'),
      ),
      isNull,
    );
  });

  test('the settlement refusal is still recognised', () {
    final refusal = jobRefusalFromException(
      _badRequest('{"code": "settlement_required", "detail": "settle first"}'),
    );

    expect(refusal?.kind, JobRefusalKind.settlementRequired);
  });
}
