import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/integration_card.dart';
import '../../../data/models/integration_provider.dart';
import '../../../data/repositories/integrations_repository.dart';
import '../../../data/services/integrations_api_client.dart';

/// Where the lookup has got to. Kept explicit rather than inferred from nulls
/// because "not looked up yet" and "looked up and not found" are different
/// things to a cashier with a customer waiting.
enum RechargeLookupState { idle, searching, found, refused, failed }

/// Drives the till's top-up flow for one provider: find a subscriber, show
/// what shape their subscription is in, page through what they have bought
/// before, and pick what to sell them.
///
/// It never buys anything. The flow ends by handing the POS an
/// [IntegrationRechargeDraft]; performing the top-up at the provider is a
/// separate, later step, and the cart line says so.
class IntegrationRechargeViewModel extends ChangeNotifier {
  IntegrationRechargeViewModel({
    required IntegrationsRepository repository,
    required this.provider,
  }) : _repository = repository;

  final IntegrationsRepository _repository;
  final IntegrationProviderKey provider;

  String get providerKey => integrationProviderKeyToJson(provider);

  RechargeLookupState _lookupState = RechargeLookupState.idle;
  String _cardNo = '';
  IntegrationCardSnapshot? _snapshot;
  String _refusalCode = '';
  Exception? _failure;
  IntegrationOffer? _selectedOffer;

  IntegrationHistoryKind _historyKind = IntegrationHistoryKind.purchases;
  IntegrationHistoryPage? _historyPage;
  bool _isHistoryLoading = false;
  static const int historyPageSize = 10;

  RechargeLookupState get lookupState => _lookupState;
  String get cardNo => _cardNo;
  IntegrationCardSnapshot? get snapshot => _snapshot;

  /// The identifier the LINE is known by, which is not always what was typed.
  ///
  /// A cashier searches LNET by phone number and the line's own identifier is
  /// a username the search merely found; for HD Box the two are the same
  /// string. Everything that addresses the line afterwards — its history, its
  /// cart line, naming its owner — belongs to this, and only the search
  /// itself belongs to [cardNo]. Falls back to what was typed while there is
  /// no resolved line yet (a search still running, or several still on offer).
  String get _resolvedCardNo {
    final resolved = _snapshot?.card.cardNo ?? '';
    return resolved.isEmpty ? _cardNo : resolved;
  }

  /// The provider's own reason for saying no, as a stable code.
  String get refusalCode => _refusalCode;

  /// A failed *request* — network, permission — as opposed to a refusal.
  Exception? get failure => _failure;

  IntegrationOffer? get selectedOffer => _selectedOffer;
  IntegrationHistoryKind get historyKind => _historyKind;
  IntegrationHistoryPage? get historyPage => _historyPage;
  bool get isHistoryLoading => _isHistoryLoading;

  bool get isSearching => _lookupState == RechargeLookupState.searching;
  bool get hasCard => _snapshot != null;

  /// Durations and top-up amounts — never a package switch. Moving a
  /// subscriber between packages is deliberately not offered: the provider
  /// hides it in its own form, the agency does not do it, and a mis-tap would
  /// put a customer on the wrong package and break their card. The backend
  /// does not send them either — this is the second lock on the same door.
  List<IntegrationOffer> get sellableOffers =>
      _snapshot?.offers
          .where((offer) => offer.isRenewal || offer.isTopUp)
          .toList() ??
      const [];

  /// True when the cashier may type an amount instead of only tapping one.
  bool get allowsCustomAmount => _snapshot?.allowsOpenAmount ?? false;

  IntegrationOpenAmount? get openAmount => _snapshot?.openAmount;

  /// Whether this provider keeps a state log worth a tab of its own.
  bool get hasStatusHistory => _snapshot?.hasStatusHistory ?? true;

  /// The lines this search matched, when it matched more than one.
  List<IntegrationCardInfo> get candidates => _snapshot?.candidates ?? const [];

  /// True while the cashier still has to say which line they mean. Nothing is
  /// priced and nothing may be added to a cart until they do.
  bool get needsLineSelection => _snapshot?.needsSelection ?? false;

  /// What the cashier typed, when they typed an amount rather than tapping
  /// one. Kept so the field and the selection cannot disagree.
  double? _customAmount;
  double? get customAmount => _customAmount;

  /// Why the typed amount cannot be sold, or null when it can.
  IntegrationAmountProblem? get customAmountProblem {
    final spec = openAmount;
    final amount = _customAmount;
    if (spec == null || amount == null) return null;
    return spec.validate(amount);
  }

  /// Price a typed amount and select it, or clear the selection.
  ///
  /// The result is an ordinary [IntegrationOffer], so the cart, the draft and
  /// the server all see the same shape whether the cashier tapped 45 or typed
  /// it. An amount the provider would refuse selects nothing rather than
  /// quoting a number that cannot be bought.
  void setCustomAmount(double? amount) {
    final spec = openAmount;
    _customAmount = amount;
    if (spec == null || amount == null || spec.validate(amount) != null) {
      _selectedOffer = null;
      notifyListeners();
      return;
    }
    _selectedOffer = spec.offerFor(
      amount,
      packageName: _snapshot?.card.packageName ?? '',
    );
    notifyListeners();
  }

  /// Narrow a multi-line result to the one the cashier picked.
  ///
  /// Re-runs the lookup against that line's own identifier rather than
  /// trusting the row we already have: the offers, and the confirmation that
  /// this line can be topped up at all, only exist for a single line.
  Future<void> selectLine(IntegrationCardInfo line) => lookup(line.cardNo);

