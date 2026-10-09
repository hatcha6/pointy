import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/service_country_detail.dart';
import '../../../data/models/service_kinds.dart';
import '../../../data/models/service_quote.dart';
import '../../../data/models/services_directory.dart';
import '../../../data/repositories/integrations_repository.dart';
import '../direct_services/arabic_search_text.dart';
import '../direct_services/country_search.dart';
import '../direct_services/foreign_amount.dart';
import '../direct_services/phone_entry.dart';
import 'service_blocker.dart';
import 'service_quote_controller.dart';
import 'services_catalog.dart';

/// What the relay said about the number's network.
enum AirtimeDetectionStatus {
  /// Nothing asked yet: the number is not long enough, or still changing.
  idle,
  detecting,
  detected,

  /// The relay could not place the number on a network.
  notDetected,

  /// The relay says the number is not a number of this country.
  invalidNumber,

  /// The relay could not be asked right now.
  unavailable,

  /// The question never got an answer.
  failed,
}

/// What Enter in the number field comes to, for a cashier at the keyboard.
enum AirtimeEnter {
  /// Nothing is missing: put the line in the cart.
  add,

  /// The network takes any amount and none is chosen: open its field.
  openCustomAmount,

  /// Go to the amounts that are there: the open field, or the first tile.
  focusAmount,

  /// Something earlier is still missing (the network, the rest of the number):
  /// stay, the line under the button says what.
  stay,
}

/// Digits that begin with the picked country's own calling code, and what
/// they would be without it: `22370123456` with Mali is probably `70123456`.
class DialCodeCorrection {
  const DialCodeCorrection({required this.dial, required this.national});

  final String dial;
  final String national;
}

/// The airtime pane: country, then the number, then the amount, until the
/// server has priced exactly that and the cashier can add it to the cart.
///
/// Held by the till for the length of the shift, so a half-typed number
/// survives the window being resized. Every network call is cancelled in
/// effect by the next change — an answer to a number that is no longer the
/// number on screen is dropped — and none of them blocks the cashier from
/// choosing the network by hand.
class AirtimeViewModel extends ChangeNotifier {
  AirtimeViewModel({
    required ServicesCatalog catalog,
    required IntegrationsRepository repository,
    this.detectDebounce = const Duration(milliseconds: 450),
    Duration quoteDebounce = const Duration(milliseconds: 400),
  }) : _catalog = catalog,
       _repository = repository,
       quote = ServiceQuoteController(
         quote: repository.quoteService,
         debounce: quoteDebounce,
       ) {
    quote.addListener(notifyListeners);
    _catalog.addListener(_onCatalogChanged);
  }

  final ServicesCatalog _catalog;
  final IntegrationsRepository _repository;

  /// The pause after the last digit before the network is asked for.
  final Duration detectDebounce;

  /// The shortest number worth asking the relay about.
  static const int minDigitsToDetect = 6;

  /// The price of exactly what is on screen.
  final ServiceQuoteController quote;

  bool _disposed = false;

  ServicesCatalog get catalog => _catalog;

  // --- step 1: the country ---------------------------------------------------

  ServiceCountry? _country;

  /// The country picked; null until one is.
  ServiceCountry? get country => _country;

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

  /// Picks [country]. Another country forgets the network and the amount; the
  /// number stays, in case it was typed or pasted first.
  void selectCountry(ServiceCountry country) {
    final answered = _answerDialChoices(country);
    if (_country?.code == country.code) {
      if (answered) {
        _afterNumberOrCountryChange();
        notifyListeners();
      }
      return;
    }
    _country = country;
    _operator = null;
    _manualOperator = false;
    _detected = null;
    _detectedPhone = null;
    _detectionStatus = AirtimeDetectionStatus.idle;
    _detectionReason = '';
    _detectSequence++;
    _detectTimer?.cancel();
    _clearAmount();
    quote.clear();
    _detailApplied = false;
    unawaited(_catalog.loadDetail(country.code));
    _applyDetailIfReady();
    _afterNumberOrCountryChange();
    notifyListeners();
  }

