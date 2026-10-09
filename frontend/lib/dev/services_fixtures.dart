// Dev-only fake directory for «كروت دفتر»' direct services — airtime sent to a
// phone abroad, bills paid abroad — for the preview harness, its capture test
// and the view-model tests.
//
// Everything is built as the JSON the shop's backend serves and parsed by the
// real models, so the preview exercises the parsers too. Names are Arabic, as
// the relay sends them, with the Latin spelling alongside in `name_en` (only
// ever searched). Not part of the shipping app. Safe to delete.
import 'package:pointy_frontend/src/data/models/service_country_detail.dart';
import 'package:pointy_frontend/src/data/models/services_directory.dart';

/// LYD per unit of each currency: what the fake relay prices amounts with.
const Map<String, double> _lydPer = {
  'XOF': 0.01827,
  'XAF': 0.01827,
  'NGN': 0.0068,
  'EGP': 0.205,
  'TND': 3.2,
  'GHS': 0.63,
  'USD': 10.2,
  'TRY': 0.3,
  'BDT': 0.085,
  'PKR': 0.036,
  'INR': 0.12,
  'PHP': 0.18,
  'MAD': 1.02,
  'DZD': 0.075,
  'KES': 0.079,
  'UGX': 0.0028,
  'TZS': 0.0039,
  'ZAR': 0.57,
  'GBP': 13.2,
  'CAD': 7.4,
  'TTD': 1.5,
  'AED': 2.78,
  'SAR': 2.72,
  'JOD': 14.4,
  'MZN': 0.16,
  'MWK': 0.006,
};

/// What a cashier says next to an amount, by currency.
const Map<String, String> _currencyNames = {
  'XOF': 'فرنك أفريقي',
  'XAF': 'فرنك وسط أفريقي',
  'NGN': 'نيرة نيجيرية',
  'EGP': 'جنيه مصري',
  'TND': 'دينار تونسي',
  'GHS': 'سيدي غاني',
  'USD': 'دولار',
  'TRY': 'ليرة تركية',
  'BDT': 'تاكا بنغلاديشية',
  'PKR': 'روبية باكستانية',
  'INR': 'روبية هندية',
  'PHP': 'بيزو فلبيني',
  'MAD': 'درهم مغربي',
  'DZD': 'دينار جزائري',
  'KES': 'شلن كيني',
  'UGX': 'شلن أوغندي',
  'TZS': 'شلن تنزاني',
  'ZAR': 'راند جنوب أفريقي',
  'GBP': 'جنيه إسترليني',
  'CAD': 'دولار كندي',
  'TTD': 'دولار ترينيداد',
  'AED': 'درهم إماراتي',
  'SAR': 'ريال سعودي',
  'JOD': 'دينار أردني',
  'MZN': 'متيكال موزمبيقي',
  'MWK': 'كواشا ملاوية',
};

/// The dinar price of [amount] (in [currency]) the fake relay quotes: the
/// converted cost plus a margin, rounded up to the next 0.25.
double servicesPreviewPrice(num amount, String currency) {
  final cost = amount * (_lydPer[currency] ?? 1) * 1.055;
  return (cost / 0.25).ceil() * 0.25;
}

String _money(double value) => value.toStringAsFixed(2);

String _plain(num value) =>
    value == value.roundToDouble() ? value.toInt().toString() : '$value';

class _Country {
  const _Country(
    this.code,
    this.name,
    this.nameEn,
    this.dial,
    this.currency, {
    this.popular = 0,
  });

  final String code;
  final String name;
  final String nameEn;
  final List<String> dial;
  final String currency;
  final int popular;
}

