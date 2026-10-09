import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/models/service_country_detail.dart';
import '../../../data/models/service_kinds.dart';
import '../../../data/models/service_quote.dart';
import '../../../data/models/services_directory.dart';
import '../../../data/repositories/integrations_repository.dart';
import '../direct_services/foreign_amount.dart';
import 'service_blocker.dart';
import 'service_quote_controller.dart';
import 'services_catalog.dart';

/// Where the cashier is in paying a bill. The first two are choices from a
/// list; the third asks for the number on the bill; then the amount; then the
/// summary the customer is read back.
enum BillFlowStep { country, provider, account, amount, summary }

/// Paying one type of bill abroad — electricity, water, television, internet —
/// from the country, through the provider and the number on the bill, to the
/// amount, until the server has priced exactly that.
///
/// One of these per opening of a bill card: the flow is modal, so nothing in
/// it outlives the cashier's visit to it. It reads the world from the shared
/// [ServicesCatalog].
class BillFlowViewModel extends ChangeNotifier {
  BillFlowViewModel({
    required this.type,
    required ServicesCatalog catalog,
    required IntegrationsRepository repository,
    Duration quoteDebounce = const Duration(milliseconds: 400),
  }) : _catalog = catalog,
       quote = ServiceQuoteController(
         quote: repository.quoteService,
         debounce: quoteDebounce,
       ) {
    quote.addListener(_onQuoteChanged);
    _catalog.addListener(_onCatalogChanged);
    _begin();
  }

  /// The longest invoice number the relay takes.
  static const int maxInvoiceLength = 24;

  /// The fewest characters an account or meter number can have.
  static const int minAccountLength = 4;
  static const int maxAccountLength = 30;

  final BillType type;
  final ServicesCatalog _catalog;

  /// The price of exactly what is on screen.
  final ServiceQuoteController quote;

  bool _disposed = false;

  ServicesCatalog get catalog => _catalog;

  // --- the countries ------------------------------------------------------------

  /// The countries that have a provider of this type, in the directory's
  /// order. Empty until the directory is read.
  List<ServiceCountry> get countries =>
      _catalog.directory?.billCountries(type) ?? const [];

  /// How many providers of this type [code] has, when that is known: the
  /// directory said, or the country has been read.
  int? providerCount(String code) {
    final key = code.toUpperCase();
    final told = _catalog.directory?.billType(type)?.counts[key];
    if (told != null) {
      return told;
    }
    final detail = _catalog.detailOf(key);
    return detail?.billersOf(type).length;
  }

  bool _started = false;

  /// Runs once, as soon as the directory is there: a type sold in one country
  /// starts at its providers, and — when the directory does not count them —
  /// every country is read in the background so the counts are on screen by
  /// the time the cashier looks for them.
  void _begin() {
    if (_started || _catalog.directory == null) {
      return;
    }
    _started = true;
    // The directory says how many providers each country has: no need to read
    // every country just to put «10 جهات» on a row. Without it (an older
    // server) they are read in the background instead.
    final told = _catalog.directory?.billType(type)?.counts.isNotEmpty ?? false;
    if (!told) {
      _catalog.prefetchDetails(countries.map((country) => country.code));
    }
    final only = countries.length == 1 ? countries.single : null;
    if (only != null) {
      _country = only;
      _autoCountry = true;
      unawaited(_catalog.loadDetail(only.code));
      _step = BillFlowStep.provider;
      _autoProvider();
    }
  }

  // --- the steps --------------------------------------------------------------------

  BillFlowStep _step = BillFlowStep.country;
  ServiceCountry? _country;
  BillBiller? _biller;
  bool _autoCountry = false;
  bool _providerFixed = false;

  BillFlowStep get step => _step;

  ServiceCountry? get country => _country;
  BillBiller? get biller => _biller;

  /// The only country that has this type, so the cashier was never asked.
  bool get isCountryFixed => _autoCountry;

