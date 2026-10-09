/// The countries «كروت دفتر» can send airtime to or pay bills in, as the shop
/// backend mirrors them from the relay's directory.
///
/// `GET /api/integrations/services/directory/`. It is the light half of the
/// directory — counts, dial codes and names, no operators and no flags — so the
/// country picker opens at once; one country's networks and providers come with
/// [ServiceCountryDetail] when it is picked. Parsed tolerantly: a malformed
/// country is skipped, never the list.
library;

import 'service_kinds.dart';
import 'tolerant_json.dart';

class ServicesDirectory {
  const ServicesDirectory({
    required this.available,
    this.errorCode = '',
    this.version = '',
    this.balance,
    this.popular = const [],
    this.countries = const [],
    this.billTypes = const [],
    this.unsupported = const [],
    this.testMode = false,
  });

  /// What a server with nothing to say amounts to.
  static const empty = ServicesDirectory(available: false);

  factory ServicesDirectory.fromJson(Map<String, Object?> json) {
    final countries = jsonList(
      json['countries'],
      ServiceCountry.fromJson,
    ).where((country) => country.code.isNotEmpty).toList(growable: false);
    final ranked = jsonTexts(json['popular']).map((code) => code.toUpperCase());
    return ServicesDirectory(
      // Absent is not "on sale" — unless there are countries to show.
      available:
          json['available'] == true ||
          (json['available'] == null && countries.isNotEmpty),
      errorCode: jsonText(json['error_code']),
      version: jsonText(json['version']),
      balance: jsonDouble(json['balance']),
      popular: ranked.isNotEmpty
          ? ranked.toList(growable: false)
          : _byRank(countries),
      countries: countries,
      billTypes: jsonList(
        json['bill_types'],
        ServiceBillTypeSummary.fromJson,
      ).where((type) => type.countries.isNotEmpty).toList(growable: false),
      unsupported: jsonList(
        json['unsupported'],
        UnsupportedServiceCountry.fromJson,
      ).where((country) => country.code.isNotEmpty).toList(growable: false),
      // Absent is not "test": only an explicit true puts the till in it.
      testMode: json['test_mode'] == true,
    );
  }

  /// The shop can use the services right now. False when the provider is not
  /// switched on, or was switched off for every shop ([errorCode] says which).
  final bool available;
  final String errorCode;

  /// Changes whenever the relay's directory does.
  final String version;

  /// The voucher balance the services are paid from, as last read.
  final double? balance;

  /// Country codes the company wants first, in its order.
  final List<String> popular;
  final List<ServiceCountry> countries;

  /// For each type of bill, the countries that have one.
  final List<ServiceBillTypeSummary> billTypes;

  /// Countries the services do not reach, so the picker can say so instead of
  /// answering a search for «السودان» with "no results".
  final List<UnsupportedServiceCountry> unsupported;

  /// The relay is buying from its test supplier: nothing sent is real and
  /// nothing paid is paid.
  final bool testMode;

  bool get hasCountries => countries.isNotEmpty;

  /// The short Arabic name the directory gives [code] — the one the countries
  /// that use that money give it (`XOF` → «فرنك أفريقي») — or null when no
  /// country does, or the name it gives is not Arabic.
  String? currencyName(String code) {
    final wanted = code.trim().toUpperCase();
    if (wanted.isEmpty) {
      return null;
    }
    for (final country in countries) {
      final name = country.currencyName.trim();
      if (country.currency == wanted &&
          name.isNotEmpty &&
          !RegExp('[A-Za-z]').hasMatch(name)) {
        return name;
      }
    }
    return null;
  }

  ServiceCountry? country(String code) {
    final wanted = code.trim().toUpperCase();
    for (final country in countries) {
      if (country.code == wanted) {
        return country;
      }
    }
    return null;
  }

  ServiceBillTypeSummary? billType(BillType type) {
    for (final summary in billTypes) {
      if (summary.type == type) {
        return summary;
      }
    }
    return null;
  }

  /// The countries airtime can be sent to, in the directory's order.
  List<ServiceCountry> get airtimeCountries => [
    for (final country in countries)
      if (country.airtimeCount > 0) country,
  ];

  /// The countries that have a provider of [type]. A server that lists no
  /// per-type summary falls back to the countries that have any biller.
  List<ServiceCountry> billCountries(BillType type) {
    final summary = billType(type);
    if (summary == null) {
      return billTypes.isEmpty
          ? [
              for (final country in countries)
                if (country.billCount > 0) country,
            ]
          : const [];
    }
    final wanted = summary.countries.toSet();
    return [
      for (final country in countries)
        if (wanted.contains(country.code)) country,
    ];
  }

