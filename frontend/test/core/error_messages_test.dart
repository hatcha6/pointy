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

  test('falls back to the generic message for non-API errors', () {
    expect(
      errorMessageFor(Exception('boom'), l10n),
      l10n.errorUnexpectedMessage,
    );
  });
}
