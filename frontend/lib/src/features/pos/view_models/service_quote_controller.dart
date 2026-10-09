import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/service_quote.dart';

enum ServiceQuoteStatus {
  /// Nothing to price yet.
  idle,

  /// A price is on its way.
  loading,

  /// The server priced it.
  ready,

  /// The server declined, and said why.
  refused,

  /// The server could not be reached.
  failed,
}

/// Asks the shop backend for the exact price of whatever the cashier has put
/// together so far, and holds the answer for exactly that request.
///
/// The price is never worked out on the till: it is the server's, sealed, and
/// the cart line carries it to checkout. So every change to the request asks
/// again — straight away for a tapped tile, after a short pause for an amount
/// being typed — and an answer to a request that was since replaced is dropped.
class ServiceQuoteController extends ChangeNotifier {
  ServiceQuoteController({
    required this.quote,
    this.debounce = const Duration(milliseconds: 400),
  });

  final Future<Result<ServiceQuoteOutcome>> Function(
    ServiceQuoteRequest request,
  )
  quote;

  /// The pause after the last change before an amount being typed is priced.
  final Duration debounce;

  ServiceQuoteStatus _status = ServiceQuoteStatus.idle;
  ServiceQuoteRequest? _request;
  ServiceQuote? _quote;
  ServiceQuoteRefusal? _refusal;
  Timer? _timer;
  int _sequence = 0;
  bool _disposed = false;

  ServiceQuoteStatus get status => _status;

  /// The request the current status answers.
  ServiceQuoteRequest? get request => _request;

  /// The price, once [status] is ready.
  ServiceQuote? get ready =>
      _status == ServiceQuoteStatus.ready ? _quote : null;

  ServiceQuoteRefusal? get refusal =>
      _status == ServiceQuoteStatus.refused ? _refusal : null;

  bool get isLoading => _status == ServiceQuoteStatus.loading;

  /// The last attempt did not get a price that asking again could not change:
  /// the server could not be reached, or refused for a reason that may pass.
  bool get _worthAskingAgain =>
      _status == ServiceQuoteStatus.failed ||
      (_status == ServiceQuoteStatus.refused &&
          (_refusal?.isTransient ?? false));

  /// Prices [next], or forgets the price when it is null. The same request
  /// again is not asked twice — unless the last attempt could not be answered
  /// or was refused for a reason that may pass (see [_worthAskingAgain]).
  ///
  /// [force] asks even then: what the answer depended on — the server's list —
  /// was read again since, so the same request may be answered differently.
  void ask(
    ServiceQuoteRequest? next, {
    bool immediate = false,
    bool force = false,
  }) {
    if (next == null) {
      clear();
      return;
    }
    if (!force && _request?.signature == next.signature && !_worthAskingAgain) {
      return;
    }
    _timer?.cancel();
    final sequence = ++_sequence;
    _request = next;
    _quote = null;
    _refusal = null;
    _status = ServiceQuoteStatus.loading;
    _notify();
    if (immediate || debounce == Duration.zero) {
      unawaited(_run(sequence, next));
    } else {
      _timer = Timer(debounce, () => unawaited(_run(sequence, next)));
    }
  }

  /// Asks now what is still waiting out its pause: the cashier pressed Enter
  /// and will not wait for the typing to be judged finished.
  void flush() {
    final request = _request;
    final timer = _timer;
    if (request == null || timer == null || !timer.isActive) {
      return;
    }
    timer.cancel();
    unawaited(_run(_sequence, request));
  }

  /// Asks again after a failure.
  void retry() {
    final last = _request;
    if (last != null) {
      _request = null;
      ask(last, immediate: true);
    }
  }

  /// Forgets any price and any pending question.
  void clear() {
    _timer?.cancel();
    _sequence++;
    final changed = _status != ServiceQuoteStatus.idle || _request != null;
    _request = null;
    _quote = null;
    _refusal = null;
    _status = ServiceQuoteStatus.idle;
    if (changed) {
      _notify();
    }
  }

  Future<void> _run(int sequence, ServiceQuoteRequest request) async {
    final result = await quote(request);
    if (_disposed || sequence != _sequence) {
      return;
    }
    switch (result) {
      case Ok<ServiceQuoteOutcome>(:final value):
        final priced = value.quote;
        if (priced != null) {
          _quote = priced.withRequest(request);
          _refusal = null;
          _status = ServiceQuoteStatus.ready;
        } else {
          _quote = null;
          _refusal = value.refusal;
          _status = ServiceQuoteStatus.refused;
        }
      case Error<ServiceQuoteOutcome>():
        _quote = null;
        _refusal = null;
        _status = ServiceQuoteStatus.failed;
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