const List<_Country> _countries = [
  _Country('ML', 'مالي', 'Mali', ['223'], 'XOF', popular: 2),
  _Country('NG', 'نيجيريا', 'Nigeria', ['234'], 'NGN', popular: 3),
  _Country('NE', 'النيجر', 'Niger', ['227'], 'XOF', popular: 1),
  _Country('EG', 'مصر', 'Egypt', ['20'], 'EGP', popular: 4),
  _Country('TN', 'تونس', 'Tunisia', ['216'], 'TND', popular: 5),
  _Country('GH', 'غانا', 'Ghana', ['233'], 'GHS', popular: 6),
  _Country('SN', 'السنغال', 'Senegal', ['221'], 'XOF', popular: 7),
  _Country('TR', 'تركيا', 'Turkey', ['90'], 'TRY', popular: 8),
  _Country('BD', 'بنغلاديش', 'Bangladesh', ['880'], 'BDT', popular: 9),
  _Country('PK', 'باكستان', 'Pakistan', ['92'], 'PKR', popular: 10),
  _Country('IN', 'الهند', 'India', ['91'], 'INR', popular: 11),
  _Country('PH', 'الفلبين', 'Philippines', ['63'], 'PHP', popular: 12),
  _Country('MA', 'المغرب', 'Morocco', ['212'], 'MAD'),
  _Country('DZ', 'الجزائر', 'Algeria', ['213'], 'DZD'),
  _Country('CM', 'الكاميرون', 'Cameroon', ['237'], 'XAF'),
  _Country('CI', 'ساحل العاج', 'Cote d Ivoire', ['225'], 'XOF'),
  _Country('BF', 'بوركينا فاسو', 'Burkina Faso', ['226'], 'XOF'),
  _Country('TG', 'توغو', 'Togo', ['228'], 'XOF'),
  _Country('BJ', 'بنين', 'Benin', ['229'], 'XOF'),
  _Country('KE', 'كينيا', 'Kenya', ['254'], 'KES'),
  _Country('UG', 'أوغندا', 'Uganda', ['256'], 'UGX'),
  _Country('TZ', 'تنزانيا', 'Tanzania', ['255'], 'TZS'),
  _Country('ZA', 'جنوب أفريقيا', 'South Africa', ['27'], 'ZAR'),
  _Country('GB', 'المملكة المتحدة', 'United Kingdom', ['44'], 'GBP'),
  _Country('US', 'الولايات المتحدة', 'United States', ['1'], 'USD'),
  _Country('CA', 'كندا', 'Canada', ['1'], 'CAD'),
  _Country('TT', 'ترينيداد وتوباغو', 'Trinidad and Tobago', ['1868'], 'TTD'),
  _Country('AE', 'الإمارات', 'United Arab Emirates', ['971'], 'AED'),
  _Country('SA', 'السعودية', 'Saudi Arabia', ['966'], 'SAR'),
  _Country('JO', 'الأردن', 'Jordan', ['962'], 'JOD'),
  _Country('MZ', 'موزمبيق', 'Mozambique', ['258'], 'MZN'),
  _Country('MW', 'ملاوي', 'Malawi', ['265'], 'MWK'),
];

const List<(String, String, String)> _unsupported = [
  ('SD', 'السودان', 'Sudan'),
  ('TD', 'تشاد', 'Chad'),
  ('SY', 'سوريا', 'Syria'),
  ('SO', 'الصومال', 'Somalia'),
  ('ER', 'إريتريا', 'Eritrea'),
  ('LY', 'ليبيا', 'Libya'),
];

// --- amounts ------------------------------------------------------------------

Map<String, Object?> _amount(
  num amount,
  String currency, {
  String? receive,
  String? receiveCurrency,
  double? price,
}) => {
  'amount': _plain(amount),
  'receive': receive ?? _plain(amount),
  'receive_currency': receiveCurrency ?? currency,
  'price': _money(price ?? servicesPreviewPrice(amount, currency)),
};

/// A network that takes any amount between [min] and [max]; [suggestions] are
/// the round amounts the till offers as tiles.
Map<String, Object?> _rangeOperator(
  int id,
  String name,
  String nameEn,
  String currency,
  num min,
  num max,
  List<num> suggestions, {
  num? popular,
}) => {
  'id': id,
  'name': name,
  'name_en': nameEn,
  'logo': '',
  'mode': 'range',
  'amount_currency': currency,
  'receive_currency': currency,
  'approximate': false,
  'min': _plain(min),
  'max': _plain(max),
  'amounts': [for (final amount in suggestions) _amount(amount, currency)],
  'popular_amount': popular == null ? null : _plain(popular),
};

/// A network that sells only the listed denominations.
Map<String, Object?> _fixedOperator(
  int id,
  String name,
  String nameEn,
  String currency,
  List<num> amounts, {
  num? popular,
}) => {
  'id': id,
  'name': name,
  'name_en': nameEn,
  'logo': '',
  'mode': 'fixed',
  'amount_currency': currency,
  'receive_currency': currency,
  'approximate': false,
  'amounts': [for (final amount in amounts) _amount(amount, currency)],
  'popular_amount': popular == null ? null : _plain(popular),
};