  /// The only provider the country has, so the cashier was never asked.
  bool get isProviderFixed => _providerFixed;

  ServiceCountryDetail? get detail {
    final country = _country;
    return country == null ? null : _catalog.detailOf(country.code);
  }

  bool get isLoadingCountry {
    final country = _country;
    return country != null &&
        detail == null &&
        _catalog.isLoadingDetail(country.code);
  }

  bool get hasCountryError {
    final country = _country;
    return country != null && _catalog.hasDetailError(country.code);
  }

  /// The picked country's providers of this type, in the server's order.
  List<BillBiller> get billers =>
      detail?.billersOf(type) ?? const <BillBiller>[];

  void retryCountry() {
    final country = _country;
    if (country != null) {
      unawaited(_catalog.loadDetail(country.code, force: true));
      notifyListeners();
    }
  }

  /// Reads the directory and this country again — the list the flow was built
  /// on is out of date — and keeps the provider the cashier chose when it is
  /// still offered; when it is not, the flow is back at choosing one.
  Future<void> refreshList() async {
    final country = _country;
    await _catalog.reload();
    if (country != null) {
      await _catalog.loadDetail(country.code, force: true);
    }
    if (_disposed) {
      return;
    }
    final chosen = _biller;
    if (chosen != null) {
      final again = detail?.biller(chosen.id);
      if (again == null) {
        _forgetFrom(BillFlowStep.provider);
        _step = BillFlowStep.provider;
        _autoProvider();
      } else {
        _biller = again;
      }
    }
    _requote(immediate: true, force: true);
    notifyListeners();
  }

  void selectCountry(ServiceCountry country) {
    if (_country?.code != country.code) {
      _country = country;
      _autoCountry = false;
      _forgetFrom(BillFlowStep.provider);
      unawaited(_catalog.loadDetail(country.code));
    }
    _step = BillFlowStep.provider;
    _autoProvider();
    notifyListeners();
  }

  void selectBiller(BillBiller biller) {
    if (_biller?.id != biller.id) {
      _biller = biller;
      _providerFixed = false;
      _forgetFrom(BillFlowStep.account);
    }
    _step = BillFlowStep.account;
    _requote();
    notifyListeners();
  }

  /// A country with one provider needs no question.
  void _autoProvider() {
    final loaded = detail;
    if (loaded == null || _country == null) {
      return;
    }
    final all = loaded.billersOf(type);
    if (all.length == 1 && _biller == null) {
      _biller = all.single;
      _providerFixed = true;
      _step = BillFlowStep.account;
    }
  }

  void _onCatalogChanged() {
    _begin();
    if (_step == BillFlowStep.provider || _step == BillFlowStep.country) {
      final before = _step;
      _autoProvider();
      if (before != _step) {
        _requote();
      }
    }
    notifyListeners();
  }

  /// The earliest step the cashier can be on: the ones before it were fixed
  /// by the data, not chosen.
  BillFlowStep get firstStep {
    if (_autoCountry && _providerFixed) return BillFlowStep.account;
    if (_autoCountry) return BillFlowStep.provider;
    return BillFlowStep.country;
  }

  bool get canGoBack => _step.index > firstStep.index;

  /// One step back; what was chosen after it is kept until it changes.
  void back() {
    if (!canGoBack) {
      return;
    }
    _addRefused = false;
    var previous = BillFlowStep.values[_step.index - 1];
    if (previous == BillFlowStep.provider && _providerFixed) {
      previous = BillFlowStep.country;
    }
    if (previous.index < firstStep.index) {
      return;
    }
    _step = previous;
    notifyListeners();
  }

  /// Jumps to a step already passed (the breadcrumb).
  void goTo(BillFlowStep step) {
    if (step.index > _step.index || step.index < firstStep.index) {
      return;
    }
    _step = step;
    notifyListeners();
  }

