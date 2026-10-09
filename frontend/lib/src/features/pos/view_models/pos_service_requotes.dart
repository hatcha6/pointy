part of 'pos_view_model.dart';

/// A direct-service line the server priced again, and what it answered.
///
/// Either [quote] — the line as it would be sold now, at a price that moved —
/// or [refusal]: the server no longer offers it.
class ServiceRequote {
  const ServiceRequote({required this.line, this.quote, this.refusal});

  final CartLine line;
  final ServiceQuote? quote;
  final ServiceQuoteRefusal? refusal;

  /// The offer is gone: there is no new price to accept.
  bool get isRefused => quote == null;

  double get oldPrice => line.unitPrice;
  double? get newPrice => quote?.price;
}

/// What the till has to put in front of the cashier about service lines that
/// were priced again while nobody was looking — a held invoice that came back,
/// the way a scan that names a handset is put in front of them to pick.
class ServiceRequoteQueue extends ChangeNotifier {
  final List<ServiceRequote> _pending = [];

  bool get hasPending => _pending.isNotEmpty;

  void add(Iterable<ServiceRequote> changes) {
    if (changes.isEmpty) {
      return;
    }
    _pending.addAll(changes);
    notifyListeners();
  }

  /// Everything waiting, once.
  List<ServiceRequote> take() {
    final taken = List<ServiceRequote>.of(_pending);
    _pending.clear();
    return taken;
  }
}

extension PosServiceRequotes on PosViewModel {
  /// A direct-service line whose quote is old enough to be asked about again,
  /// and which kept the request it was priced from.
  bool _isStaleServiceLine(CartLine line, DateTime now) {
    final integration = line.integration;
    if (integration == null ||
        !integration.isDirectService ||
        integration.quoteRequest == null) {
      return false;
    }
    final at = integration.quotedAt;
    return at == null || now.difference(at) >= _serviceQuoteFreshFor;
  }

  /// Prices every old-enough direct-service line of the active invoice again,
  /// with the request it was first priced from.
  ///
  /// A line whose price did not move is quietly given its fresh quote. A price
  /// that moved, or an offer the server no longer makes, is returned for the
  /// cashier to decide: nothing is changed behind their back. A server that
  /// cannot be asked changes nothing — the charge itself refuses any amount
  /// other than the one quoted, so a moved price is caught there at worst.
  Future<List<ServiceRequote>> requoteServiceLines() async {
    final repository = _integrationsRepository;
    if (repository == null) {
      return const [];
    }
    final session = _activeSaleSession;
    final now = DateTime.now();
    final stale = [
      for (final line in session.cart)
        if (_isStaleServiceLine(line, now)) line,
    ];
    final changes = <ServiceRequote>[];
    for (final line in stale) {
      final request = ServiceQuoteRequest.fromJson(
        line.integration!.quoteRequest!,
      );
      final result = await repository.quoteService(request);
      if (_disposed) {
        return const [];
      }
      if (result case Ok<ServiceQuoteOutcome>(:final value)) {
        final fresh = value.quote;
        if (fresh != null) {
          final same =
              (fresh.price - line.unitPrice).abs() < 0.005 &&
              fresh.optionCode == line.integration!.optionCode &&
              fresh.subscriberRef == line.integration!.subscriberRef;
          if (same) {
            _replaceServiceLine(line, fresh.withRequest(request));
          } else {
            changes.add(
              ServiceRequote(line: line, quote: fresh.withRequest(request)),
            );
          }
        } else if (value.refusal case final refusal?
            when !refusal.isTransient) {
          changes.add(ServiceRequote(line: line, refusal: refusal));
        }
      }
    }
    return changes;
  }

  /// Puts the line's new quote in: its price, its sealed token, its age.
  void acceptServiceRequote(ServiceRequote change) {
    final quote = change.quote;
    if (quote == null) {
      return;
    }
    _replaceServiceLine(change.line, quote);
    unawaited(refreshDiscountPreview());
  }

  /// Takes a line whose offer is gone out of the invoice.
  void dropServiceRequote(ServiceRequote change) {
    removeCartLine(change.line.lineKey, source: 'service_requote_dropped');
  }

  /// Gives the line [quote] as its own: same line, new price and seal.
  void _replaceServiceLine(CartLine line, ServiceQuote quote) {
    for (final session in _saleSessions) {
      final index = session.cart.indexWhere(
        (candidate) => candidate.lineKey == line.lineKey,
      );
      if (index == -1) {
        continue;
      }
      final current = session.cart[index];
      session.cart[index] = CartLine(
        variant: current.variant.copyWith(unitPrice: quote.price),
        quantity: current.quantity,
        notes: current.notes,
        integration: current.integration!.requoted(
          subscriberRef: quote.subscriberRef,
          optionCode: quote.optionCode,
          optionLabel: quote.optionLabel,
          quote: quote.quote,
          quotedAt: DateTime.now(),
          quoteRequest: quote.request?.toJson(),
        ),
        lineKey: current.lineKey,
      );
      _touchActiveSaleSession();
      _notifyChanged();
      return;
    }
  }

  /// Forgets what one cashier or one shift left on the services: the airtime
  /// form, the recent recipients, the directory, and any price waiting to be
  /// shown. Called when somebody signs out, a different user signs in, or a
  /// new shift begins.
  void resetServiceState() {
    _serviceShelves?.reset();
    serviceRequotes.take();
  }

  /// A held invoice came back (restored, or switched to): its service lines
  /// are priced again in the background, and what moved is queued for the
  /// cashier. Never throws, never blocks.
  void _scheduleServiceRequote() {
    if (_integrationsRepository == null) {
      return;
    }
    final sessionId = _activeSaleSessionId;
    unawaited(() async {
      final changes = await requoteServiceLines();
      // They moved to another invoice while it was asked: not the one the
      // cashier is looking at any more.
      if (!_disposed && sessionId == _activeSaleSessionId) {
        serviceRequotes.add(changes);
      }
    }());
  }
}