/// A network paid in dollars whose recipient gets an approximate local amount.
Map<String, Object?> _approximateOperator(
  int id,
  String name,
  String nameEn,
  String receiveCurrency,
  List<(int, int)> usdAndReceive,
) => {
  'id': id,
  'name': name,
  'name_en': nameEn,
  'logo': '',
  'mode': 'fixed',
  'amount_currency': 'USD',
  'receive_currency': receiveCurrency,
  'approximate': true,
  'amounts': [
    for (final (usd, receive) in usdAndReceive)
      _amount(
        usd,
        'USD',
        receive: _plain(receive),
        receiveCurrency: receiveCurrency,
      ),
  ],
  'popular_amount': null,
};

/// A provider that takes any amount between [min] and [max].
Map<String, Object?> _rangeBiller(
  int id,
  String name,
  String nameEn,
  String type,
  String service,
  String currency,
  num min,
  num max,
  List<num> suggestions, {
  bool requiresInvoice = false,
}) => {
  'id': id,
  'name': name,
  'name_en': nameEn,
  'type': type,
  'service': service,
  'mode': 'range',
  'requires_invoice': requiresInvoice,
  'amount_currency': currency,
  'min': _plain(min),
  'max': _plain(max),
  'suggested': [
    for (final amount in suggestions)
      {
        'amount': _plain(amount),
        'price': _money(servicesPreviewPrice(amount, currency)),
      },
  ],
};

/// A provider that sells only plans.
Map<String, Object?> _fixedBiller(
  int id,
  String name,
  String nameEn,
  String type,
  String currency,
  List<(int, num, String, String)> plans,
) => {
  'id': id,
  'name': name,
  'name_en': nameEn,
  'type': type,
  'service': 'prepaid',
  'mode': 'fixed',
  'requires_invoice': false,
  'amount_currency': currency,
  'plans': [
    for (final (planId, amount, description, descriptionEn) in plans)
      {
        'id': planId,
        'amount': _plain(amount),
        'description': description,
        'description_en': descriptionEn,
        'price': _money(servicesPreviewPrice(amount, currency)),
      },
  ],
};

// --- the countries' networks and providers --------------------------------------