  /// Forgets what was chosen from [from] onward.
  void _forgetFrom(BillFlowStep from) {
    if (from.index <= BillFlowStep.provider.index) {
      _biller = null;
      _providerFixed = false;
    }
    if (from.index <= BillFlowStep.account.index) {
      _account = '';
      _invoice = '';
    }
    if (from.index <= BillFlowStep.amount.index) {
      _clearAmount();
    }
    quote.clear();
  }

  // --- the number on the bill ----------------------------------------------------------

  String _account = '';
  String _invoice = '';

  String get account => _account;
  String get invoice => _invoice;

  bool get needsInvoice => _biller?.requiresInvoice ?? false;

  void setAccount(String value) {
    final next = value.trim();
    if (next == _account) {
      return;
    }
    _account = next;
    _requote();
    notifyListeners();
  }

  void setInvoice(String value) {
    final next = value.trim();
    if (next == _invoice) {
      return;
    }
    _invoice = next;
    _requote();
    notifyListeners();
  }

  bool get isAccountOk =>
      _account.length >= minAccountLength &&
      _account.length <= maxAccountLength;

  bool get isInvoiceOk =>
      _invoice.isNotEmpty &&
      _invoice.length <= maxInvoiceLength &&
      RegExp(r'^[A-Za-z0-9\-_/]+$').hasMatch(_invoice);

  /// The number step is complete.
  bool get isAccountStepDone => isAccountOk && (!needsInvoice || isInvoiceOk);

  /// Moves on from the number step when it is complete.
  void continueFromAccount() {
    if (_biller != null && isAccountStepDone) {
      _step = BillFlowStep.amount;
      if (needsInvoice && _biller!.isRange && !_customOpen) {
        _customOpen = true;
      }
      notifyListeners();
    }
  }

  // --- the amount --------------------------------------------------------------------------

  String? _amount;
  BillPlan? _plan;
  bool _customOpen = false;
  String _customText = '';

  /// The amount chosen, in the provider's currency, as the relay writes it.
  String? get amount => _amount;

  /// The plan chosen, for a provider that sells only plans.
  BillPlan? get plan => _plan;

  bool get isCustomOpen => _customOpen;
  String get customText => _customText;

  /// The suggested amount equal to [amount], if there is one.
  BillAmount? get selectedSuggestion {
    final amount = _amount;
    if (amount == null || _plan != null) {
      return null;
    }
    for (final suggestion in _biller?.suggested ?? const <BillAmount>[]) {
      if (suggestion.amount == amount) {
        return suggestion;
      }
    }
    return null;
  }

  ServiceAmountProblem? get customProblem {
    final biller = _biller;
    if (!_customOpen || biller == null || _customText.trim().isEmpty) {
      return null;
    }
    final value = parseTypedAmount(_customText);
    if (value == null) {
      return ServiceAmountProblem.invalid;
    }
    if (biller.min != null && value < biller.min!) {
      return ServiceAmountProblem.belowMin;
    }
    if (biller.max != null && value > biller.max!) {
      return ServiceAmountProblem.aboveMax;
    }
    return null;
  }

  void selectPlan(BillPlan plan) {
    _plan = plan;
    _amount = plan.amount;
    _customOpen = false;
    _customText = '';
    _requote(immediate: true);
    notifyListeners();
  }

  void selectSuggestion(BillAmount suggestion) {
    _plan = null;
    _amount = suggestion.amount;
    _customOpen = false;
    _customText = '';
    _requote(immediate: true);
    notifyListeners();
  }

  void openCustomAmount() {
    if (_customOpen) {
      return;
    }
    _customOpen = true;
    _plan = null;
    _amount = null;
    _customText = '';
    quote.clear();
    notifyListeners();
  }

  void setCustomAmount(String typed) {
    _customOpen = true;
    _plan = null;
    _customText = typed;
    _amount = customProblem == null && typed.trim().isNotEmpty
        ? canonicalAmountText(typed)
        : null;
    _requote();
    notifyListeners();
  }

