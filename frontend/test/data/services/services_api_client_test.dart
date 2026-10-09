import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/models/service_kinds.dart';
import 'package:pointy_frontend/src/data/models/service_quote.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/data/services/services_api_client.dart';

/// What «كروت دفتر»' direct services put on the wire, and what they read back.
void main() {
  late List<http.Request> seen;

  ServicesApiClient client(
    Object? Function(http.Request request) answer, {
    int status = 200,
  }) {
    seen = [];
    return ServicesApiClient(
      PosApiSession(
        client: MockClient((request) async {
          seen.add(request);
          return http.Response(
            jsonEncode(answer(request)),
            status,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
        baseUrl: 'http://lan.test/api',
      ),
    );
  }

  group('detecting the network of a number', () {
    // A recipient's phone number must not sit in a URL: proxies, access logs
    // and browser history keep URLs. Detection is a POST with a JSON body.
    test(
      'is a POST with the number in the body, never in the address',
      () async {
        final api = client(
          (_) => {
            'detected': true,
            'reason': '',
            'operator': {
              'id': 289,
              'name': 'أورنج مالي',
              'name_en': 'Orange Mali',
              'mode': 'range',
              'amount_currency': 'XOF',
              'min': '1967',
              'max': '32800',
              'amounts': <Object?>[],
            },
            'phone': {
              'e164': '+22370123456',
              'national': '70123456',
              'country': 'ML',
            },
          },
        );

        final detection = await api.detect(country: 'ml', phone: '70123456');

        expect(seen, hasLength(1));
        final request = seen.single;
        expect(request.method, 'POST');
        expect(request.url.path, '/api/integrations/services/detect/');
        expect(
          request.url.hasQuery,
          isFalse,
          reason: 'nothing travels in the query',
        );
        expect(request.url.toString(), isNot(contains('70123456')));
        expect(jsonDecode(request.body), {
          'country': 'ML',
          'phone': '70123456',
        });
        expect(request.headers['content-type'], contains('application/json'));

        expect(detection.detected, isTrue);
        expect(detection.operator!.id, 289);
        expect(detection.operator!.name, 'أورنج مالي');
        expect(detection.phone!.e164, '+22370123456');
        expect(detection.phone!.country, 'ML');
      },
    );

    test(
      'a number the relay cannot place is an answer, with its reason',
      () async {
        final api = client(
          (_) => {
            'detected': false,
            'reason': 'not_detected',
            'operator': null,
            'phone': null,
          },
        );

        final detection = await api.detect(country: 'ML', phone: '70120000');

        expect(detection.detected, isFalse);
        expect(detection.reason, ServiceRefusalCode.notDetected);
        expect(detection.operator, isNull);
      },
    );
  });

  group('pricing', () {
    test('posts the request and reads the sealed quote', () async {
      final api = client(
        (_) => {
          'ok': true,
          'kind': 'airtime',
          'option_code': 'air:289:5000:XOF',
          'option_label': 'شحن أورنج مالي 5,000 فرنك أفريقي',
          'subscriber_ref': '+22370123456',
          'price': '96.50',
          'receive': {'amount': '5000', 'currency': 'XOF'},
          'approximate': false,
          'quote': 'sealed-token',
          'service_variant_id': 41,
          'exceeds_float': false,
        },
      );

      final outcome = await api.quote(
        const ServiceQuoteRequest.airtime(
          country: 'ML',
          operatorId: 289,
          phone: '70123456',
          amount: '5000',
          amountCurrency: 'XOF',
        ),
      );

      final request = seen.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/integrations/services/quote/');
      expect(jsonDecode(request.body), {
        'kind': 'airtime',
        'country': 'ML',
        'operator_id': 289,
        'phone': '70123456',
        'amount': '5000',
        'amount_currency': 'XOF',
      });
      final quote = outcome.quote!;
      expect(quote.kind, ServiceKind.airtime);
      expect(quote.optionCode, 'air:289:5000:XOF');
      expect(quote.subscriberRef, '+22370123456');
      expect(quote.price, 96.5);
      expect(quote.receiveAmount, '5000');
      expect(quote.receiveCurrency, 'XOF');
      expect(quote.serviceVariantId, 41);
      expect(quote.quote, 'sealed-token');
      expect(
        quote.cost,
        isNull,
        reason: 'the cost goes only to reporting roles',
      );
      expect(quote.isUsable, isTrue);
    });

    test(
      'a bill quote is a bill even when the server does not say so',
      () async {
        final api = client(
          (_) => {
            'ok': true,
            'option_code': 'bill:5:2000:NGN',
            'option_label': 'كهرباء لاغوس',
            'subscriber_ref': '45012345678',
            'price': '12.40',
            'receive': {'amount': '2000', 'currency': 'NGN'},
            'quote': 'sealed',
            'service_variant_id': 42,
            'exceeds_float': true,
            'cost': '11.90',
          },
        );

        final outcome = await api.quote(
          const ServiceQuoteRequest.bill(
            country: 'NG',
            billerId: 5,
            account: '45012345678',
            amount: '2000',
            amountCurrency: 'NGN',
          ),
        );

        expect(outcome.quote!.kind, ServiceKind.bill);
        expect(outcome.quote!.exceedsFloat, isTrue);
        expect(outcome.quote!.cost, 11.9);
      },
    );

    test('a refusal is an answer, with its limits', () async {
      final api = client(
        (_) => {
          'ok': false,
          'error_code': 'amount_out_of_range',
          'min': '1967',
          'max': '32800',
        },
      );

      final outcome = await api.quote(
        const ServiceQuoteRequest.airtime(
          country: 'ML',
          operatorId: 289,
          phone: '70123456',
          amount: '100',
          amountCurrency: 'XOF',
        ),
      );

      expect(outcome.isQuoted, isFalse);
      expect(outcome.refusal!.errorCode, ServiceRefusalCode.amountOutOfRange);
      expect(outcome.refusal!.min, 1967);
      expect(outcome.refusal!.max, 32800);
    });

    test('an invoice is sent for a biller that needs one', () async {
      final api = client(
        (_) => {'ok': false, 'error_code': 'invoice_required'},
      );

      final outcome = await api.quote(
        const ServiceQuoteRequest.bill(
          country: 'SN',
          billerId: 50,
          account: '123456',
          amount: '15000',
          amountCurrency: 'XOF',
          invoiceId: 'F-2291',
        ),
      );

      expect(
        jsonDecode(seen.single.body),
        containsPair('invoice_id', 'F-2291'),
      );
      expect(outcome.refusal!.errorCode, ServiceRefusalCode.invoiceRequired);
    });
  });

  group('reading', () {
    test(
      'the recent recipients come newest first from the recent list',
      () async {
        final api = client(
          (_) => {
            'kind': 'airtime',
            'recent': [
              {
                'phone': '+22370123456',
                'country': 'ML',
                'operator_id': 289,
                'operator_name': 'أورنج مالي',
                'amount': '5000',
                'currency': 'XOF',
                'at': '2026-10-07T09:30:00+00:00',
              },
              {'phone': '', 'country': 'ML'},
            ],
          },
        );

        final recents = await api.fetchRecent(ServiceKind.airtime);

        expect(seen.single.method, 'GET');
        expect(seen.single.url.path, '/api/integrations/services/recent/');
        expect(seen.single.url.queryParameters, {'kind': 'airtime'});
        expect(
          recents,
          hasLength(1),
          reason: 'a row with no number is no recipient',
        );
        expect(recents.single.phone, '+22370123456');
        expect(recents.single.operatorId, 289);
        expect(recents.single.operatorName, 'أورنج مالي');
        expect(recents.single.amount, '5000');
        expect(recents.single.currency, 'XOF');
        expect(recents.single.at, isNotNull);
      },
    );

    test('the directory and a country are read from their endpoints', () async {
      final api = client(
        (request) => request.url.path.endsWith('/directory/')
            ? {
                'available': true,
                'error_code': '',
                'version': 'v1',
                'balance': '120.00',
                'balance_at': '2026-10-07T09:30:00+00:00',
                'popular': ['NE', 'ML'],
                'countries': [
                  {
                    'code': 'ML',
                    'name': 'مالي',
                    'name_en': 'Mali',
                    'dial': ['223'],
                    'currency': 'XOF',
                    'currency_name': 'فرنك أفريقي',
                    'popular': 2,
                    'airtime': 2,
                    'bills': 1,
                  },
                ],
                'bill_types': [
                  {
                    'type': 'tv',
                    'countries': ['ML'],
                    'billers': 1,
                  },
                ],
                'unsupported': [
                  {'code': 'SD', 'name': 'السودان'},
                ],
              }
            : {
                'available': true,
                'error_code': '',
                'country': {
                  'code': 'ML',
                  'name': 'مالي',
                  'name_en': 'Mali',
                  'dial': ['223'],
                },
                'airtime': {
                  'operators': [
                    {
                      'id': 289,
                      'name': 'أورنج مالي',
                      'name_en': 'Orange Mali',
                      'mode': 'range',
                      'amount_currency': 'XOF',
                      'min': '1967',
                      'max': '32800',
                      'amounts': [
                        {
                          'amount': '5000',
                          'price': '96.50',
                          'exceeds_float': false,
                        },
                      ],
                    },
                  ],
                },
              },
      );

      final directory = await api.fetchDirectory();
      final detail = await api.fetchCountry('ml');

      expect(seen.map((request) => request.url.path), [
        '/api/integrations/services/directory/',
        '/api/integrations/services/countries/ML/',
      ]);
      expect(directory.available, isTrue);
      expect(directory.country('ML')!.airtimeCount, 2);
      expect(directory.country('ML')!.billCount, 1);
      expect(directory.billType(BillType.tv)!.countries, ['ML']);
      expect(directory.unsupported.single.code, 'SD');
      expect(detail.available, isTrue);
      expect(detail.operators.single.amounts.single.price, 96.5);
    });

    test(
      'a country the server answers "unavailable" for carries no networks',
      () async {
        final api = client(
          (_) => {
            'available': false,
            'error_code': 'switched_off',
            'country': null,
          },
        );

        final detail = await api.fetchCountry('ML');

        expect(detail.available, isFalse);
        expect(detail.errorCode, 'switched_off');
        expect(detail.operators, isEmpty);
        expect(detail.billers, isEmpty);
      },
    );
  });
}