/// Operators of the countries the harness builds by hand; every other
/// directory country gets [_genericOperators].
final Map<String, List<Map<String, Object?>>> _operators = {
  'ML': [
    _rangeOperator(289, 'أورنج مالي', 'Orange Mali', 'XOF', 1967, 32800, [
      2000,
      5000,
      10000,
      15000,
      25000,
    ], popular: 5000),
    _fixedOperator(290, 'مالتل', 'Malitel', 'XOF', [1000, 2000, 5000, 10000]),
    _fixedOperator(291, 'تيليسيل مالي', 'Telecel Mali', 'XOF', [
      500,
      1000,
      2000,
      5000,
    ]),
  ],
  'NE': [
    _rangeOperator(301, 'إيرتل النيجر', 'Airtel Niger', 'XOF', 500, 50000, [
      1000,
      2000,
      5000,
      10000,
      20000,
    ], popular: 2000),
    _rangeOperator(302, 'موف النيجر', 'Moov Niger', 'XOF', 500, 50000, [
      1000,
      2000,
      5000,
      10000,
    ]),
    _fixedOperator(303, 'نيجر تيليكوم', 'Niger Telecom', 'XOF', [
      500,
      1000,
      2000,
      5000,
    ]),
  ],
  'NG': [
    _rangeOperator(310, 'إم تي إن نيجيريا', 'MTN Nigeria', 'NGN', 50, 50000, [
      200,
      500,
      1000,
      2000,
      5000,
    ], popular: 1000),
    _rangeOperator(311, 'إيرتل نيجيريا', 'Airtel Nigeria', 'NGN', 50, 50000, [
      200,
      500,
      1000,
      2000,
      5000,
    ]),
    _rangeOperator(312, 'غلو نيجيريا', 'Glo Nigeria', 'NGN', 50, 50000, [
      200,
      500,
      1000,
      2000,
    ]),
    _fixedOperator(313, '9موبايل', '9mobile', 'NGN', [100, 200, 500, 1000]),
  ],
  'EG': [
    _fixedOperator(320, 'فودافون مصر', 'Vodafone Egypt', 'EGP', [
      5,
      10,
      15,
      20,
      25,
      50,
      100,
    ], popular: 20),
    _fixedOperator(321, 'أورنج مصر', 'Orange Egypt', 'EGP', [
      5,
      10,
      15,
      20,
      25,
      50,
    ]),
    _fixedOperator(322, 'اتصالات مصر', 'Etisalat Egypt', 'EGP', [
      5,
      10,
      15,
      25,
      50,
    ]),
    _fixedOperator(323, 'وي مصر', 'WE Egypt', 'EGP', [5, 10, 20, 50, 100]),
  ],
  'TN': [
    _rangeOperator(330, 'أوريدو تونس', 'Ooredoo Tunisia', 'TND', 1, 50, [
      1,
      2,
      5,
      10,
      20,
    ]),
    _rangeOperator(331, 'أورنج تونس', 'Orange Tunisie', 'TND', 1, 50, [
      1,
      2,
      5,
      10,
    ]),
    _rangeOperator(332, 'تونس تيليكوم', 'Tunisie Telecom', 'TND', 1, 50, [
      1,
      2,
      5,
      10,
    ]),
  ],
  'GH': [
    _rangeOperator(340, 'إم تي إن غانا', 'MTN Ghana', 'GHS', 1, 500, [
      2,
      5,
      10,
      20,
      50,
    ]),
    _rangeOperator(341, 'تيليسيل غانا', 'Telecel Ghana', 'GHS', 1, 500, [
      2,
      5,
      10,
      20,
    ]),
    _approximateOperator(342, 'إيرتل تيجو غانا', 'AirtelTigo Ghana', 'GHS', [
      (1, 12),
      (2, 24),
      (5, 61),
      (10, 122),
    ]),
  ],
  'SN': [
    _rangeOperator(350, 'أورنج السنغال', 'Orange Senegal', 'XOF', 500, 50000, [
      1000,
      2000,
      5000,
      10000,
    ]),
    _rangeOperator(351, 'فري السنغال', 'Free Senegal', 'XOF', 500, 50000, [
      1000,
      2000,
      5000,
    ]),
    _fixedOperator(352, 'إكسبريسو السنغال', 'Expresso Senegal', 'XOF', [
      1000,
      2000,
      5000,
    ]),
  ],
  'TR': [
    _fixedOperator(360, 'تيركسل', 'Turkcell', 'TRY', [50, 100, 150, 250]),
    _fixedOperator(361, 'فودافون تركيا', 'Vodafone Turkey', 'TRY', [
      50,
      100,
      150,
      250,
    ]),
    _fixedOperator(362, 'تورك تيليكوم', 'Turk Telekom', 'TRY', [50, 100, 200]),
  ],
};

