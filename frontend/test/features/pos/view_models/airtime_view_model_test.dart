import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/services_fake_repository.dart';
import 'package:pointy_frontend/src/data/models/service_quote.dart';
import 'package:pointy_frontend/src/features/pos/view_models/airtime_view_model.dart';
import 'package:pointy_frontend/src/features/pos/view_models/service_blocker.dart';
import 'package:pointy_frontend/src/features/pos/view_models/service_quote_controller.dart';
import 'package:pointy_frontend/src/features/pos/view_models/services_catalog.dart';

/// The airtime form from the cashier's side: country, number, network,
/// amount — and the exact reason it cannot be added yet.
void main() {
  late PreviewServicesRepository repository;
  late ServicesCatalog catalog;
  late AirtimeViewModel airtime;

  setUp(() async {
    repository = PreviewServicesRepository();
    catalog = ServicesCatalog(repository: repository);
    airtime = AirtimeViewModel(
      catalog: catalog,
      repository: repository,
      detectDebounce: const Duration(milliseconds: 20),
      quoteDebounce: const Duration(milliseconds: 20),
    );
    await catalog.ensureLoaded();
  });

  tearDown(() {
    airtime.dispose();
    catalog.dispose();
  });

  Future<void> settle([int milliseconds = 120]) =>
      Future<void>.delayed(Duration(milliseconds: milliseconds));

  Future<void> pickMali() async {
    airtime.selectCountry(catalog.directory!.country('ML')!);
    await catalog.loadDetail('ML');
    await settle(10);
  }

  group('the country', () {
    test(
      'is read when it is picked, and its networks are then at hand',
      () async {
        expect(airtime.blocker?.reason, ServiceBlockReason.noCountry);

        airtime.selectCountry(catalog.directory!.country('ML')!);
        expect(airtime.country!.code, 'ML');
        await catalog.loadDetail('ML');
        await settle(10);

        expect(airtime.detail!.operators, hasLength(3));
        expect(airtime.networks.map((o) => o.id), [289, 290, 291]);
        expect(airtime.blocker?.reason, ServiceBlockReason.noNumber);
        expect(repository.countryReads['ML'], 1);
      },
    );

    test('a country with one network needs no question', () async {
      final single = catalog.directory!.country('MZ')!;
      airtime.selectCountry(single);
      await catalog.loadDetail('MZ');
      await settle(10);

      expect(airtime.detail!.operators, hasLength(1));
      expect(airtime.operator!.id, airtime.detail!.operators.single.id);
      expect(airtime.isManualOperator, isFalse);
    });

    test(
      'a country that cannot be read says so, and can be tried again',
      () async {
        repository.failCountries.add('ML');
        airtime.selectCountry(catalog.directory!.country('ML')!);
        await catalog.loadDetail('ML');
        await settle(10);

        expect(airtime.hasCountryError, isTrue);
        expect(airtime.blocker?.reason, ServiceBlockReason.countryFailed);

        repository.failCountries.clear();
        airtime.retryCountry();
        await settle();

        expect(airtime.hasCountryError, isFalse);
        expect(airtime.detail, isNotNull);
      },
    );

    test(
      'another country forgets the network and the amount, not the number',
      () async {
        await pickMali();
        airtime.onPhoneInput('70123456');
        await settle();
        airtime.selectAmount(airtime.operator!.amountFor('5000')!);
        expect(airtime.amount, '5000');

        airtime.selectCountry(catalog.directory!.country('NE')!);
        await settle(10);

        expect(airtime.operator, isNull);
        expect(airtime.amount, isNull);
        expect(airtime.national, '70123456');
        expect(airtime.quote.status, ServiceQuoteStatus.idle);
      },
    );
  });

  group('the number', () {
    test(
      'is asked about only once it has a few digits, after a pause',
      () async {
        await pickMali();
        airtime.onPhoneInput('7012');
        await settle();
        expect(repository.detections, isEmpty);

        airtime.onPhoneInput('70123456');
        expect(airtime.detectionStatus, AirtimeDetectionStatus.idle);
        await settle();

        expect(repository.detections, hasLength(1));
        expect(repository.detections.single.country, 'ML');
        expect(repository.detections.single.phone, '70123456');
      },
    );

    test(
      'keeps what was typed — a leading zero too — and drops separators',
      () async {
        await pickMali();
        airtime.onPhoneInput('070 12-34 56');
        expect(airtime.national, '070123456');
        expect(airtime.displayNumber, '+223 07 01 23 45 6');
      },
    );

    test(
      'a number that is typing is asked about once, for the last digits',
      () async {
        await pickMali();
        for (final typed in [
          '70',
          '701',
          '7012',
          '70123',
          '701234',
          '7012345',
          '70123456',
        ]) {
          airtime.onPhoneInput(typed);
          await settle(2);
        }
        await settle();

        expect(repository.detections.map((d) => d.phone), ['70123456']);
      },
    );
  });

  group('detecting the network', () {
    test('selects the network the relay found, and says so', () async {
      await pickMali();
      airtime.onPhoneInput('70123456');
      await settle();

      expect(airtime.detectionStatus, AirtimeDetectionStatus.detected);
      expect(airtime.operator!.id, 289);
      expect(airtime.detectedOperator!.id, 289);
      expect(airtime.isManualOperator, isFalse);
      expect(airtime.blocker?.reason, ServiceBlockReason.noAmount);
    });

    test('does not choose for a cashier who already chose', () async {
      await pickMali();
      airtime.selectOperator(airtime.detail!.operator(290)!);
      airtime.onPhoneInput('70123456');
      await settle();

      expect(airtime.operator!.id, 290);
      expect(airtime.detectedOperator!.id, 289);
      expect(airtime.detectionDisagrees, isTrue);

      airtime.useDetectedOperator();
      expect(airtime.operator!.id, 289);
      expect(airtime.isManualOperator, isFalse);
      expect(airtime.detectionDisagrees, isFalse);
    });

    test('when it cannot place the number, the cashier chooses', () async {
      await pickMali();
      airtime.onPhoneInput('70120000');
      await settle();

      expect(airtime.detectionStatus, AirtimeDetectionStatus.notDetected);
      expect(airtime.operator, isNull);
      expect(airtime.blocker?.reason, ServiceBlockReason.noNetwork);

      airtime.selectOperator(airtime.networks.first);
      expect(airtime.operator, isNotNull);
      expect(airtime.blocker?.reason, ServiceBlockReason.noAmount);
    });

    test('an unavailable relay is told apart, and never blocks', () async {
      await pickMali();
      airtime.onPhoneInput('70129999');
      await settle();

      expect(airtime.detectionStatus, AirtimeDetectionStatus.unavailable);
      airtime.selectOperator(airtime.networks.first);
      expect(airtime.operator, isNotNull);
    });

    test('an error is a failure to ask, not a verdict on the number', () async {
      repository.failDetect = true;
      await pickMali();
      airtime.onPhoneInput('70123456');
      await settle();

      expect(airtime.detectionStatus, AirtimeDetectionStatus.failed);
      airtime.selectOperator(airtime.networks.first);
      airtime.selectAmount(airtime.operator!.amounts.first);
      await settle();
      expect(airtime.canAdd, isTrue);
    });

    test('drops an answer about a number that was since changed', () async {
      repository.detectDelay = const Duration(milliseconds: 80);
      await pickMali();
      airtime.onPhoneInput('70123456');
      await settle(60);
      expect(airtime.detectionStatus, AirtimeDetectionStatus.detecting);

      // The cashier fixes the number while the relay is thinking.
      airtime.onPhoneInput('60123456');
      expect(airtime.detectionStatus, AirtimeDetectionStatus.idle);
      await settle(80);
      // The first answer (Orange, for a 7) arrived and was ignored; the
      // second (Malitel, for a 6) is the one that counts.
      await settle(200);

      expect(airtime.detectedOperator!.id, 290);
      expect(airtime.operator!.id, 290);
    });
  });

  group('pasting a number', () {
    test(
      'with its country code picks the country and keeps the digits',
      () async {
        airtime.onPhoneInput('+22370123456', pasted: true);
        await settle();

        expect(airtime.country!.code, 'ML');
        expect(airtime.national, '70123456');
        expect(airtime.phoneRevision, greaterThan(0));
        expect(airtime.operator!.id, 289, reason: 'detected after the paste');
      },
    );

    test('switches the country when it is another one', () async {
      await pickMali();
      airtime.onPhoneInput('+2349031234567', pasted: true);
      await settle(60);

      expect(airtime.country!.code, 'NG');
      expect(airtime.national, '9031234567');
    });

    test(
      'typed in full does the same, but waits until it is a whole number',
      () async {
        airtime.onPhoneInput('+2237');
        expect(airtime.country, isNull);
        expect(airtime.isInternationalPending, isTrue);
        expect(airtime.blocker?.reason, ServiceBlockReason.noCountry);

        airtime.onPhoneInput('+22370123456');
        await settle(60);

        expect(airtime.country!.code, 'ML');
        expect(airtime.national, '70123456');
        expect(airtime.isInternationalPending, isFalse);
      },
    );

    test(
      'with a calling code nobody has says so and guesses nothing',
      () async {
        airtime.onPhoneInput('+999123456789', pasted: true);

        expect(airtime.hasUnknownPrefix, isTrue);
        expect(airtime.country, isNull);
        expect(airtime.national, isEmpty);
      },
    );

    test('00 does what + does', () async {
      airtime.onPhoneInput('0022770123456', pasted: true);
      await settle(60);

      expect(airtime.country!.code, 'NE');
      expect(airtime.national, '70123456');
    });
  });

  group('a number pasted with a calling code several countries share', () {
    test('is offered to the cashier, never decided for them', () async {
      airtime.onPhoneInput('+1 202 555 0123', pasted: true);

      expect(airtime.country, isNull, reason: 'not the first of them');
      expect(airtime.dialChoices.map((country) => country.code).toSet(), {
        'US',
        'CA',
      });
      expect(airtime.sharedDial, '1');
      expect(airtime.hasUnknownPrefix, isFalse);
      expect(airtime.blocker!.reason, ServiceBlockReason.chooseDialCountry);
      expect(airtime.canAdd, isFalse);
    });

    test(
      'is not decided by a country that is not one of them either',
      () async {
        await pickMali();

        airtime.onPhoneInput('+1 202 555 0123', pasted: true);

        expect(airtime.country!.code, 'ML', reason: 'left as it was');
        expect(airtime.dialChoices, hasLength(2));
        expect(airtime.blocker!.reason, ServiceBlockReason.chooseDialCountry);
      },
    );

    test(
      'is settled by the country already picked when it is one of them',
      () async {
        airtime.selectCountry(catalog.directory!.country('CA')!);
        await catalog.loadDetail('CA');

        airtime.onPhoneInput('+1 202 555 0123', pasted: true);

        expect(airtime.country!.code, 'CA');
        expect(airtime.dialChoices, isEmpty);
        expect(airtime.national, '2025550123');
      },
    );

    test(
      'choosing one takes that country and the digits after the code',
      () async {
        airtime.onPhoneInput('+1 202 555 0123', pasted: true);
        final revision = airtime.phoneRevision;

        airtime.chooseDialCountry(catalog.directory!.country('CA')!);
        await settle(20);

        expect(airtime.country!.code, 'CA');
        expect(airtime.national, '2025550123');
        expect(airtime.dialChoices, isEmpty);
        expect(airtime.phoneRevision, greaterThan(revision));
        expect(
          airtime.blocker!.reason,
          isNot(ServiceBlockReason.chooseDialCountry),
        );
      },
    );

    test('typing on forgets the question', () async {
      airtime.onPhoneInput('+1 202 555 0123', pasted: true);

      airtime.onPhoneInput('70123456');

      expect(airtime.dialChoices, isEmpty);
      expect(airtime.sharedDial, isNull);
    });

    test('a country picked from the list answers it too', () async {
      airtime.onPhoneInput('+1 202 555 0123', pasted: true);

      airtime.selectCountry(catalog.directory!.country('US')!);

      expect(airtime.dialChoices, isEmpty);
      expect(airtime.country!.code, 'US');
      expect(airtime.national, '2025550123');
    });

    test('a reset forgets it', () async {
      airtime.onPhoneInput('+1 202 555 0123', pasted: true);

      airtime.reset();

      expect(airtime.dialChoices, isEmpty);
      expect(airtime.blocker!.reason, ServiceBlockReason.noCountry);
    });
  });

  group('a number copied from a chat', () {
    test(
      'keeps its plus behind direction marks and picks the country',
      () async {
        for (final raw in const [
          '\u202A+223 70 12 34 56\u202C',
          '(+223) 70 12 34 56',
          '\u200E+223\u00A070\u00A012\u00A034\u00A056',
        ]) {
          airtime.reset();
          airtime.onPhoneInput(raw, pasted: true);
          await settle(60);

          expect(airtime.country?.code, 'ML', reason: raw);
          expect(airtime.national, '70123456', reason: raw);
        }
      },
    );
  });

  group('digits that begin with the country\'s own calling code', () {
    test('are never cut for the cashier, but are questioned', () async {
      await pickMali();

      airtime.onPhoneInput('22370123456');

      expect(airtime.national, '22370123456');
      final fix = airtime.dialCodeCorrection!;
      expect(fix.dial, '223');
      expect(fix.national, '70123456');
    });

    test('one tap puts the number right, in the field too', () async {
      await pickMali();
      airtime.onPhoneInput('22370123456');
      final revision = airtime.phoneRevision;

      airtime.applyDialCodeCorrection();

      expect(airtime.national, '70123456');
      expect(airtime.phoneRevision, greaterThan(revision));
      expect(airtime.dialCodeCorrection, isNull);
      await settle();
      expect(repository.detections.last.phone, '70123456');
    });

    test(
      'a number too short to be a code and a number is left alone',
      () async {
        await pickMali();

        airtime.onPhoneInput('223701234');

        expect(airtime.dialCodeCorrection, isNull);
      },
    );

    test('another country\'s code is not this country\'s', () async {
      await pickMali();

      airtime.onPhoneInput('23470123456');

      expect(airtime.dialCodeCorrection, isNull);
    });

    test(
      'a number the relay placed as it was typed is not questioned',
      () async {
        // India's numbers may start 91 on their own: when the relay reads the
        // digits as the national number they are, nothing is wrong.
        final india = catalog.directory!.country('IN');
        if (india == null) {
          return;
        }
        airtime.selectCountry(india);
        await catalog.loadDetail('IN');
        await settle(10);

        airtime.onPhoneInput('9123456789');
        expect(
          airtime.dialCodeCorrection,
          isNotNull,
          reason: 'until the relay says',
        );
      },
    );

    test('is gone when the number changes', () async {
      await pickMali();
      airtime.onPhoneInput('22370123456');
      expect(airtime.dialCodeCorrection, isNotNull);

      airtime.onPhoneInput('2237012');

      expect(airtime.dialCodeCorrection, isNull);
    });
  });

  group('what the customer is read back', () {
    Future<void> priced() async {
      await pickMali();
      airtime.onPhoneInput('70123456');
      await settle();
      airtime.selectAmount(airtime.operator!.amountFor('5000')!);
      await settle(40);
    }

    test(
      'is the number as the server normalised it, grouped by its code',
      () async {
        await priced();

        expect(airtime.readyQuote!.subscriberRef, '+22370123456');
        expect(airtime.serverNumber, '+223 70 12 34 56');
        expect(airtime.detectedPhone!.e164, '+22370123456');
        expect(airtime.canAdd, isTrue);
      },
    );

    test('is nothing until the server has priced it', () async {
      await pickMali();
      airtime.onPhoneInput('70123456');
      await settle();

      expect(airtime.serverNumber, isNull);
    });

    test('a number the relay says is not a number cannot be added', () async {
      await pickMali();
      airtime.onPhoneInput('70128888');
      await settle();
      expect(airtime.detectionStatus, AirtimeDetectionStatus.invalidNumber);
      airtime.selectOperator(airtime.detail!.operator(289)!);
      airtime.selectAmount(airtime.operator!.amountFor('5000')!);
      await settle(40);

      expect(airtime.readyQuote, isNotNull, reason: 'the server priced it');
      expect(airtime.blocker?.reason, ServiceBlockReason.numberInvalid);
      expect(airtime.canAdd, isFalse);
    });

    test('is the first thing said, before a network or an amount', () async {
      await pickMali();
      airtime.onPhoneInput('70128888');
      await settle();

      expect(airtime.blocker?.reason, ServiceBlockReason.numberInvalid);
    });

    test(
      'a quote for another number than the relay placed cannot be added',
      () async {
        await pickMali();
        airtime.onPhoneInput('70123456');
        await settle();
        repository.quoteSubscriberRef = '+22322370123456';
        airtime.selectAmount(airtime.operator!.amountFor('5000')!);
        await settle(40);

        expect(airtime.serverNumber, '+223 22 37 01 23 45 6');
        expect(airtime.blocker?.reason, ServiceBlockReason.numberMismatch);
        expect(airtime.canAdd, isFalse);
      },
    );

    test('a relay that could not be asked does not stop the sale', () async {
      repository.failDetect = true;
      await pickMali();
      airtime.onPhoneInput('70123456');
      await settle();
      airtime.selectOperator(airtime.detail!.operator(289)!);
      airtime.selectAmount(airtime.operator!.amountFor('5000')!);
      await settle(40);

      expect(airtime.detectedPhone, isNull);
      expect(airtime.canAdd, isTrue);
    });

    test(
      'a changed number forgets what the relay said about the last one',
      () async {
        await priced();
        expect(airtime.detectedPhone, isNotNull);

        airtime.onPhoneInput('7012345');

        expect(airtime.detectedPhone, isNull);
        expect(airtime.serverNumber, isNull);
      },
    );
  });

  group('the amount', () {
    Future<void> readyToChoose() async {
      await pickMali();
      airtime.onPhoneInput('70123456');
      await settle();
    }

    test('a tile is priced at once, and the line is ready to add', () async {
      await readyToChoose();
      airtime.selectAmount(airtime.operator!.amountFor('5000')!);
      expect(airtime.blocker?.reason, ServiceBlockReason.quoting);
      await settle(40);

      expect(airtime.canAdd, isTrue);
      final quote = airtime.readyQuote!;
      expect(quote.optionCode, 'air:289:5000:XOF');
      expect(quote.price, 96.5);
      expect(quote.subscriberRef, '+22370123456');
      expect(repository.quotes.last.toJson(), {
        'kind': 'airtime',
        'country': 'ML',
        'operator_id': 289,
        'phone': '70123456',
        'amount': '5000',
        'amount_currency': 'XOF',
      });
    });

    test('an amount of the cashier\'s own is priced after a pause', () async {
      await readyToChoose();
      airtime.openCustomAmount();
      expect(airtime.isCustomOpen, isTrue);
      expect(airtime.blocker?.reason, ServiceBlockReason.noAmount);

      airtime.setCustomAmount('3,500');
      expect(
        airtime.amount,
        '3500',
        reason: 'a comma before three digits groups',
      );
      await settle();

      expect(airtime.canAdd, isTrue);
      expect(airtime.readyQuote!.optionCode, 'air:289:3500:XOF');
      expect(airtime.readyQuote!.receiveAmount, '3500');
    });

    test('Arabic digits are digits', () async {
      await readyToChoose();
      airtime.setCustomAmount('٥٠٠٠');

      expect(airtime.amount, '5000');
    });

    test(
      'an amount outside the network\'s range is refused before it is sent',
      () async {
        await readyToChoose();
        airtime.openCustomAmount();
        final asked = repository.quotes.length;

        airtime.setCustomAmount('100');
        expect(airtime.customProblem, ServiceAmountProblem.belowMin);
        expect(airtime.amount, isNull);
        expect(airtime.blocker!.reason, ServiceBlockReason.amountBelowMin);
        expect(airtime.blocker!.min, 1967);

        airtime.setCustomAmount('99999');
        expect(airtime.customProblem, ServiceAmountProblem.aboveMax);
        expect(airtime.blocker!.reason, ServiceBlockReason.amountAboveMax);
        expect(airtime.blocker!.max, 32800);

        airtime.setCustomAmount('abc');
        expect(airtime.customProblem, ServiceAmountProblem.invalid);
        await settle();
        expect(repository.quotes.length, asked, reason: 'nothing was sent');
      },
    );

    test('a fixed network offers its own amounts and no custom one', () async {
      airtime.selectCountry(catalog.directory!.country('EG')!);
      await catalog.loadDetail('EG');
      airtime.onPhoneInput('01012345678');
      await settle();

      expect(airtime.operator!.id, 320);
      expect(airtime.operator!.isFixed, isTrue);
      expect(airtime.operator!.takesCustomAmount, isFalse);
      airtime.selectAmount(airtime.operator!.amountFor('20')!);
      await settle(40);
      expect(airtime.readyQuote!.optionCode, 'air:320:20:EGP');
    });

    test('an approximate network says what arrives, roughly', () async {
      airtime.selectCountry(catalog.directory!.country('GH')!);
      await catalog.loadDetail('GH');
      airtime.selectOperator(airtime.detail!.operator(342)!);
      airtime.onPhoneInput('244123456');
      airtime.selectAmount(airtime.operator!.amounts[1]);
      await settle(60);

      final quote = airtime.readyQuote!;
      expect(quote.approximate, isTrue);
      expect(quote.receiveCurrency, 'GHS');
      expect(quote.receiveAmount, '24');
      expect(repository.quotes.last.amountCurrency, 'USD');
    });

    test(
      'a change of network keeps the amount when the new one takes it too',
      () async {
        await readyToChoose();
        airtime.selectAmount(airtime.operator!.amountFor('5000')!);
        await settle(40);

        airtime.selectOperator(airtime.detail!.operator(290)!);
        expect(airtime.amount, '5000', reason: 'Malitel sells 5,000 too');
        await settle(40);
        expect(airtime.readyQuote!.optionCode, 'air:290:5000:XOF');

        airtime.selectOperator(airtime.detail!.operator(289)!);
        airtime.selectAmount(airtime.operator!.amountFor('15000')!);
        airtime.selectOperator(airtime.detail!.operator(290)!);
        expect(airtime.amount, isNull, reason: 'Malitel has no 15,000');
        expect(airtime.blocker!.reason, ServiceBlockReason.noAmount);
      },
    );
  });

  group('why it cannot be added', () {
    test(
      'is always the first thing still missing, in the order of the steps',
      () async {
        expect(airtime.blocker!.reason, ServiceBlockReason.noCountry);
        await pickMali();
        expect(airtime.blocker!.reason, ServiceBlockReason.noNumber);
        airtime.onPhoneInput('7012');
        expect(airtime.blocker!.reason, ServiceBlockReason.numberTooShort);
        airtime.onPhoneInput('70123456');
        expect(airtime.blocker!.reason, ServiceBlockReason.noNetwork);
        await settle();
        expect(airtime.blocker!.reason, ServiceBlockReason.noAmount);
        airtime.selectAmount(airtime.operator!.amounts.first);
        expect(airtime.blocker!.isWaiting, isTrue);
        await settle(40);
        expect(airtime.blocker, isNull);
      },
    );

    test('a number with too many digits is too long, not incomplete', () async {
      await pickMali();
      airtime.onPhoneInput('70123456789012');
      expect(airtime.blocker!.reason, ServiceBlockReason.numberTooLong);

      airtime.onPhoneInput('7012345678901');
      expect(
        airtime.blocker!.reason,
        isNot(
          anyOf(
            ServiceBlockReason.numberTooLong,
            ServiceBlockReason.numberTooShort,
          ),
        ),
        reason: '13 digits with a 3-digit code still fit a number',
      );

      airtime.onPhoneInput('70123');
      expect(airtime.blocker!.reason, ServiceBlockReason.numberTooShort);
    });

    test('carries the server\'s refusal, with its code and limits', () async {
      repository.refuseQuote = ServiceRefusalCode.invalidPhone;
      await pickMali();
      airtime.onPhoneInput('70123456');
      await settle();
      airtime.selectAmount(airtime.operator!.amounts.first);
      await settle(40);

      expect(airtime.blocker!.reason, ServiceBlockReason.quoteRefused);
      expect(airtime.blocker!.code, ServiceRefusalCode.invalidPhone);
      expect(airtime.canAdd, isFalse);
    });

    test('says a price could not be read, and can ask again', () async {
      repository.failQuote = true;
      await pickMali();
      airtime.onPhoneInput('70123456');
      await settle();
      airtime.selectAmount(airtime.operator!.amounts.first);
      await settle(40);
      expect(airtime.blocker!.reason, ServiceBlockReason.quoteFailed);

      repository.failQuote = false;
      airtime.quote.retry();
      await settle(40);
      expect(airtime.canAdd, isTrue);
    });
  });

  group('recent numbers', () {
    test(
      'are read once, and one tap fills country, number, network and amount',
      () async {
        await airtime.loadRecents();
        await airtime.loadRecents();
        expect(repository.recentReads, 1);
        expect(airtime.recents, hasLength(4));

        airtime.useRecent(airtime.recents.first);
        await settle();

        expect(airtime.country!.code, 'ML');
        expect(airtime.national, '70123456');
        expect(airtime.operator!.id, 289);
        expect(airtime.amount, '5000');
        expect(airtime.canAdd, isTrue);
      },
    );

    test('in another country wait for it to be read', () async {
      await airtime.loadRecents();
      final nigeria = airtime.recents.firstWhere((r) => r.country == 'NG');

      airtime.useRecent(nigeria);
      await settle();

      expect(airtime.country!.code, 'NG');
      expect(airtime.national, '9031234567');
      expect(airtime.operator!.id, 310);
      expect(airtime.amount, '2000');
    });

    test('are empty for a shop that has sold none', () async {
      repository.noRecents = true;
      await airtime.loadRecents(force: true);

      expect(airtime.recents, isEmpty);
    });
  });

  group('after the line is in the cart', () {
    test('the form returns to the number, keeping the country', () async {
      await pickMali();
      airtime.onPhoneInput('70123456');
      await settle();
      airtime.selectAmount(airtime.operator!.amountFor('5000')!);
      await settle(40);
      await airtime.loadRecents();
      final revision = airtime.phoneRevision;
      final focus = airtime.focusRevision;

      airtime.afterAdded();

      expect(airtime.country!.code, 'ML');
      expect(airtime.national, isEmpty);
      expect(airtime.operator, isNull);
      expect(airtime.amount, isNull);
      expect(airtime.quote.status, ServiceQuoteStatus.idle);
      expect(airtime.blocker!.reason, ServiceBlockReason.noNumber);
      expect(airtime.phoneRevision, greaterThan(revision));
      expect(airtime.focusRevision, greaterThan(focus));
      // The recipient is first among the recents, once.
      expect(airtime.recents.first.phone, '+22370123456');
      expect(
        airtime.recents.where((r) => r.phone == '+22370123456'),
        hasLength(1),
      );
      expect(airtime.recents.first.amount, '5000');
    });

    test('the next number is asked about afresh', () async {
      await pickMali();
      airtime.onPhoneInput('70123456');
      await settle();
      airtime.selectAmount(airtime.operator!.amounts.first);
      await settle(40);
      airtime.afterAdded();

      airtime.onPhoneInput('60123456');
      await settle();

      expect(airtime.operator!.id, 290);
    });
  });
}