  /// Reads the picked country's networks again after a failure.
  void retryCountry() {
    final country = _country;
    if (country == null) {
      return;
    }
    _detailApplied = false;
    unawaited(_catalog.loadDetail(country.code, force: true));
    notifyListeners();
  }

  // --- step 2: the number ------------------------------------------------------

  String _national = '';
  bool _internationalPending = false;
  bool _unknownPrefix = false;
  List<ServiceCountry> _dialChoices = const [];
  String _pendingNational = '';
  String? _sharedDial;

  /// Bumped whenever the view model rewrote the digits itself — a pasted
  /// international number — so the field shows them.
  int phoneRevision = 0;

  /// The countries a pasted number's calling code could be, when it is one
  /// several share (`+1`) and nothing says which: the cashier is asked, the
  /// first of them is never taken. Empty otherwise.
  List<ServiceCountry> get dialChoices => _dialChoices;

  /// The shared calling code the choices are for, digits only (`1`); null when
  /// there is no question.
  String? get sharedDial => _sharedDial;

  /// The cashier says which of [dialChoices] the pasted number is for: that
  /// country is taken, with the digits that followed the code.
  void chooseDialCountry(ServiceCountry country) {
    if (_dialChoices.any((candidate) => candidate.code == country.code)) {
      selectCountry(country);
    }
  }

  void _forgetDialChoices() {
    _dialChoices = const [];
    _pendingNational = '';
    _sharedDial = null;
  }

  /// A country was picked while a shared calling code waited for an answer.
  /// When it is one of the countries asked about, the number pasted is its
  /// own, without the code; any other country means the paste was not for it.
  /// True when the digits changed.
  bool _answerDialChoices(ServiceCountry country) {
    if (_dialChoices.isEmpty) {
      return false;
    }
    final belongs = _dialChoices.any((c) => c.code == country.code);
    final pending = _pendingNational;
    _forgetDialChoices();
    _internationalPending = false;
    _national = belongs ? pending : '';
    phoneRevision++;
    return true;
  }

  /// The digits of the number as typed, without the country's code.
  String get national => _national;

  /// An international number is being typed whose country is not known yet.
  bool get isInternationalPending => _internationalPending;

  /// The international number typed starts with a code no country has.
  bool get hasUnknownPrefix => _unknownPrefix;

  /// What the number typed would be without the country's own calling code,
  /// when it begins with it — a customer's number copied with its code but no
  /// plus, `22370123456` with Mali. Never applied by itself (India's numbers
  /// may begin 91): the screen offers it, one tap fixes it. Null when the
  /// digits are too few to be a code and a number, or when the relay placed
  /// them as they stand.
  DialCodeCorrection? get dialCodeCorrection {
    final country = _country;
    if (country == null || _internationalPending) {
      return null;
    }
    final dial = CountrySearch.dialOf(country, _national);
    if (dial == null) {
      return null;
    }
    final rest = _national.substring(dial.length);
    if (_national.length < 10 || rest.length < 7) {
      return null;
    }
    if (_detectionStatus == AirtimeDetectionStatus.detected) {
      final placed = digitsOnly(_detectedPhone?.e164 ?? '');
      if (country.dial.any((code) => placed == '$code$_national')) {
        return null;
      }
    }
    return DialCodeCorrection(dial: dial, national: rest);
  }

  /// Takes the number without its country's calling code, after the cashier
  /// said that is what they meant.
  void applyDialCodeCorrection() {
    final fix = dialCodeCorrection;
    if (fix == null) {
      return;
    }
    _national = fix.national;
    phoneRevision++;
    _afterNumberOrCountryChange();
    notifyListeners();
  }

  /// The number as the cashier reads it back: `+223 70 12 34 56`.
  String get displayNumber {
    final country = _country;
    return PhoneEntry.display(
      dial: country?.primaryDial ?? '',
      national: _national,
    );
  }

  bool get hasPlausibleNumber {
    final country = _country;
    return country != null &&
        PhoneEntry.isPlausible(dial: country.primaryDial, national: _national);
  }