  static List<String> _byRank(List<ServiceCountry> countries) {
    final ranked = [
      for (final country in countries)
        if (country.popularRank > 0) country,
    ]..sort((a, b) => a.popularRank.compareTo(b.popularRank));
    return [for (final country in ranked) country.code];
  }
}

/// One country in the directory.
class ServiceCountry {
  const ServiceCountry({
    required this.code,
    this.name = '',
    this.nameEn = '',
    this.dial = const [],
    this.currency = '',
    this.currencyName = '',
    this.popularRank = 0,
    this.airtimeCount = 0,
    this.billCount = 0,
  });

  factory ServiceCountry.fromJson(Map<String, Object?> json) {
    return ServiceCountry(
      code: jsonText(json['code']).toUpperCase(),
      name: jsonText(json['name']),
      nameEn: jsonText(json['name_en']),
      dial: [
        for (final entry in jsonTexts(
          json['dial'] is List ? json['dial'] : [json['dial']],
        ))
          if (entry.replaceAll(RegExp(r'\D'), '').isNotEmpty)
            entry.replaceAll(RegExp(r'\D'), ''),
      ],
      currency: jsonText(json['currency']).toUpperCase(),
      currencyName: jsonText(json['currency_name']),
      popularRank: jsonInt(json['popular']),
      airtimeCount: _count(json['airtime'], 'operators'),
      billCount: _count(json['bills'], 'billers'),
    );
  }

  /// ISO 3166 alpha-2.
  final String code;

  /// Arabic.
  final String name;

  /// Search only: never shown.
  final String nameEn;

  /// Calling codes, digits only, without `+`: `["223"]`, or several for a
  /// country that has them (`["1809", "1829", "1849"]`).
  final List<String> dial;

  /// ISO 4217, of the amounts this country's operators take.
  final String currency;

  /// The everyday short Arabic name next to an amount: «فرنك أفريقي».
  final String currencyName;

  /// 1-based place in the company's popular list; 0 when not in it.
  final int popularRank;
  final int airtimeCount;
  final int billCount;

  bool get isPopular => popularRank > 0;

  String get label => serviceDisplayName(name, fallback: code);

  /// The first calling code, or empty.
  String get primaryDial => dial.isEmpty ? '' : dial.first;

  /// The currency as a cashier says it next to an amount.
  String get currencyLabel => currencyName.isNotEmpty ? currencyName : currency;

  static int _count(Object? raw, String listKey) {
    if (raw is num) return raw.toInt();
    final map = jsonMap(raw);
    if (map == null) {
      return int.tryParse(raw?.toString() ?? '') ?? 0;
    }
    final list = map[listKey];
    return list is List ? list.length : jsonInt(map['count']);
  }
}

/// How many countries and providers one type of bill has.
class ServiceBillTypeSummary {
  const ServiceBillTypeSummary({
    required this.type,
    this.countries = const [],
    this.billers = 0,
    this.counts = const {},
  });

  factory ServiceBillTypeSummary.fromJson(Map<String, Object?> json) {
    final counts = jsonMap(json['counts']);
    return ServiceBillTypeSummary(
      type: billTypeFromJson(json['type']),
      countries: [
        for (final code in jsonTexts(json['countries'])) code.toUpperCase(),
      ],
      billers: jsonInt(json['billers']),
      counts: {
        if (counts != null)
          for (final entry in counts.entries)
            if (jsonInt(entry.value) > 0)
              entry.key.toUpperCase(): jsonInt(entry.value),
      },
    );
  }

  final BillType type;
  final List<String> countries;
  final int billers;

  /// How many providers of this type each country has, by country code — when
  /// the server says (optional: without it the till reads each country).
  final Map<String, int> counts;
}

/// A country the services do not serve (yet).
class UnsupportedServiceCountry {
  const UnsupportedServiceCountry({
    required this.code,
    this.name = '',
    this.nameEn = '',
  });

  factory UnsupportedServiceCountry.fromJson(Map<String, Object?> json) {
    return UnsupportedServiceCountry(
      code: jsonText(json['code']).toUpperCase(),
      name: jsonText(json['name']),
      nameEn: jsonText(json['name_en']),
    );
  }

  final String code;
  final String name;
  final String nameEn;

  String get label => serviceDisplayName(name, fallback: code);
}