List<Map<String, Object?>> _genericOperators(_Country country, int seed) {
  final names = switch (country.code) {
    'BD' => const [
      ('غرامين فون', 'Grameenphone'),
      ('روبي', 'Robi'),
      ('بنغلالينك', 'Banglalink'),
    ],
    'PK' => const [
      ('جاز', 'Jazz'),
      ('تيلينور باكستان', 'Telenor Pakistan'),
      ('زونغ', 'Zong'),
    ],
    'IN' => const [
      ('إيرتل الهند', 'Airtel India'),
      ('جيو', 'Jio'),
      ('في آي', 'Vi'),
    ],
    'PH' => const [('غلوب', 'Globe'), ('سمارت', 'Smart'), ('تي إن تي', 'TNT')],
    'MA' => const [
      ('اتصالات المغرب', 'Maroc Telecom'),
      ('أورنج المغرب', 'Orange Maroc'),
      ('إنوي', 'inwi'),
    ],
    'DZ' => const [
      ('موبيليس', 'Mobilis'),
      ('جيزي', 'Djezzy'),
      ('أوريدو الجزائر', 'Ooredoo Algeria'),
    ],
    'CM' => const [
      ('إم تي إن الكاميرون', 'MTN Cameroon'),
      ('أورنج الكاميرون', 'Orange Cameroon'),
      ('نكست تل', 'Nexttel'),
    ],
    'ZA' => const [
      ('فوداكوم', 'Vodacom'),
      ('إم تي إن جنوب أفريقيا', 'MTN South Africa'),
      ('سيل سي', 'Cell C'),
    ],
    'GB' => const [
      ('أو 2', 'O2'),
      ('فودافون بريطانيا', 'Vodafone UK'),
      ('ثري', 'Three'),
    ],
    'US' => const [
      ('تي موبايل', 'T-Mobile'),
      ('إيه تي آند تي', 'AT&T'),
      ('فيريزون', 'Verizon'),
    ],
    'SA' => const [
      ('إس تي سي', 'STC'),
      ('موبايلي', 'Mobily'),
      ('زين السعودية', 'Zain KSA'),
    ],
    'JO' => const [
      ('زين الأردن', 'Zain Jordan'),
      ('أورنج الأردن', 'Orange Jordan'),
      ('أمنية', 'Umniah'),
    ],
    'KE' => const [('سفاري كوم', 'Safaricom'), ('إيرتل كينيا', 'Airtel Kenya')],
    'AE' => const [('اتصالات الإمارات', 'Etisalat UAE'), ('دو', 'du')],
    _ => [
      ('إم تي إن ${country.name}', 'MTN ${country.nameEn}'),
      ('أورنج ${country.name}', 'Orange ${country.nameEn}'),
    ],
  };
  return [
    for (final (index, (name, nameEn)) in names.indexed)
      _rangeOperator(
        400 + seed * 10 + index,
        name,
        nameEn,
        country.currency,
        _genericRange(country.currency).$1,
        _genericRange(country.currency).$2,
        _genericRange(country.currency).$3,
      ),
  ];
}

/// A believable minimum, maximum and round amounts for [currency].
(num, num, List<num>) _genericRange(String currency) => switch (currency) {
  'USD' ||
  'GBP' ||
  'CAD' ||
  'TTD' ||
  'AED' ||
  'SAR' ||
  'JOD' => (5, 100, [5, 10, 20, 50]),
  'EGP' || 'TND' || 'MAD' || 'ZAR' || 'TRY' => (10, 500, [10, 20, 50, 100]),
  'INR' ||
  'PHP' ||
  'BDT' ||
  'PKR' ||
  'DZD' => (50, 5000, [100, 200, 500, 1000]),
  _ => (500, 50000, [1000, 2000, 5000, 10000]),
};