  /// The text of the number field changed. [pasted] says a whole number
  /// arrived at once: an international one then picks its country, whatever
  /// its length.
  void onPhoneInput(String raw, {bool pasted = false}) {
    _forgetDialChoices();
    if (PhoneEntry.looksInternational(raw)) {
      final digits = digitsOnly(raw);
      final search = _catalog.airtimeSearch;
      if (search != null && (pasted || digits.length >= 9)) {
        final parse = PhoneEntry.parse(
          raw,
          directory: search,
          current: _country,
        );
        final found = parse.country;
        if (found != null) {
          _internationalPending = false;
          _unknownPrefix = false;
          _national = parse.national;
          phoneRevision++;
          if (_country?.code != found.code) {
            selectCountry(found);
          } else {
            _afterNumberOrCountryChange();
          }
          notifyListeners();
          return;
        }
        if (parse.isSharedCode) {
          // Several countries have this code: the number is held until the
          // cashier says whose it is, and nothing is guessed meanwhile.
          _dialChoices = parse.candidates;
          _sharedDial = parse.sharedDial;
          _pendingNational = parse.national;
          _unknownPrefix = false;
        } else {
          _unknownPrefix = true;
        }
      }
      _internationalPending = true;
      if (_national.isNotEmpty) {
        _national = '';
        _afterNumberOrCountryChange();
      }
      notifyListeners();
      return;
    }
    final digits = digitsOnly(raw);
    final changed =
        digits != _national || _internationalPending || _unknownPrefix;
    _internationalPending = false;
    _unknownPrefix = false;
    if (!changed) {
      return;
    }
    _national = digits;
    _afterNumberOrCountryChange();
    notifyListeners();
  }

  void _afterNumberOrCountryChange() {
    // What was found for the old number says nothing about the new one.
    _detectSequence++;
    _detectTimer?.cancel();
    _detectedPhone = null;
    if (_detectionStatus != AirtimeDetectionStatus.idle) {
      _detectionStatus = AirtimeDetectionStatus.idle;
      _detectionReason = '';
    }
    if (_country != null &&
        _national.length >= minDigitsToDetect &&
        !_internationalPending) {
      final sequence = _detectSequence;
      final code = _country!.code;
      final digits = _national;
      _detectTimer = Timer(
        detectDebounce,
        () => unawaited(_runDetection(sequence, code, digits)),
      );
    }
    _requote();
  }

  // --- the network ---------------------------------------------------------------

  AirtimeOperator? _operator;
  AirtimeOperator? _detected;
  ServicePhone? _detectedPhone;
  bool _manualOperator = false;
  bool _detailApplied = false;
  AirtimeDetectionStatus _detectionStatus = AirtimeDetectionStatus.idle;
  String _detectionReason = '';
  Timer? _detectTimer;
  int _detectSequence = 0;

  /// The network chosen — by the relay, or by the cashier.
  AirtimeOperator? get operator => _operator;

  /// The network the relay placed the number on, once it has.
  AirtimeOperator? get detectedOperator => _detected;

  /// The number as the relay normalised it, once it has answered for it.
  ServicePhone? get detectedPhone => _detectedPhone;

  /// The number the server will send to — its own normalisation, grouped by
  /// calling code — once it has priced exactly this; null before. This is what
  /// the cashier reads back to the customer, not what was typed.
  String? get serverNumber {
    final priced = quote.ready;
    if (priced == null) {
      return null;
    }
    return PhoneEntry.displayE164(
      priced.subscriberRef,
      country: _country,
      directory: _catalog.airtimeSearch,
    );
  }

  /// The server priced a number that is not the one the relay placed: the two
  /// read the digits differently, and one of them is wrong.
  bool get numberMismatch {
    final priced = quote.ready;
    final placed = digitsOnly(_detectedPhone?.e164 ?? '');
    return priced != null &&
        placed.isNotEmpty &&
        placed != digitsOnly(priced.subscriberRef);
  }

  AirtimeDetectionStatus get detectionStatus => _detectionStatus;

  /// Why nothing was detected, as a refusal code.
  String get detectionReason => _detectionReason;

  /// The cashier chose the network themselves.
  bool get isManualOperator => _manualOperator;

