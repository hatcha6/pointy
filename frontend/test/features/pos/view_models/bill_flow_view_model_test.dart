import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/services_fake_repository.dart';
import 'package:pointy_frontend/dev/services_fixtures.dart';
import 'package:pointy_frontend/src/data/models/service_kinds.dart';
import 'package:pointy_frontend/src/data/models/service_quote.dart';
import 'package:pointy_frontend/src/data/models/services_directory.dart';
import 'package:pointy_frontend/src/features/pos/view_models/bill_flow_view_model.dart';
import 'package:pointy_frontend/src/features/pos/view_models/service_blocker.dart';
import 'package:pointy_frontend/src/features/pos/view_models/service_quote_controller.dart';
import 'package:pointy_frontend/src/features/pos/view_models/services_catalog.dart';

/// Paying a bill abroad from the cashier's side: country, provider, the
/// number on the bill, the amount — and a price the server stands behind.
void main() {
  late PreviewServicesRepository repository;
  late ServicesCatalog catalog;
  final flows = <BillFlowViewModel>[];

  setUp(() async {
    repository = PreviewServicesRepository();
    catalog = ServicesCatalog(repository: repository);
    await catalog.ensureLoaded();
  });

  tearDown(() {
    for (final flow in flows) {
      flow.dispose();
    }
    flows.clear();
    catalog.dispose();
  });

  BillFlowViewModel open(BillType type) {
    final flow = BillFlowViewModel(
      type: type,
      catalog: catalog,
      repository: repository,
      quoteDebounce: const Duration(milliseconds: 20),
    );
    flows.add(flow);
    return flow;
  }

  Future<void> settle([int milliseconds = 80]) =>
      Future<void>.delayed(Duration(milliseconds: milliseconds));

  group('the countries', () {
    test(
      'are the ones that have this type, counted by the directory',
      () async {
        final flow = open(BillType.electricity);
        await settle();

        expect(flow.step, BillFlowStep.country);
        expect(flow.countries.map((c) => c.code).toSet(), {
          'NG',
          'SN',
          'ML',
          'ZA',
          'MZ',
          'MW',
        });
        // The directory counts the providers of each country, so none is read
        // just to say «10 جهات».
        expect(repository.countryReads, isEmpty);
        expect(flow.providerCount('NG'), 10);
        expect(flow.providerCount('ML'), 1);
        expect(flow.providerCount('XX'), isNull);
      },
    );

    test(
      'are read in the background when the directory does not count them',
      () async {
        repository.directory = ServicesDirectory.fromJson(
          servicesPreviewDirectoryJson(withCounts: false),
        );
        catalog.dispose();
        catalog = ServicesCatalog(repository: repository);
        await catalog.ensureLoaded();

        final flow = open(BillType.electricity);
        await settle();

        // Each was read, so each can say how many providers it has.
        expect(
          repository.countryReads.keys.toSet(),
          flow.countries.map((c) => c.code).toSet(),
        );
        expect(flow.providerCount('NG'), 10);
        expect(flow.providerCount('ML'), 1);
      },
    );

    test('a type sold in one country starts at its providers', () async {
      final flow = open(BillType.water);
      await settle();

      expect(flow.countries.map((c) => c.code), ['SN']);
      expect(flow.isCountryFixed, isTrue);
      expect(flow.country!.code, 'SN');
      // …and Senegal's one water company is chosen too.
      expect(flow.isProviderFixed, isTrue);
      expect(flow.biller!.id, 52);
      expect(flow.step, BillFlowStep.account);
      expect(flow.firstStep, BillFlowStep.account);
      expect(flow.canGoBack, isFalse);
    });

    test('opened before the directory arrived, waits for it', () async {
      final slow = PreviewServicesRepository(
        directoryDelay: const Duration(milliseconds: 60),
      );
      final slowCatalog = ServicesCatalog(repository: slow);
      final flow = BillFlowViewModel(
        type: BillType.water,
        catalog: slowCatalog,
        repository: slow,
      );
      expect(flow.countries, isEmpty);
      expect(flow.step, BillFlowStep.country);

      await slowCatalog.ensureLoaded();
      await settle(120);

      expect(flow.country!.code, 'SN');
      expect(flow.step, BillFlowStep.account);
      flow.dispose();
      slowCatalog.dispose();
    });
  });

  group('the steps', () {
    test('go country, provider, number, amount, summary — and back', () async {
      final flow = open(BillType.electricity);
      await settle();
      expect(flow.canGoBack, isFalse);

      flow.selectCountry(catalog.directory!.country('NG')!);
      expect(flow.step, BillFlowStep.provider);
      await catalog.loadDetail('NG');
      await settle(10);
      expect(flow.billers, hasLength(10));

      flow.selectBiller(flow.billers.first);
      expect(flow.step, BillFlowStep.account);
      expect(flow.biller!.name, 'كهرباء إيكيجا (مسبقة الدفع)');

      flow.setAccount('04223568280');
      expect(flow.isAccountStepDone, isTrue);
      flow.continueFromAccount();
      expect(flow.step, BillFlowStep.amount);

      flow.selectSuggestion(flow.biller!.suggested[1]);
      flow.continueFromAmount();
      expect(flow.step, BillFlowStep.summary);

      flow.back();
      expect(flow.step, BillFlowStep.amount);
      flow.goTo(BillFlowStep.provider);
      expect(flow.step, BillFlowStep.provider);
      expect(flow.biller, isNotNull, reason: 'kept until something changes');
      flow.goTo(BillFlowStep.summary);
      expect(flow.step, BillFlowStep.provider, reason: 'not forward');
    });

    test('another provider forgets the number and the amount', () async {
      final flow = open(BillType.electricity);
      await settle();
      flow.selectCountry(catalog.directory!.country('NG')!);
      await catalog.loadDetail('NG');
      flow.selectBiller(flow.billers.first);
      flow.setAccount('04223568280');
      flow.continueFromAccount();
      flow.selectSuggestion(flow.biller!.suggested.first);

      flow.goTo(BillFlowStep.provider);
      flow.selectBiller(flow.billers[2]);

      expect(flow.account, isEmpty);
      expect(flow.amount, isNull);
      expect(flow.quote.status, ServiceQuoteStatus.idle);
      expect(flow.step, BillFlowStep.account);
    });

    test('another country forgets the provider', () async {
      final flow = open(BillType.electricity);
      await settle();
      flow.selectCountry(catalog.directory!.country('NG')!);
      await catalog.loadDetail('NG');
      flow.selectBiller(flow.billers.first);

      flow.goTo(BillFlowStep.country);
      flow.selectCountry(catalog.directory!.country('ML')!);
      await catalog.loadDetail('ML');
      await settle(10);

      expect(
        flow.biller,
        isNotNull,
        reason: 'Mali has one: chosen for the cashier',
      );
      expect(flow.biller!.id, 40);
      expect(flow.isProviderFixed, isTrue);
    });
  });

  group('the number on the bill', () {
    test(
      'needs a few characters, and for a postpaid invoice the invoice too',
      () async {
        final flow = open(BillType.water);
        await settle();

        expect(flow.needsInvoice, isTrue);
        expect(flow.isAccountStepDone, isFalse);
        flow.setAccount('45');
        expect(flow.isAccountOk, isFalse);
        flow.setAccount('4521897');
        expect(flow.isAccountOk, isTrue);
        expect(flow.isAccountStepDone, isFalse, reason: 'no invoice yet');
        flow.setInvoice('bad invoice!');
        expect(flow.isInvoiceOk, isFalse);
        flow.setInvoice('2024-118833');
        expect(flow.isInvoiceOk, isTrue);
        expect(flow.isAccountStepDone, isTrue);
        flow.setInvoice('X' * 25);
        expect(flow.isInvoiceOk, isFalse, reason: 'at most 24 characters');
      },
    );

    test('is not continued from until it is complete', () async {
      final flow = open(BillType.water);
      await settle();
      flow.setAccount('4521897');
      flow.continueFromAccount();
      expect(flow.step, BillFlowStep.account);

      flow.setInvoice('2024-118833');
      flow.continueFromAccount();
      expect(flow.step, BillFlowStep.amount);
      // An invoice is paid by its total, typed as written on it.
      expect(flow.isCustomOpen, isTrue);
    });
  });

  group('the amount', () {
    Future<BillFlowViewModel> ready(
      BillType type,
      String country,
      int providerIndex,
    ) async {
      final flow = open(type);
      await settle();
      if (flow.country == null) {
        flow.selectCountry(catalog.directory!.country(country)!);
      }
      await catalog.loadDetail(country);
      await settle(10);
      if (flow.biller == null) {
        flow.selectBiller(flow.billers[providerIndex]);
      }
      return flow;
    }

    test(
      'a suggestion is priced at once, with the server\'s own option code',
      () async {
        final flow = await ready(BillType.electricity, 'NG', 0);
        flow.setAccount('04223568280');
        flow.continueFromAccount();
        flow.selectSuggestion(flow.biller!.suggested[1]);
        await settle(40);

        expect(flow.canAdd, isTrue);
        expect(flow.readyQuote!.optionCode, 'bill:5:5000:NGN');
        expect(flow.readyQuote!.subscriberRef, '04223568280');
        expect(repository.quotes.last.toJson(), {
          'kind': 'bill',
          'country': 'NG',
          'biller_id': 5,
          'account': '04223568280',
          'amount': '5000',
          'amount_currency': 'NGN',
        });
      },
    );

    test('a plan is priced by its id', () async {
      final flow = await ready(BillType.tv, 'ML', 0);
      expect(flow.biller!.isFixed, isTrue);
      flow.setAccount('0123456789');
      flow.continueFromAccount();
      flow.selectPlan(flow.biller!.plans.first);
      expect(flow.blocker!.reason, ServiceBlockReason.quoting);
      await settle(40);

      expect(flow.plan!.id, 241);
      expect(flow.amount, '10000');
      expect(repository.quotes.last.amountId, 241);
      expect(flow.readyQuote!.optionCode, 'bill:24:10000:XOF:241');
      expect(flow.canAdd, isTrue);
    });

    test(
      'an invoice\'s total is typed, and the invoice travels with it',
      () async {
        final flow = open(BillType.water);
        await settle();
        flow.setAccount('4521897');
        flow.setInvoice('2024-118833');
        flow.continueFromAccount();
        flow.setCustomAmount('15,000');
        await settle(60);

        expect(flow.amount, '15000');
        expect(repository.quotes.last.invoiceId, '2024-118833');
        expect(repository.quotes.last.toJson()['invoice_id'], '2024-118833');
        expect(flow.readyQuote!.optionCode, 'bill:52:15000:XOF::2024-118833');
        expect(flow.canAdd, isTrue);
      },
    );

    test('a typed amount is held to the provider\'s limits', () async {
      final flow = await ready(BillType.electricity, 'NG', 0);
      flow.setAccount('04223568280');
      flow.continueFromAccount();
      flow.openCustomAmount();

      flow.setCustomAmount('500');
      expect(flow.blocker!.reason, ServiceBlockReason.amountBelowMin);
      expect(flow.blocker!.min, 1000);
      flow.setCustomAmount('900000');
      expect(flow.blocker!.reason, ServiceBlockReason.amountAboveMax);
      flow.setCustomAmount('12000');
      expect(flow.amount, '12000');
    });

    test('the server may still refuse: the invoice, the account', () async {
      repository.refuseQuote = ServiceRefusalCode.invoiceRequired;
      final flow = open(BillType.water);
      await settle();
      flow.setAccount('4521897');
      flow.setInvoice('2024-118833');
      flow.continueFromAccount();
      flow.setCustomAmount('15000');
      await settle(60);

      expect(flow.blocker!.reason, ServiceBlockReason.quoteRefused);
      expect(flow.blocker!.code, ServiceRefusalCode.invoiceRequired);
    });
  });

  group('why it cannot be added', () {
    test('is the first thing still missing', () async {
      final flow = open(BillType.electricity);
      await settle();
      expect(flow.blocker!.reason, ServiceBlockReason.noCountry);
      flow.selectCountry(catalog.directory!.country('NG')!);
      expect(
        flow.blocker!.reason,
        anyOf(ServiceBlockReason.loadingCountry, ServiceBlockReason.noProvider),
      );
      await catalog.loadDetail('NG');
      await settle(10);
      expect(flow.blocker!.reason, ServiceBlockReason.noProvider);
      flow.selectBiller(flow.billers.first);
      expect(flow.blocker!.reason, ServiceBlockReason.noAccount);
      flow.setAccount('04');
      expect(flow.blocker!.reason, ServiceBlockReason.accountTooShort);
      flow.setAccount('04223568280');
      expect(flow.blocker!.reason, ServiceBlockReason.noAmount);
      flow.selectSuggestion(flow.biller!.suggested.first);
      await settle(40);
      expect(flow.blocker, isNull);
    });

    test(
      'names a missing plan, not a missing amount, for a provider of plans',
      () async {
        final flow = open(BillType.tv);
        await settle();
        flow.selectCountry(catalog.directory!.country('ML')!);
        await catalog.loadDetail('ML');
        await settle(10);
        flow.setAccount('0123456789');

        expect(flow.blocker!.reason, ServiceBlockReason.noPlan);
      },
    );
  });
}