  void _clearAmount() {
    _amount = null;
    _plan = null;
    _customOpen = false;
    _customText = '';
  }

  /// Moves on from the amount step when an amount is chosen.
  void continueFromAmount() {
    if (_amount != null && customProblem == null) {
      _step = BillFlowStep.summary;
      notifyListeners();
    }
  }

  // --- pricing ---------------------------------------------------------------------------------

  ServiceQuoteRequest? _buildRequest() {
    final country = _country;
    final biller = _biller;
    final amount = _amount;
    if (country == null ||
        biller == null ||
        amount == null ||
        !isAccountStepDone) {
      return null;
    }
    return ServiceQuoteRequest.bill(
      country: country.code,
      billerId: biller.id,
      account: _account,
      amount: amount,
      amountCurrency: biller.amountCurrency,
      amountId: _plan?.id,
      invoiceId: biller.requiresInvoice ? _invoice : null,
    );
  }

  void _requote({bool immediate = false, bool force = false}) {
    quote.ask(_buildRequest(), immediate: immediate, force: force);
  }

  ServiceQuote? get readyQuote => quote.ready;

  /// The first thing still missing before the line can go in the cart.
  ServiceBlocker? get blocker {
    if (_country == null) {
      return const ServiceBlocker(ServiceBlockReason.noCountry);
    }
    if (detail == null) {
      return ServiceBlocker(
        isLoadingCountry
            ? ServiceBlockReason.loadingCountry
            : ServiceBlockReason.countryFailed,
      );
    }
    final biller = _biller;
    if (biller == null) {
      return const ServiceBlocker(ServiceBlockReason.noProvider);
    }
    if (_account.isEmpty) {
      return const ServiceBlocker(ServiceBlockReason.noAccount);
    }
    if (!isAccountOk) {
      return const ServiceBlocker(ServiceBlockReason.accountTooShort);
    }
    if (biller.requiresInvoice && !isInvoiceOk) {
      return const ServiceBlocker(ServiceBlockReason.noInvoice);
    }
    if (_amount == null) {
      return switch (customProblem) {
        ServiceAmountProblem.invalid => const ServiceBlocker(
          ServiceBlockReason.amountInvalid,
        ),
        ServiceAmountProblem.belowMin => ServiceBlocker(
          ServiceBlockReason.amountBelowMin,
          min: biller.min,
          max: biller.max,
        ),
        ServiceAmountProblem.aboveMax => ServiceBlocker(
          ServiceBlockReason.amountAboveMax,
          min: biller.min,
          max: biller.max,
        ),
        null => ServiceBlocker(
          biller.isFixed
              ? ServiceBlockReason.noPlan
              : ServiceBlockReason.noAmount,
        ),
      };
    }
    return switch (quote.status) {
      ServiceQuoteStatus.ready => null,
      ServiceQuoteStatus.refused => ServiceBlocker(
        ServiceBlockReason.quoteRefused,
        code: quote.refusal?.errorCode ?? '',
        min: quote.refusal?.min,
        max: quote.refusal?.max,
      ),
      ServiceQuoteStatus.failed => const ServiceBlocker(
        ServiceBlockReason.quoteFailed,
      ),
      ServiceQuoteStatus.idle || ServiceQuoteStatus.loading =>
        const ServiceBlocker(ServiceBlockReason.quoting),
    };
  }

  bool get canAdd => blocker == null;

  bool _addRefused = false;

  /// The cart could not take the bill — a sale is being completed — and the
  /// summary says so until something changes.
  bool get addRefused => _addRefused;

  void markAddRefused() {
    _addRefused = true;
    notifyListeners();
  }

  void _onQuoteChanged() {
    _addRefused = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _catalog.removeListener(_onCatalogChanged);
    quote.removeListener(_onQuoteChanged);
    quote.dispose();
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }
}