  /// The cashier chose one network and the relay says it is another: a
  /// ported number, or a slip of the finger. Told, never overridden.
  bool get detectionDisagrees =>
      _manualOperator &&
      _detected != null &&
      _operator != null &&
      _detected!.id != _operator!.id &&
      _detectionStatus == AirtimeDetectionStatus.detected;

  /// The country's networks, plus the one the relay detected if the
  /// directory did not list it.
  List<AirtimeOperator> get networks {
    final listed = detail?.operators ?? const <AirtimeOperator>[];
    final extra = _detected;
    if (extra == null || listed.any((operator) => operator.id == extra.id)) {
      return listed;
    }
    return [...listed, extra];
  }

  /// Chooses the network by hand. The relay keeps its own opinion on screen
  /// (see [detectionDisagrees]) but no longer changes the choice.
  void selectOperator(AirtimeOperator operator) {
    _setOperator(operator, manual: true);
  }

  /// Takes the relay's network instead of the one chosen by hand.
  void useDetectedOperator() {
    final detected = _detected;
    if (detected != null) {
      _setOperator(detected, manual: false);
    }
  }

  void _setOperator(AirtimeOperator operator, {required bool manual}) {
    if (_operator?.id == operator.id && _manualOperator == manual) {
      return;
    }
    _operator = operator;
    _manualOperator = manual;
    _keepAmountIfOffered();
    _requote(immediate: true);
    notifyListeners();
  }

  void _applyDetailIfReady() {
    final country = _country;
    if (country == null || _detailApplied) {
      return;
    }
    final loaded = _catalog.detailOf(country.code);
    if (loaded == null) {
      return;
    }
    _detailApplied = true;
    if (_operator == null) {
      final pending = _pendingOperatorId;
      final wanted = pending == null ? null : loaded.operator(pending);
      if (wanted != null) {
        _operator = wanted;
        _manualOperator = true;
        _applyPendingAmount();
      } else if (loaded.operators.length == 1) {
        _operator = loaded.operators.single;
        _manualOperator = false;
      }
    }
    _pendingOperatorId = null;
    _pendingAmount = null;
    _requote(immediate: true);
  }

  void _onCatalogChanged() {
    _applyDetailIfReady();
    notifyListeners();
  }

  Future<void> _runDetection(int sequence, String code, String digits) async {
    if (_disposed || sequence != _detectSequence) {
      return;
    }
    _detectionStatus = AirtimeDetectionStatus.detecting;
    notifyListeners();
    final result = await _repository.detectServiceOperator(
      country: code,
      phone: digits,
    );
    // The number on screen moved on while the relay was thinking.
    if (_disposed || sequence != _detectSequence) {
      return;
    }
    switch (result) {
      case Ok<OperatorDetection>(:final value):
        final found = value.operator;
        _detectedPhone = value.phone;
        if (value.detected && found != null) {
          final listed = detail?.operator(found.id);
          final operator = listed ?? found;
          _detected = operator;
          _detectionStatus = AirtimeDetectionStatus.detected;
          _detectionReason = '';
          if (!_manualOperator) {
            _setOperator(operator, manual: false);
          }
        } else {
          _detected = null;
          _detectionReason = value.reason;
          _detectionStatus = switch (value.reason) {
            ServiceRefusalCode.invalidPhone =>
              AirtimeDetectionStatus.invalidNumber,
            ServiceRefusalCode.unavailable ||
            ServiceRefusalCode.notConfigured ||
            ServiceRefusalCode.switchedOff =>
              AirtimeDetectionStatus.unavailable,
            _ => AirtimeDetectionStatus.notDetected,
          };
        }
      case Error<OperatorDetection>():
        _detected = null;
        _detectionStatus = AirtimeDetectionStatus.failed;
    }
    notifyListeners();
  }

  // --- step 3: the amount ----------------------------------------------------------

  String? _amount;
  bool _customOpen = false;
  String _customText = '';
  int? _pendingOperatorId;
  String? _pendingAmount;

  /// The amount chosen, in the network's amount currency, as the relay writes
  /// it. Null until one is chosen — or typed validly.
  String? get amount => _amount;