final Map<String, List<Map<String, Object?>>> _billers = {
  'NG': [
    _rangeBiller(
      5,
      'كهرباء إيكيجا (مسبقة الدفع)',
      'Ikeja Electricity Prepaid',
      'electricity',
      'prepaid',
      'NGN',
      1000,
      300000,
      [2000, 5000, 10000, 20000, 50000],
    ),
    _rangeBiller(
      6,
      'كهرباء إيكيجا (لاحقة الدفع)',
      'Ikeja Electricity Postpaid',
      'electricity',
      'postpaid',
      'NGN',
      1000,
      500000,
      [5000, 10000, 25000, 50000],
    ),
    _rangeBiller(
      7,
      'كهرباء إيكو (مسبقة الدفع)',
      'Eko Electricity Prepaid',
      'electricity',
      'prepaid',
      'NGN',
      1000,
      300000,
      [2000, 5000, 10000, 20000],
    ),
    _rangeBiller(
      8,
      'كهرباء إيكو (لاحقة الدفع)',
      'Eko Electricity Postpaid',
      'electricity',
      'postpaid',
      'NGN',
      1000,
      500000,
      [5000, 10000, 25000],
    ),
    _rangeBiller(
      9,
      'كهرباء أبوجا (مسبقة الدفع)',
      'Abuja Electricity Prepaid',
      'electricity',
      'prepaid',
      'NGN',
      1000,
      300000,
      [2000, 5000, 10000, 20000],
    ),
    _rangeBiller(
      10,
      'كهرباء أبوجا (لاحقة الدفع)',
      'Abuja Electricity Postpaid',
      'electricity',
      'postpaid',
      'NGN',
      1000,
      500000,
      [5000, 10000, 25000],
    ),
    _rangeBiller(
      11,
      'كهرباء كانو (مسبقة الدفع)',
      'Kano Electricity Prepaid',
      'electricity',
      'prepaid',
      'NGN',
      1000,
      300000,
      [2000, 5000, 10000],
    ),
    _rangeBiller(
      12,
      'كهرباء بورت هاركورت (مسبقة الدفع)',
      'Port Harcourt Electricity Prepaid',
      'electricity',
      'prepaid',
      'NGN',
      1000,
      300000,
      [2000, 5000, 10000],
    ),
    _rangeBiller(
      13,
      'كهرباء إيبادان (مسبقة الدفع)',
      'Ibadan Electricity Prepaid',
      'electricity',
      'prepaid',
      'NGN',
      1000,
      300000,
      [2000, 5000, 10000],
    ),
    _rangeBiller(
      14,
      'كهرباء إينوغو (مسبقة الدفع)',
      'Enugu Electricity Prepaid',
      'electricity',
      'prepaid',
      'NGN',
      1000,
      300000,
      [2000, 5000, 10000],
    ),
    _fixedBiller(20, 'دي إس تي في نيجيريا', 'DStv Nigeria', 'tv', 'NGN', [
      (201, 2950, 'دي إس تي في – باقة بادي – شهر', 'DStv Padi (1 month)'),
      (202, 4200, 'دي إس تي في – باقة يانغا – شهر', 'DStv Yanga (1 month)'),
      (203, 7400, 'دي إس تي في – باقة كونفام – شهر', 'DStv Confam (1 month)'),
      (
        204,
        12500,
        'دي إس تي في – باقة كومباكت – شهر',
        'DStv Compact (1 month)',
      ),
      (
        205,
        29500,
        'دي إس تي في – باقة بريميوم – شهر',
        'DStv Premium (1 month)',
      ),
    ]),
    _fixedBiller(21, 'جوتي في نيجيريا', 'GOtv Nigeria', 'tv', 'NGN', [
      (211, 1300, 'جوتي في – باقة سمولي – شهر', 'GOtv Smallie (1 month)'),
      (212, 2700, 'جوتي في – باقة جينجا – شهر', 'GOtv Jinja (1 month)'),
      (213, 3950, 'جوتي في – باقة جولي – شهر', 'GOtv Jolli (1 month)'),
    ]),
    _rangeBiller(
      30,
      'سبكترانيت',
      'Spectranet',
      'internet',
      'prepaid',
      'NGN',
      1000,
      100000,
      [2000, 5000, 10000, 20000],
    ),
  ],
  'ML': [
    _rangeBiller(
      40,
      'طاقة مالي (EDM) – مسبقة الدفع',
      'Energie du Mali Prepaid',
      'electricity',
      'prepaid',
      'XOF',
      1000,
      100000,
      [2000, 5000, 10000, 20000],
    ),
    _fixedBiller(24, 'كانال بلس مالي', 'Canalplus Mali', 'tv', 'XOF', [
      (
        241,
        10000,
        'كانال بلس أكسيس إنجليش بيسك – شهر',
        'Canalplus Acces English Basic (10000/1MOIS)',
      ),
      (242, 5000, 'كانال بلس أكسيس – شهر', 'Canalplus Acces (5000/1MOIS)'),
      (
        243,
        10000,
        'كانال بلس إيفاسيون – شهر',
        'Canalplus Evasion (10000/1MOIS)',
      ),
      (
        244,
        15000,
        'كانال بلس إيفاسيون بلس – شهر',
        'Canalplus Evasion+ (15000/1MOIS)',
      ),
      (245, 27000, 'كانال بلس أكسيس – 3 أشهر', 'Canalplus Acces (27000/3MOIS)'),
      (
        246,
        50000,
        'كانال بلس إيفاسيون – 6 أشهر',
        'Canalplus Evasion (50000/6MOIS)',
      ),
    ]),
  ],
  'SN': [
    _rangeBiller(
      50,
      'سينيليك – فاتورة الكهرباء',
      'Senelec Postpaid',
      'electricity',
      'postpaid',
      'XOF',
      500,
      1000000,
      const [],
      requiresInvoice: true,
    ),
    _rangeBiller(
      51,
      'سينيليك – وويوفال (مسبقة الدفع)',
      'Senelec Woyofal Prepaid',
      'electricity',
      'prepaid',
      'XOF',
      1000,
      200000,
      [2000, 5000, 10000, 20000],
    ),
    _rangeBiller(
      52,
      'سين إيو – فاتورة المياه',
      'Sen Eau',
      'water',
      'postpaid',
      'XOF',
      500,
      500000,
      const [],
      requiresInvoice: true,
    ),
    _fixedBiller(53, 'كانال بلس السنغال', 'Canalplus Senegal', 'tv', 'XOF', [
      (531, 5000, 'كانال بلس أكسيس – شهر', 'Canalplus Acces (5000/1MOIS)'),
      (
        532,
        10000,
        'كانال بلس إيفاسيون – شهر',
        'Canalplus Evasion (10000/1MOIS)',
      ),
    ]),
  ],
  'ZA': [
    _rangeBiller(
      60,
      'بلدية جوهانسبرغ (مسبقة الدفع)',
      'City Power Johannesburg Prepaid',
      'electricity',
      'prepaid',
      'ZAR',
      20,
      2000,
      [50, 100, 200, 500],
    ),
    _fixedBiller(61, 'ديستيف جنوب أفريقيا', 'DStv South Africa', 'tv', 'ZAR', [
      (611, 119, 'ديستيف – باقة إيزي فيو – شهر', 'DStv EasyView (1 month)'),
      (612, 329, 'ديستيف – باقة كومباكت – شهر', 'DStv Compact (1 month)'),
    ]),
    _rangeBiller(
      62,
      'أفريهوست',
      'Afrihost',
      'internet',
      'prepaid',
      'ZAR',
      50,
      2000,
      [99, 199, 499],
    ),
  ],
  'MZ': [
    _rangeBiller(
      70,
      'كهرباء موزمبيق (مسبقة الدفع)',
      'EDM Mozambique Prepaid',
      'electricity',
      'prepaid',
      'MZN',
      50,
      20000,
      [100, 500, 1000],
    ),
  ],
  'MW': [
    _rangeBiller(
      80,
      'كهرباء ملاوي (مسبقة الدفع)',
      'ESCOM Malawi Prepaid',
      'electricity',
      'prepaid',
      'MWK',
      1000,
      500000,
      [5000, 10000, 20000],
    ),
  ],
};

