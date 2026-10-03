import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/error_messages.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('ar'));
  });

  test('shows the backend message (already localized) when present', () {
    const error = PosApiException(
      message: 'الرصيد غير كافٍ',
      statusCode: 400,
      responseBody: '',
    );
    expect(errorMessageFor(error, l10n), 'الرصيد غير كافٍ');
  });

  test('falls back to the server message for a blank 5xx', () {
    const error = PosApiException(
      message: '   ',
      statusCode: 503,
      responseBody: '',
    );
    expect(errorMessageFor(error, l10n), l10n.errorServerMessage);
  });

  test('falls back to the generic message for a blank 4xx', () {
    const error = PosApiException(
      message: '',
      statusCode: 400,
      responseBody: '',
    );
    expect(errorMessageFor(error, l10n), l10n.errorUnexpectedMessage);
  });

  // `throwApiException` puts a developer string in `message`, and the backend
  // answers many refusals in English or with a code. None of that may reach an
  // Arabic screen; integration errors showed "… failed with status 400".
  test('never shows the developer message a client attaches', () {
    const error = PosApiException(
      message: 'Integrations request failed with status 400',
      statusCode: 400,
      responseBody: '',
    );
    expect(errorMessageFor(error, l10n), l10n.errorUnexpectedMessage);
  });

  test('a 5xx with a developer message gets the server message', () {
    const error = PosApiException(
      message: 'Recharge failed with status 502',
      statusCode: 502,
      responseBody: '{"detail": "bad gateway"}',
    );
    expect(errorMessageFor(error, l10n), l10n.errorServerMessage);
  });

  test("shows the backend's own sentence when it wrote one in Arabic", () {
    const error = PosApiException(
      message: 'Integration save failed with status 400',
      statusCode: 400,
      responseBody: '{"detail": "تمت الإضافة مسبقاً"}',
    );
    expect(errorMessageFor(error, l10n), 'تمت الإضافة مسبقاً');
  });

  test('an English or coded backend answer falls back to Arabic copy', () {
    const error = PosApiException(
      message: 'Integration action failed with status 400',
      statusCode: 400,
      responseBody: '{"detail": "switched_off"}',
    );
    expect(errorMessageFor(error, l10n), l10n.errorUnexpectedMessage);
  });

  test('falls back to the generic message for non-API errors', () {
    expect(
      errorMessageFor(Exception('boom'), l10n),
      l10n.errorUnexpectedMessage,
    );
  });
}