  /// The tile for [amount] on the chosen network, if it has one.
  AirtimeAmount? get selectedTile {
    final operator = _operator;
    final amount = _amount;
    return operator == null || amount == null
        ? null
        : operator.amountFor(amount);
  }

  /// The "another amount" field is open.
  bool get isCustomOpen => _customOpen;
  String get customText => _customText;

  /// What is wrong with the amount typed, if anything.
  ServiceAmountProblem? get customProblem {
    final operator = _operator;
    if (!_customOpen || operator == null || _customText.trim().isEmpty) {
      return null;
    }
    final value = parseTypedAmount(_customText);
    if (value == null) {
      return ServiceAmountProblem.invalid;
    }
    final min = operator.min;
    final max = operator.max;
    if (min != null && value < min) {
      return ServiceAmountProblem.belowMin;
    }
    if (max != null && value > max) {
      return ServiceAmountProblem.aboveMax;
    }
    return null;
  }

  /// Picks one of the network's own amounts.
  void selectAmount(AirtimeAmount tile) {
    _amount = tile.amount;
    _customOpen = false;
    _customText = '';
    _requote(immediate: true);
    notifyListeners();
  }

  /// Opens the field for an amount of the cashier's own.
  void openCustomAmount() {
    if (_customOpen) {
      return;
    }
    _customOpen = true;
    if (selectedTile != null || _amount == null) {
      _amount = null;
      _customText = '';
    }
    _requote(immediate: true);
    notifyListeners();
  }

  /// The custom field changed.
  void setCustomAmount(String typed) {
    _customOpen = true;
    _customText = typed;
    _amount = customProblem == null && typed.trim().isNotEmpty
        ? canonicalAmountText(typed)
        : null;
    _requote();
    notifyListeners();
  }

  void _clearAmount() {
    _amount = null;
    _customOpen = false;
    _customText = '';
  }

  /// A change of network keeps the amount when the new one takes it too.
  void _keepAmountIfOffered() {
    final operator = _operator;
    final amount = _amount;
    if (operator == null || amount == null) {
      return;
    }
    final value = double.tryParse(amount) ?? 0;
    if (operator.amountFor(amount) != null) {
      _customOpen = false;
      _customText = '';
      return;
    }
    if (operator.takesCustomAmount && operator.accepts(value)) {
      _customOpen = true;
      _customText = amount;
      return;
    }
    _clearAmount();
  }

  void _applyPendingAmount() {
    final operator = _operator;
    final amount = _pendingAmount;
    if (operator == null || amount == null) {
      return;
    }
    final tile = operator.amountFor(amount);
    if (tile != null) {
      _amount = tile.amount;
      _customOpen = false;
      _customText = '';
    } else if (operator.takesCustomAmount &&
        operator.accepts(double.tryParse(amount) ?? 0)) {
      _amount = amount;
      _customOpen = true;
      _customText = formatForeignAmountText(amount);
    }
  }

  // --- pricing ----------------------------------------------------------------------

  ServiceQuoteRequest? _buildRequest() {
    final country = _country;
    final operator = _operator;
    final amount = _amount;
    if (country == null ||
        operator == null ||
        amount == null ||
        _internationalPending ||
        !hasPlausibleNumber ||
        detail == null) {
      return null;
    }
    return ServiceQuoteRequest.airtime(
      country: country.code,
      operatorId: operator.id,
      phone: _national,
      amount: amount,
      amountCurrency: operator.amountCurrency,
    );
  }

  void _requote({bool immediate = false, bool force = false}) {
    quote.ask(_buildRequest(), immediate: immediate, force: force);
  }

  /// The server's price for what is on screen; null while there is none.
  ServiceQuote? get readyQuote => quote.ready;

