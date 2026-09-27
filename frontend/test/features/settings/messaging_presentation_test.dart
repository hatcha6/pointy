import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/features/settings/views/messaging_presentation.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('ar'));

  // Every OutboundMessage.error_code the contract lists for the UI.
  const contractCodes = [
    'not_entitled',
    'service_disabled',
    'monthly_limit',
    'rate_limited',
    'template_not_configured',
    'template_required',
    'invalid_phone',
    'bad_number',
    'provider_credit',
    'provider_unauthorized',
    'provider_rejected',
    'provider_error',
    'sms_unconfigured',
    'relay_unreachable',
    'outcome_unknown',
    'driver_error',
    'delivery_failed',
  ];

  test('every contract error code has an Arabic sentence', () {
    for (final code in contractCodes) {
      final sentence = messagingErrorMessage(code, l10n);
      expect(sentence, isNotNull, reason: code);
      expect(sentence, isNot(contains('_')), reason: code);
    }
  });

  test('codes that mean the same thing say the same thing', () {
    expect(
      messagingErrorMessage('bad_number', l10n),
      messagingErrorMessage('invalid_phone', l10n),
    );
    expect(
      messagingErrorMessage('unknown_kind', l10n),
      messagingErrorMessage('template_not_configured', l10n),
    );
    expect(
      messagingErrorMessage('outcome_unknown', l10n),
      messagingErrorMessage('provider_error', l10n),
    );
  });

  group('messagingFailureMessage', () {
    test('prefers the mapped sentence over the raw detail', () {
      expect(
        messagingFailureMessage(
          l10n,
          code: 'monthly_limit',
          detail: 'monthly SMS limit reached',
          fallback: 'x',
        ),
        l10n.messagingErrorMonthlyLimit,
      );
    });

    test('an unknown code falls back to the detail, then the fallback', () {
      expect(
        messagingFailureMessage(
          l10n,
          code: 'too_long',
          detail: 'الرسالة أطول من المسموح.',
          fallback: 'x',
        ),
        'الرسالة أطول من المسموح.',
      );
      expect(messagingFailureMessage(l10n, fallback: 'بديل'), 'بديل');
    });

    test('a provider rejection keeps the provider reason', () {
      final text = messagingFailureMessage(
        l10n,
        code: 'provider_rejected',
        detail: 'LY phones must be made of 9 numbers',
        fallback: 'x',
      );

      expect(text, startsWith(l10n.messagingErrorProviderRejected));
      expect(text, endsWith('LY phones must be made of 9 numbers'));
    });
  });
}
