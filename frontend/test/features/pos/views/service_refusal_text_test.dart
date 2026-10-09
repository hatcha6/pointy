import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations_ar.dart';
import 'package:pointy_frontend/src/data/models/service_quote.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/service_texts.dart';

/// What a refused quote says, by the server's stable code — in Arabic, in
/// words about what the cashier typed, never the code itself.
void main() {
  final l10n = AppLocalizationsAr();

  test('an invoice number the provider does not take says what it takes', () {
    expect(
      serviceRefusalText(l10n, ServiceRefusalCode.invalidInvoice),
      'رقم الفاتورة غير صالح — 24 خانة كحد أقصى من الأحرف الإنجليزية والأرقام و - _ /',
    );
  });

  test('stands beside an invoice number that was not given at all', () {
    expect(
      serviceRefusalText(l10n, ServiceRefusalCode.invoiceRequired),
      'هذه الجهة تطلب رقم الفاتورة',
    );
    expect(
      serviceRefusalText(l10n, ServiceRefusalCode.invalidInvoice),
      isNot(serviceRefusalText(l10n, ServiceRefusalCode.invoiceRequired)),
    );
  });

  test('is not one worth asking again: the number will still be wrong', () {
    expect(
      ServiceRefusalCode.isTransient(ServiceRefusalCode.invalidInvoice),
      isFalse,
    );
    expect(
      ServiceQuoteRefusal(
        errorCode: ServiceRefusalCode.invalidInvoice,
      ).isTransient,
      isFalse,
    );
  });

  test('is the relay\'s own word for it', () {
    expect(ServiceRefusalCode.invalidInvoice, 'invalid_invoice');
  });

  test('every code the quote can refuse with has words of its own', () {
    const codes = [
      ServiceRefusalCode.invalidPhone,
      ServiceRefusalCode.invalidAccount,
      ServiceRefusalCode.invoiceRequired,
      ServiceRefusalCode.invalidInvoice,
      ServiceRefusalCode.amountNotOffered,
      ServiceRefusalCode.invalidAmount,
      ServiceRefusalCode.unknownOperator,
      ServiceRefusalCode.unknownBiller,
      ServiceRefusalCode.serviceUnavailable,
      ServiceRefusalCode.rateUnset,
      ServiceRefusalCode.unreachable,
      ServiceRefusalCode.notConfigured,
      ServiceRefusalCode.switchedOff,
    ];
    final other = serviceRefusalText(l10n, 'something_new');
    for (final code in codes) {
      final text = serviceRefusalText(l10n, code);
      expect(text, isNotEmpty, reason: code);
      expect(RegExp('[A-Za-z]{3,}').hasMatch(text), isFalse, reason: code);
      expect(
        text,
        isNot(other),
        reason: '$code must not fall to the catch-all',
      );
    }
  });
}
