import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/service_kinds.dart';
import 'package:pointy_frontend/src/data/models/service_quote.dart';
import 'package:pointy_frontend/src/features/pos/view_models/service_quote_controller.dart';

/// The price of exactly what is on screen: asked again on every change, held
/// only for the request it answers.
void main() {
  ServiceQuoteRequest request(String amount, {String phone = '70123456'}) =>
      ServiceQuoteRequest.airtime(
        country: 'ML',
        operatorId: 289,
        phone: phone,
        amount: amount,
        amountCurrency: 'XOF',
      );

  ServiceQuote quoteFor(ServiceQuoteRequest request) => ServiceQuote(
    kind: ServiceKind.airtime,
    optionCode: 'air:289:${request.amount}:XOF',
    optionLabel: 'label',
    subscriberRef: '+22370123456',
    price: 96.5,
    receiveAmount: request.amount,
    receiveCurrency: 'XOF',
    quote: 'sealed-${request.amount}',
    serviceVariantId: 9301,
  );

  late List<ServiceQuoteRequest> asked;
  late Map<String, Completer<Result<ServiceQuoteOutcome>>> pending;

  ServiceQuoteController controller({
    Duration debounce = Duration.zero,
    bool hold = false,
  }) {
    asked = [];
    pending = {};
    return ServiceQuoteController(
      debounce: debounce,
      quote: (request) {
        asked.add(request);
        if (hold) {
          final completer = Completer<Result<ServiceQuoteOutcome>>();
          pending[request.amount] = completer;
          return completer.future;
        }
        return Future.value(Ok(ServiceQuoteOutcome.quoted(quoteFor(request))));
      },
    );
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 40));

  test('starts with nothing to price', () {
    final quotes = controller();
    expect(quotes.status, ServiceQuoteStatus.idle);
    expect(quotes.ready, isNull);
    expect(quotes.refusal, isNull);
    quotes.dispose();
  });

  test(
    'is loading from the moment it is asked, then ready with the price',
    () async {
      final quotes = controller();
      quotes.ask(request('5000'), immediate: true);
      expect(quotes.status, ServiceQuoteStatus.loading);
      expect(quotes.isLoading, isTrue);

      await settle();

      expect(quotes.status, ServiceQuoteStatus.ready);
      expect(quotes.ready!.optionCode, 'air:289:5000:XOF');
      expect(quotes.ready!.price, 96.5);
      expect(quotes.request!.amount, '5000');
      quotes.dispose();
    },
  );

  test('drops an answer to a request that was since replaced', () async {
    final quotes = controller(hold: true);
    quotes.ask(request('5000'), immediate: true);
    quotes.ask(request('10000'), immediate: true);

    // The newer one answers first, the older one limps in afterwards.
    pending['10000']!.complete(
      Ok(ServiceQuoteOutcome.quoted(quoteFor(request('10000')))),
    );
    await settle();
    pending['5000']!.complete(
      Ok(ServiceQuoteOutcome.quoted(quoteFor(request('5000')))),
    );
    await settle();

    expect(quotes.ready!.optionCode, 'air:289:10000:XOF');
    quotes.dispose();
  });

  test('does not ask twice for the same request', () async {
    final quotes = controller();
    quotes.ask(request('5000'), immediate: true);
    await settle();
    quotes.ask(request('5000'), immediate: true);
    await settle();

    expect(asked, hasLength(1));
    expect(quotes.status, ServiceQuoteStatus.ready);
    quotes.dispose();
  });

  test('asks at once what is still waiting out its pause', () async {
    final quotes = controller(debounce: const Duration(seconds: 5));
    quotes.ask(request('5000'));
    await settle();
    expect(asked, isEmpty, reason: 'still in the pause');

    quotes.flush();
    await settle();

    expect(asked, hasLength(1));
    expect(quotes.status, ServiceQuoteStatus.ready);
    quotes.flush();
    await settle();
    expect(asked, hasLength(1), reason: 'nothing was waiting the second time');
    quotes.dispose();
  });

  test('asks the same request again when forced to', () async {
    final quotes = controller();
    quotes.ask(request('5000'), immediate: true);
    await settle();
    quotes.ask(request('5000'), immediate: true, force: true);
    await settle();

    expect(asked, hasLength(2));
    expect(quotes.status, ServiceQuoteStatus.ready);
    quotes.dispose();
  });

  test(
    'waits for a pause in the typing before asking, and asks once',
    () async {
      final quotes = controller(debounce: const Duration(milliseconds: 30));
      quotes.ask(request('1'));
      quotes.ask(request('15'));
      quotes.ask(request('150'));
      expect(quotes.status, ServiceQuoteStatus.loading);
      expect(asked, isEmpty, reason: 'still typing');

      await Future<void>.delayed(const Duration(milliseconds: 90));

      expect(asked.map((r) => r.amount), ['150']);
      expect(quotes.ready!.quote, 'sealed-150');
      quotes.dispose();
    },
  );

  test('a refusal is an answer: its code, its limits', () async {
    final quotes = ServiceQuoteController(
      debounce: Duration.zero,
      quote: (_) async => const Ok(
        ServiceQuoteOutcome.refused(
          ServiceQuoteRefusal(
            errorCode: ServiceRefusalCode.amountOutOfRange,
            min: 1967,
            max: 32800,
          ),
        ),
      ),
    );
    quotes.ask(request('100'), immediate: true);
    await settle();

    expect(quotes.status, ServiceQuoteStatus.refused);
    expect(quotes.ready, isNull);
    expect(quotes.refusal!.errorCode, ServiceRefusalCode.amountOutOfRange);
    expect(quotes.refusal!.min, 1967);
    quotes.dispose();
  });

  test('a failure is told apart from a refusal, and can be retried', () async {
    var answer = false;
    final quotes = ServiceQuoteController(
      debounce: Duration.zero,
      quote: (request) async => answer
          ? Ok(ServiceQuoteOutcome.quoted(quoteFor(request)))
          : Error(Exception('offline')),
    );
    quotes.ask(request('5000'), immediate: true);
    await settle();
    expect(quotes.status, ServiceQuoteStatus.failed);

    answer = true;
    quotes.retry();
    expect(quotes.status, ServiceQuoteStatus.loading);
    await settle();

    expect(quotes.status, ServiceQuoteStatus.ready);
    quotes.dispose();
  });

  test('a failed request asked for again is asked again', () async {
    var calls = 0;
    final quotes = ServiceQuoteController(
      debounce: Duration.zero,
      quote: (request) async {
        calls++;
        return calls == 1
            ? Error(Exception('offline'))
            : Ok(ServiceQuoteOutcome.quoted(quoteFor(request)));
      },
    );
    quotes.ask(request('5000'), immediate: true);
    await settle();
    quotes.ask(request('5000'), immediate: true);
    await settle();

    expect(calls, 2);
    expect(quotes.status, ServiceQuoteStatus.ready);
    quotes.dispose();
  });

  test(
    'forgets the price, and any answer still on its way, when cleared',
    () async {
      final quotes = controller(hold: true);
      quotes.ask(request('5000'), immediate: true);
      quotes.clear();
      expect(quotes.status, ServiceQuoteStatus.idle);

      pending['5000']!.complete(
        Ok(ServiceQuoteOutcome.quoted(quoteFor(request('5000')))),
      );
      await settle();

      expect(quotes.status, ServiceQuoteStatus.idle);
      expect(quotes.ready, isNull);
      quotes.ask(null);
      expect(quotes.status, ServiceQuoteStatus.idle);
      quotes.dispose();
    },
  );

  group('a refusal that may pass', () {
    ServiceQuoteController refusing(
      String code,
      List<ServiceQuoteRequest> sent,
    ) => ServiceQuoteController(
      debounce: Duration.zero,
      quote: (request) {
        sent.add(request);
        return Future.value(
          Ok(ServiceQuoteOutcome.refused(ServiceQuoteRefusal(errorCode: code))),
        );
      },
    );

    test('is asked again when the same request comes back', () async {
      for (final code in [
        ServiceRefusalCode.unreachable,
        ServiceRefusalCode.serviceUnavailable,
        ServiceRefusalCode.unavailable,
      ]) {
        final sent = <ServiceQuoteRequest>[];
        final quotes = refusing(code, sent);
        quotes.ask(request('5000'), immediate: true);
        await settle();
        expect(quotes.status, ServiceQuoteStatus.refused, reason: code);

        // The cashier taps the same tile again.
        quotes.ask(request('5000'), immediate: true);
        await settle();

        expect(sent, hasLength(2), reason: code);
        quotes.dispose();
      }
    });

    test('can be retried', () async {
      final sent = <ServiceQuoteRequest>[];
      final quotes = refusing(ServiceRefusalCode.unreachable, sent);
      quotes.ask(request('5000'), immediate: true);
      await settle();

      quotes.retry();
      await settle();

      expect(sent, hasLength(2));
      quotes.dispose();
    });

    test('is not asked again when the answer is final', () async {
      for (final code in [
        ServiceRefusalCode.invalidPhone,
        ServiceRefusalCode.amountOutOfRange,
        ServiceRefusalCode.rateUnset,
      ]) {
        final sent = <ServiceQuoteRequest>[];
        final quotes = refusing(code, sent);
        quotes.ask(request('5000'), immediate: true);
        await settle();

        quotes.ask(request('5000'), immediate: true);
        await settle();

        expect(sent, hasLength(1), reason: code);
        quotes.dispose();
      }
    });
  });

  test('says nothing after it is disposed', () async {
    final quotes = controller(hold: true);
    var notified = 0;
    quotes.addListener(() => notified++);
    quotes.ask(request('5000'), immediate: true);
    final before = notified;
    quotes.dispose();
    pending['5000']!.complete(
      Ok(ServiceQuoteOutcome.quoted(quoteFor(request('5000')))),
    );
    await settle();

    expect(notified, before);
  });
}