// --- building the JSON --------------------------------------------------------

List<Map<String, Object?>> _operatorsOf(_Country country) {
  final hand = _operators[country.code];
  if (hand != null) return hand;
  if (country.code == 'MZ' || country.code == 'MW') {
    return [
      _rangeOperator(
        420 + country.code.codeUnitAt(0),
        'فودكوم ${country.name}',
        'Vodacom ${country.nameEn}',
        country.currency,
        _genericRange(country.currency).$1,
        _genericRange(country.currency).$2,
        _genericRange(country.currency).$3,
      ),
    ];
  }
  return _genericOperators(country, _countries.indexOf(country) + 1);
}

Map<String, Object?> _countryJson(_Country country) => {
  'code': country.code,
  'name': country.name,
  'name_en': country.nameEn,
  'dial': country.dial,
  'currency': country.currency,
  'currency_name': _currencyNames[country.currency] ?? country.currency,
  'popular': country.popular,
};

/// `GET /api/integrations/services/countries/<CODE>/`, for one directory
/// country.
Map<String, Object?> servicesPreviewCountryJson(
  String code, {
  bool testMode = false,
}) {
  final country = _countries.firstWhere(
    (candidate) => candidate.code == code.toUpperCase(),
    orElse: () => throw StateError('no preview country $code'),
  );
  final billers = _billers[country.code] ?? const [];
  return {
    if (testMode) 'test_mode': true,
    'country': _countryJson(country),
    'airtime': {'operators': _operatorsOf(country)},
    if (billers.isNotEmpty) 'bills': {'billers': billers},
  };
}

ServiceCountryDetail servicesPreviewCountry(
  String code, {
  bool testMode = false,
}) => ServiceCountryDetail.fromJson(
  servicesPreviewCountryJson(code, testMode: testMode),
);

/// The codes the harness can answer a country request for.
List<String> get servicesPreviewCountryCodes => [
  for (final country in _countries) country.code,
];