  /// True when the float cannot cover the selected top-up. Advisory: the sale
  /// is still recorded, and the shop tops the float up separately — but a
  /// cashier should know before the customer pays.
  bool get exceedsBalance {
    final offer = _selectedOffer;
    final balance = _snapshot?.balance;
    if (offer == null || balance == null) return false;
    return offer.cost > balance;
  }

  void selectOffer(IntegrationOffer? offer) {
    if (_selectedOffer?.code == offer?.code) return;
    _selectedOffer = offer;
    // Tapping a quick-pick retires whatever was typed, so the amount field
    // cannot keep claiming a number that is no longer what will be sold.
    _customAmount = null;
    notifyListeners();
  }

  void reset() {
    _lookupState = RechargeLookupState.idle;
    _cardNo = '';
    _snapshot = null;
    _refusalCode = '';
    _failure = null;
    _selectedOffer = null;
    _customAmount = null;
    _historyPage = null;
    _historyKind = IntegrationHistoryKind.purchases;
    notifyListeners();
  }

  Future<void> lookup(String cardNo) async {
    final trimmed = cardNo.trim();
    if (trimmed.isEmpty) return;

    _cardNo = trimmed;
    _lookupState = RechargeLookupState.searching;
    _snapshot = null;
    _selectedOffer = null;
    _customAmount = null;
    _historyPage = null;
    _refusalCode = '';
    _failure = null;
    notifyListeners();

    final result = await _repository.lookupCard(
      providerKey: providerKey,
      cardNo: trimmed,
    );
    switch (result) {
      case Ok<IntegrationCardSnapshot>(value: final snapshot):
        _snapshot = snapshot;
        _lookupState = RechargeLookupState.found;
      // Preselect nothing: picking a duration is the cashier's decision and
      // a preselected one is the kind of default that gets sold by accident.
      case Error<IntegrationCardSnapshot>(exception: final exception):
        if (exception is IntegrationProviderRefusal) {
          _refusalCode = exception.errorCode;
          _lookupState = RechargeLookupState.refused;
        } else {
          _failure = exception;
          _lookupState = RechargeLookupState.failed;
        }
    }
    notifyListeners();

    // History is per line, so there is nothing to fetch while several are
    // still on offer — and the search term is not a line identifier.
    if (_lookupState == RechargeLookupState.found && !needsLineSelection) {
      await loadHistory();
    }
  }

  Future<void> showHistoryKind(IntegrationHistoryKind kind) {
    if (_historyKind == kind && _historyPage != null) {
      return Future<void>.value();
    }
    _historyKind = kind;
    _historyPage = null;
    notifyListeners();
    return loadHistory();
  }

  Future<void> loadHistory({int offset = 0}) async {
    if (_cardNo.isEmpty) return;
    _isHistoryLoading = true;
    notifyListeners();

    final result = await _repository.loadHistory(
      providerKey: providerKey,
      cardNo: _resolvedCardNo,
      kind: _historyKind,
      limit: historyPageSize,
      offset: offset,
    );
    switch (result) {
      case Ok<IntegrationHistoryPage>(value: final page):
        _historyPage = page;
      case Error<IntegrationHistoryPage>():
        _historyPage = IntegrationHistoryPage(
          ok: false,
          kind: _historyKind,
          errorCode: 'unexpected_response',
        );
    }
    _isHistoryLoading = false;
    notifyListeners();
  }

  Future<void> nextHistoryPage() {
    final page = _historyPage;
    if (page == null || !page.hasNext) return Future<void>.value();
    return loadHistory(offset: page.offset + page.limit);
  }

  Future<void> previousHistoryPage() {
    final page = _historyPage;
    if (page == null || !page.hasPrevious) return Future<void>.value();
    return loadHistory(offset: (page.offset - page.limit).clamp(0, 1 << 30));
  }

  /// What the POS should add to the cart, or null if nothing is chosen yet.
  ///
  /// The selling price is deliberately absent: the server computes it from the
  /// shop's markup setting, because apps.sales never trusts a price that came
  /// from a till.
  IntegrationRechargeDraft? buildDraft() {
    final snapshot = _snapshot;
    final offer = _selectedOffer;
    if (snapshot == null || offer == null) return null;
    return IntegrationRechargeDraft(
      provider: provider,
      serviceVariant: snapshot.serviceVariant,
      subscriberRef: _resolvedCardNo,
      offer: offer,
      price: offer.price,
    );
  }

  /// Name the person behind this card.
  ///
  /// The provider will not tell us who it is — HD Box masks the subscriber —
  /// so a card stays anonymous until somebody at the till says otherwise,
  /// and an anonymous card is a renewal nobody can remind anyone about.
  Future<bool> identifySubscriber({
    int? customerId,
    String? displayName,
  }) async {
    final snapshot = _snapshot;
    if (snapshot == null) return false;

    final result = await _repository.identifySubscriber(
      providerKey,
      _resolvedCardNo,
      customerId: customerId,
      displayName: displayName,
    );
    switch (result) {
      case Ok<IntegrationSubscriber>(value: final subscriber):
        _snapshot = IntegrationCardSnapshot(
          card: snapshot.card,
          offers: snapshot.offers,
          serviceVariant: snapshot.serviceVariant,
          subscriber: subscriber,
          currency: snapshot.currency,
          balance: snapshot.balance,
          offersErrorCode: snapshot.offersErrorCode,
          openAmount: snapshot.openAmount,
          candidates: snapshot.candidates,
          needsSelection: snapshot.needsSelection,
          historyKinds: snapshot.historyKinds,
        );
        notifyListeners();
        return true;
      case Error<IntegrationSubscriber>(exception: final exception):
        _failure = exception;
        notifyListeners();
        return false;
    }
  }
}
