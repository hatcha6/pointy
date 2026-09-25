import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/portal_payment.dart';
import '../../../data/repositories/integrations_repository.dart';

/// One provider's website payments for a day, and recording them as sales.
///
/// Everything that decides whether a payment may be recorded — whether it is
/// really done, whether a sale already accounts for it, whether a drawer can
/// have held its cash — is the server's call and arrives as a state. This
/// only keeps the day on screen, and turns a refusal into something the sheet
/// can say.
class PortalPaymentsViewModel extends ChangeNotifier {
  PortalPaymentsViewModel(
    this._repository, {
    required this.providerKey,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _date = _dayOf(_clock());
  }

  final IntegrationsRepository _repository;
  final String providerKey;
  final DateTime Function() _clock;

  late DateTime _date;
  PortalPaymentsDay? _day;
  Exception? _failure;
  bool _isLoading = false;
  bool _isSubmitting = false;
  bool _showAll = false;

  /// Bumped per load, so a slow answer for a day the manager has already left
  /// cannot overwrite the day they moved to.
  int _generation = 0;

  DateTime get date => _date;
  PortalPaymentsDay? get day => _day;
  Exception? get failure => _failure;
  bool get isLoading => _isLoading;
  bool get isSubmitting => _isSubmitting;
  bool get showAll => _showAll;
  bool get isToday => _date == _dayOf(_clock());

  /// What the list shows: everything, or only what still needs an invoice.
  List<PortalPayment> get visiblePayments {
    final payments = _day?.payments ?? const <PortalPayment>[];
    if (_showAll) return payments;
    return payments
        .where((payment) => payment.state.needsRecording)
        .toList(growable: false);
  }

  /// Read the day. [refresh] false answers from the server's copy of the
  /// provider's report without reading the provider again — right after a
  /// write, when nothing but Pointy's side has moved.
  Future<void> load({bool refresh = true}) async {
    final generation = ++_generation;
    _isLoading = true;
    _failure = null;
    notifyListeners();
    final result = await _repository.loadPortalPayments(
      providerKey,
      date: _date,
      refresh: refresh,
    );
    if (generation != _generation) return;
    switch (result) {
      case Ok<PortalPaymentsDay>(value: final day):
        _day = day;
      case Error<PortalPaymentsDay>(exception: final exception):
        _failure = exception;
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> setDate(DateTime date) {
    final day = _dayOf(date);
    if (day == _date && _day != null) return Future<void>.value();
    _date = day;
    _day = null;
    return load();
  }

  void setShowAll(bool value) {
    if (_showAll == value) return;
    _showAll = value;
    notifyListeners();
  }

  /// Issue the invoice for [payment]. On success the day is reloaded so the
  /// row moves to "recorded" with its invoice beside it.
  Future<Result<PortalPaymentOrder>> record(
    PortalPayment payment,
    PortalPaymentRecordDraft draft,
  ) {
    return _write(
      () => _repository.recordPortalPayment(
        providerKey,
        payment.reference,
        draft,
      ),
    );
  }

  /// [payment] is the top-up [candidate]'s sale was waiting for.
  Future<Result<PortalPaymentOrder>> link(
    PortalPayment payment,
    PortalPaymentCandidate candidate,
  ) {
    return _write(
      () => _repository.linkPortalPayment(
        providerKey,
        payment.reference,
        fulfillmentId: candidate.fulfillmentId,
      ),
    );
  }

  Future<Result<PortalPaymentOrder>> _write(
    Future<Result<PortalPaymentOrder>> Function() write,
  ) async {
    if (_isSubmitting) {
      // A second tap while the first is in flight. The server would refuse
      // it anyway — one payment is one sale — but it should never be asked.
      return Error(const PortalPaymentRefusal('busy'));
    }
    _isSubmitting = true;
    notifyListeners();
    final result = await write();
    _isSubmitting = false;
    notifyListeners();
    // Reloaded after a refusal too: "already recorded" and "no longer
    // verified" mean the row on screen is out of date either way.
    await load(refresh: false);
    return result;
  }

  static DateTime _dayOf(DateTime moment) =>
      DateTime(moment.year, moment.month, moment.day);
}