/// `GET /api/integrations/services/directory/`: counts, calling codes and
/// names for every country, with the bill types and the countries the services
/// do not reach.
///
/// [withCounts] adds each bill type's per-country provider counts, as the shop
/// backend now sends them; an older server sends none. [testMode] is the relay
/// buying from its test supplier (`test_mode: true`).
Map<String, Object?> servicesPreviewDirectoryJson({
  bool withCounts = true,
  bool testMode = false,
}) {
  Set<String> countriesOf(String type) => {
    for (final entry in _billers.entries)
      if (entry.value.any((biller) => biller['type'] == type)) entry.key,
  };
  int billersOf(String type) => _billers.values.fold(
    0,
    (sum, billers) =>
        sum + billers.where((biller) => biller['type'] == type).length,
  );
  final billTypes = [
    for (final type in const ['electricity', 'water', 'tv', 'internet'])
      if (countriesOf(type).isNotEmpty)
        {
          'type': type,
          'countries': [
            for (final country in _countries)
              if (countriesOf(type).contains(country.code)) country.code,
          ],
          'billers': billersOf(type),
          if (withCounts)
            'counts': {
              for (final country in _countries)
                if (countriesOf(type).contains(country.code))
                  country.code: (_billers[country.code] ?? const [])
                      .where((biller) => biller['type'] == type)
                      .length,
            },
        },
  ];
  return {
    'available': true,
    'error_code': '',
    if (testMode) 'test_mode': true,
    'version': '4f1c9a7e02b3d5a8',
    'balance': '345.50',
    'popular': [
      for (final country
          in [..._countries]
            ..removeWhere((country) => country.popular == 0)
            ..sort((a, b) => a.popular.compareTo(b.popular)))
        country.code,
    ],
    'countries': [
      for (final country in _countries)
        {
          ..._countryJson(country),
          'airtime': _operatorsOf(country).length,
          'bills': (_billers[country.code] ?? const []).length,
        },
    ],
    'bill_types': billTypes,
    'unsupported': [
      for (final (code, name, nameEn) in _unsupported)
        {'code': code, 'name': name, 'name_en': nameEn},
    ],
  };
}

ServicesDirectory servicesPreviewDirectory({bool testMode = false}) =>
    ServicesDirectory.fromJson(
      servicesPreviewDirectoryJson(testMode: testMode),
    );

/// The `services` entries the voucher menu lists: airtime, and one card per
/// type of bill the directory has a provider for.
List<Map<String, Object?>> servicesPreviewMenuServicesJson({
  bool airtime = true,
  Set<String> billTypes = const {'electricity', 'water', 'tv', 'internet'},
  bool testMode = false,
}) {
  final directory = servicesPreviewDirectoryJson();
  final summaries = (directory['bill_types']! as List).cast<Map>();
  return [
    if (airtime)
      {
        'key': 'airtime',
        'kind': 'airtime',
        'available': true,
        if (testMode) 'test_mode': true,
        'variant_id': 9301,
        'countries': _countries.length,
        'providers': _countries.fold<int>(
          0,
          (sum, country) => sum + _operatorsOf(country).length,
        ),
      },
    for (final summary in summaries)
      if (billTypes.contains(summary['type']))
        {
          'key': 'bill:${summary['type']}',
          'kind': 'bill',
          'bill_type': summary['type'],
          'available': true,
          if (testMode) 'test_mode': true,
          'variant_id': 9302,
          'countries': (summary['countries']! as List).length,
          'providers': summary['billers'],
        },
  ];
}

/// The recipients the fake relay says were sold to lately.
List<Map<String, Object?>> servicesPreviewRecentsJson() => [
  {
    'phone': '+22370123456',
    'country': 'ML',
    'operator_id': 289,
    'operator_name': 'أورنج مالي',
    'amount': '5000',
    'currency': 'XOF',
    'at': '2026-10-08T09:12:00Z',
  },
  {
    'phone': '+2349031234567',
    'country': 'NG',
    'operator_id': 310,
    'operator_name': 'إم تي إن نيجيريا',
    'amount': '2000',
    'currency': 'NGN',
    'at': '2026-10-07T15:40:00Z',
  },
  {
    'phone': '+22796123456',
    'country': 'NE',
    'operator_id': 301,
    'operator_name': 'إيرتل النيجر',
    'amount': '10000',
    'currency': 'XOF',
    'at': '2026-10-06T11:05:00Z',
  },
  {
    'phone': '+201012345678',
    'country': 'EG',
    'operator_id': 320,
    'operator_name': 'فودافون مصر',
    'amount': '50',
    'currency': 'EGP',
    'at': '2026-10-05T18:22:00Z',
  },
];