  /// The first thing still missing before the line can go in the cart, or null
  /// when it can.
  ServiceBlocker? get blocker {
    // A number pasted with a code several countries share comes before
    // everything: no other step is meaningful until it is known whose it is.
    if (_dialChoices.isNotEmpty) {
      return const ServiceBlocker(ServiceBlockReason.chooseDialCountry);
    }
    final country = _country;
    if (country == null) {
      return const ServiceBlocker(ServiceBlockReason.noCountry);
    }
    if (detail == null) {
      return ServiceBlocker(
        isLoadingCountry
            ? ServiceBlockReason.loadingCountry
            : ServiceBlockReason.countryFailed,
      );
    }
    if (_national.isEmpty || _internationalPending) {
      return const ServiceBlocker(ServiceBlockReason.noNumber);
    }
    if (!hasPlausibleNumber) {
      return ServiceBlocker(
        PhoneEntry.isTooLong(dial: country.primaryDial, national: _national)
            ? ServiceBlockReason.numberTooLong
            : ServiceBlockReason.numberTooShort,
      );
    }
    // The relay's verdict on the digits comes before anything else: no
    // network or amount makes a wrong number right.
    if (_detectionStatus == AirtimeDetectionStatus.invalidNumber) {
      return const ServiceBlocker(ServiceBlockReason.numberInvalid);
    }
    if (_operator == null) {
      return const ServiceBlocker(ServiceBlockReason.noNetwork);
    }
    if (_amount == null) {
      return switch (customProblem) {
        ServiceAmountProblem.invalid => const ServiceBlocker(
          ServiceBlockReason.amountInvalid,
        ),
        ServiceAmountProblem.belowMin => ServiceBlocker(
          ServiceBlockReason.amountBelowMin,
          min: _operator!.min,
          max: _operator!.max,
        ),
        ServiceAmountProblem.aboveMax => ServiceBlocker(
          ServiceBlockReason.amountAboveMax,
          min: _operator!.min,
          max: _operator!.max,
        ),
        null => const ServiceBlocker(ServiceBlockReason.noAmount),
      };
    }
    return switch (quote.status) {
      ServiceQuoteStatus.ready =>
        numberMismatch
            ? const ServiceBlocker(ServiceBlockReason.numberMismatch)
            : null,
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

  // --- recent recipients ---------------------------------------------------------------

  List<RecentRecipient> _recents = const [];
  bool _recentsLoaded = false;

  List<RecentRecipient> get recents => _recents;

  /// Reads the recipients sold to lately, once per shift unless [force].
  Future<void> loadRecents({bool force = false}) async {
    if (_recentsLoaded && !force) {
      return;
    }
    _recentsLoaded = true;
    final result = await _repository.loadServiceRecents(ServiceKind.airtime);
    if (_disposed) {
      return;
    }
    switch (result) {
      case Ok<List<RecentRecipient>>(:final value):
        _recents = List.unmodifiable(value);
        notifyListeners();
      case Error<List<RecentRecipient>>():
        // A repeat customer is a convenience, not a need: try again next time.
        _recentsLoaded = false;
    }
  }

  /// One tap on a recent recipient: their country, number and network, and
  /// the amount too when the network still offers it.
  void useRecent(RecentRecipient recipient) {
    final directory = _catalog.directory;
    final country = directory?.country(recipient.country);
    if (country == null) {
      return;
    }
    final search = _catalog.airtimeSearch;
    final digits = digitsOnly(recipient.phone);
    var national = digits;
    if (search != null) {
      final parse = PhoneEntry.parse(
        recipient.phone.startsWith('+') ? recipient.phone : '+$digits',
        directory: search,
        current: country,
      );
      if (parse.country?.code == country.code) {
        national = parse.national;
      }
    }
    final sameCountry = _country?.code == country.code;
    _forgetDialChoices();
    _national = national;
    _internationalPending = false;
    _unknownPrefix = false;
    phoneRevision++;
    if (!sameCountry) {
      _pendingOperatorId = recipient.operatorId;
      _pendingAmount = recipient.amount;
      selectCountry(country);
      return;
    }
    _clearAmount();
    final operator = detail?.operator(recipient.operatorId);
    _pendingAmount = recipient.amount;
    if (operator != null) {
      _operator = operator;
      _manualOperator = true;
      _applyPendingAmount();
    }
    _pendingAmount = null;
    _afterNumberOrCountryChange();
    _requote(immediate: true);
    notifyListeners();
  }

  // --- after the line is in the cart -------------------------------------------------------

  /// Bumped when the form goes back to the number, so the field takes focus.
  int focusRevision = 0;

  /// Asks the number field to take focus: a country was just chosen.
  void requestPhoneFocus() {
    focusRevision++;
    notifyListeners();
  }

  /// Bumped when the amounts should take focus: Enter ended the number.
  int amountFocusRevision = 0;

  /// What Enter does in the number field, given what is chosen so far: the
  /// next thing still to be done, or — when nothing is — the add itself.
  AirtimeEnter get enterInNumber {
    if (canAdd) {
      return AirtimeEnter.add;
    }
    final operator = _operator;
    if (operator == null || _internationalPending || !hasPlausibleNumber) {
      return AirtimeEnter.stay;
    }
    if (_customOpen) {
      return AirtimeEnter.focusAmount;
    }
    if (_amount != null) {
      return AirtimeEnter.stay;
    }
    return operator.takesCustomAmount
        ? AirtimeEnter.openCustomAmount
        : AirtimeEnter.focusAmount;
  }

  /// Takes the keyboard to the amounts: the field when it is open, the first
  /// tile otherwise.
  void requestAmountFocus() {
    amountFocusRevision++;
    notifyListeners();
  }

  /// Prices what is on screen at once, without waiting out the pause after the
  /// last keystroke.
  void priceNow() => quote.flush();

  /// The line is in the cart: the form goes back to the number, keeping the
  /// country, and the recipient is at the front of the recents.
  void afterAdded() {
    final added = quote.ready;
    final country = _country;
    final operator = _operator;
    final amount = _amount;
    if (added != null &&
        country != null &&
        operator != null &&
        amount != null) {
      _recents = List.unmodifiable(
        [
          RecentRecipient(
            phone: added.subscriberRef,
            country: country.code,
            operatorId: operator.id,
            operatorName: operator.name,
            amount: amount,
            currency: operator.amountCurrency,
            at: DateTime.now(),
          ),
          for (final recent in _recents)
            if (recent.phone != added.subscriberRef) recent,
        ].take(12),
      );
    }
    _national = '';
    _internationalPending = false;
    _unknownPrefix = false;
    _forgetDialChoices();
    phoneRevision++;
    focusRevision++;
    _detected = null;
    _detectedPhone = null;
    _detectionStatus = AirtimeDetectionStatus.idle;
    _detectionReason = '';
    _detectSequence++;
    _detectTimer?.cancel();
    _operator = null;
    _manualOperator = false;
    _clearAmount();
    quote.clear();
    final loaded = detail;
    if (loaded != null && loaded.operators.length == 1) {
      _operator = loaded.operators.single;
    }
    notifyListeners();
  }

  /// Forgets the recipients read — they were somebody else's customers.
  void forgetRecents() {
    _recents = const [];
    _recentsLoaded = false;
    notifyListeners();
  }

  /// Reads the directory and this country again — the list the screen was
  /// built on is out of date — and keeps what the cashier chose when it is
  /// still offered.
  Future<void> refreshList() async {
    final country = _country;
    await _catalog.reload();
    if (country != null) {
      await _catalog.loadDetail(country.code, force: true);
    }
    if (_disposed) {
      return;
    }
    final fresh = detail;
    final chosen = _operator;
    if (chosen != null && fresh != null) {
      final again = fresh.operator(chosen.id);
      if (again == null) {
        _operator = null;
        _manualOperator = false;
        _clearAmount();
        quote.clear();
      } else {
        _operator = again;
        _keepAmountIfOffered();
      }
    }
    _requote(immediate: true, force: true);
    notifyListeners();
  }

  /// Forgets everything, the country too.
  void reset() {
    _country = null;
    _national = '';
    _internationalPending = false;
    _unknownPrefix = false;
    _forgetDialChoices();
    phoneRevision++;
    _detected = null;
    _detectedPhone = null;
    _operator = null;
    _manualOperator = false;
    _detectionStatus = AirtimeDetectionStatus.idle;
    _detectSequence++;
    _detectTimer?.cancel();
    _clearAmount();
    quote.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _detectTimer?.cancel();
    _catalog.removeListener(_onCatalogChanged);
    quote.removeListener(notifyListeners);
    quote.dispose();
    super.dispose();
  }
}
