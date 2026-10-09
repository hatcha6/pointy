import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/services_fixtures.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations_ar.dart';
import 'package:pointy_frontend/src/data/models/services_directory.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/airtime_phone_step.dart';

/// Every amount a cashier reads is in a currency named in Arabic — never the
/// three Latin letters of its ISO code, unless nobody anywhere names it.
void main() {
  final l10n = AppLocalizationsAr();
  final directory = servicesPreviewDirectory();
  final mali = directory.country('ML')!;

  String label(
    String code, {
    ServiceCountry? country,
    bool withDirectory = true,
  }) => serviceCurrencyLabel(
    l10n,
    country,
    code,
    directory: withDirectory ? directory : null,
  );

  test('a country\'s own money is named the way that country says it', () {
    expect(label('XOF', country: mali), 'فرنك أفريقي');
    expect(label('xof', country: mali), 'فرنك أفريقي');
  });

  test('the dollar and the euro are named in full', () {
    expect(label('USD', country: mali), 'دولار أمريكي');
    expect(label('USD'), 'دولار أمريكي');
    expect(label('EUR', country: mali), 'يورو');
    expect(label('usd', withDirectory: false), 'دولار أمريكي');
  });

  test('any other money is named by the countries that use it', () {
    expect(label('NGN', country: mali), 'نيرة نيجيرية');
    expect(label('GHS'), 'سيدي غاني');
    expect(label('EGP'), 'جنيه مصري');
  });

  test('money nobody names is the code, held left to right', () {
    expect(label('ZZZ', country: mali), '\u{2066}ZZZ\u{2069}');
    expect(
      label('NGN', country: mali, withDirectory: false),
      '\u{2066}NGN\u{2069}',
    );
  });

  test('a name that is not Arabic is not used', () {
    final odd = ServicesDirectory.fromJson(const {
      'available': true,
      'countries': [
        {
          'code': 'XX',
          'name': 'س',
          'dial': ['1'],
          'currency': 'QQQ',
          'currency_name': 'Qqq coin',
        },
      ],
    });

    expect(odd.currencyName('QQQ'), isNull);
    expect(
      serviceCurrencyLabel(l10n, null, 'QQQ', directory: odd),
      '\u{2066}QQQ\u{2069}',
    );
  });

  test('nothing is said for no currency', () {
    expect(label(''), '');
    expect(label('  '), '');
  });
}
