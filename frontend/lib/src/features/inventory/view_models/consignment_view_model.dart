import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/consignment.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/consignment_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../pdf/consignment_pdf.dart';

/// مستحقات الأمانات, and the position behind it.
///
/// Holds no money of its own: the payable, the commission and the custody
/// exposure all arrive computed, and every action here re-reads rather than
/// adjusting a local number. A screen that decremented its own total after a
/// payout would be a screen that can disagree with the drawer.
class ConsignmentViewModel extends ChangeNotifier {
  ConsignmentViewModel(
    this._repository, {
    ShopSettingsRepository? shopSettingsRepository,
    PrintingRepository? printingRepository,
    ConsignmentDocumentPdfService documents =
        const ConsignmentDocumentPdfService(),
  }) : _shopSettings = shopSettingsRepository,
       _printingRepository = printingRepository,
       _documents = documents;

  final ConsignmentRepository _repository;
  final ShopSettingsRepository? _shopSettings;

  /// Sends the vouchers to this device's documents printer when one is set.
  final PrintingRepository? _printingRepository;
  final ConsignmentDocumentPdfService _documents;

  ConsignmentPayablePage _payables = const ConsignmentPayablePage();
  ConsignmentPosition _position = const ConsignmentPosition();
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isDisbursing = false;
  bool _hasError = false;
  int _page = 1;
  String _search = '';
  final Set<int> _selected = <int>{};

  /// The rows as the server answered them.
  ///
  /// Deliberately not filtered here any more. The list is paged, so a
  /// client-side filter searches the page it happens to be holding — which
  /// answers "سالم is owed nothing" for a consignor whose row is on page three,
  /// and is the worst possible wrong answer on a screen about money owed to
  /// people. The search goes to the server with the query.
  List<ConsignmentPayable> get payables => _payables.rows;

  ConsignmentPosition get position => _position;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMore => _payables.hasNext;
  bool get isDisbursing => _isDisbursing;
  bool get hasError => _hasError;
  bool get isEmpty => _payables.isEmpty;
  String get search => _search;
  double get totalDue => _payables.totalDue;

  Set<int> get selected => Set.unmodifiable(_selected);

  /// What the selected rows come to. One consignor collecting for three of
  /// their articles signs one voucher, so the screen adds them up before the
  /// drawer opens rather than after.
  double get selectedTotal {
    var total = 0.0;
    for (final row in _payables.rows) {
      if (_selected.contains(row.unitId)) {
        total += row.payoutDue;
      }
    }
    return total;
  }

  /// A voucher covers one consignor. Selecting a second one's article is not a
  /// mistake worth a dialog — it simply cannot be paid on the same page.
  bool get selectionIsOneConsignor {
    final owners = <int?>{};
    for (final row in _payables.rows) {
      if (_selected.contains(row.unitId)) {
        owners.add(row.consignorId);
      }
    }
    return owners.length <= 1;
  }

  bool get canDisburse =>
      _selected.isNotEmpty && selectionIsOneConsignor && !_isDisbursing;

  Future<void> load() async {
    _isLoading = true;
    _page = 1;
    notifyListeners();
    final results = await Future.wait([
      _repository.loadPayables(page: _page, search: _search),
      _repository.loadPosition(),
    ]);
    switch (results[0]) {
      case Ok<ConsignmentPayablePage>(:final value):
        _payables = value;
        _hasError = false;
        _selected.removeWhere(
          (id) => !value.rows.any((row) => row.unitId == id),
        );
      case Error<ConsignmentPayablePage>():
        _hasError = true;
      default:
        break;
    }
    if (results[1] case Ok<ConsignmentPosition>(:final value)) {
      _position = value;
    }
    _isLoading = false;
    notifyListeners();
  }

  /// The next page, appended.
  ///
  /// The same guard the units list needed: the scroll extent that asks for this
  /// fires again while the request is still in flight, and a failed page must
  /// not look like the end of the list — a consignment dealer with fifty unpaid
  /// articles has a fifty-first, and silently losing it is how somebody is
  /// never paid.
  Future<void> loadMore() async {
    if (_isLoadingMore || _isLoading || !_payables.hasNext) {
      return;
    }
    _isLoadingMore = true;
    notifyListeners();
    final result = await _repository.loadPayables(
      page: _page + 1,
      search: _search,
    );
    switch (result) {
      case Ok<ConsignmentPayablePage>(:final value):
        _page += 1;
        _payables = ConsignmentPayablePage(
          rows: [..._payables.rows, ...value.rows],
          // The headline is the shop's whole liability, so it comes from the
          // server rather than being re-added up from the rows on screen.
          totalDue: value.totalDue,
          count: value.count,
          hasNext: value.hasNext,
        );
        _hasError = false;
      case Error<ConsignmentPayablePage>():
        _hasError = true;
    }
    _isLoadingMore = false;
    notifyListeners();
  }

  void setSearch(String term) {
    final trimmed = term.trim();
    if (_search == trimmed) {
      return;
    }
    _search = trimmed;
    _selected.clear();
    unawaited(load());
  }

  void toggle(ConsignmentPayable row) {
    if (!_selected.remove(row.unitId)) {
      // Picking a different consignor replaces the selection rather than
      // refusing it: the cashier has moved on to the next person at the
      // counter, and making them clear the last one first is friction for
      // nothing.
      if (_selected.isNotEmpty && !_sameConsignor(row)) {
        _selected.clear();
      }
      _selected.add(row.unitId);
    }
    notifyListeners();
  }

  bool _sameConsignor(ConsignmentPayable row) {
    for (final existing in _payables.rows) {
      if (_selected.contains(existing.unitId)) {
        return existing.consignorId == row.consignorId;
      }
    }
    return true;
  }

  void selectAllFor(ConsignmentPayable row) {
    _selected
      ..clear()
      ..addAll([
        for (final other in _payables.rows)
          if (other.consignorId == row.consignorId) other.unitId,
      ]);
    notifyListeners();
  }

  void clearSelection() {
    if (_selected.isEmpty) {
      return;
    }
    _selected.clear();
    notifyListeners();
  }

  /// Hand over the money. Returns the voucher, or null when it was refused —
  /// the caller shows the reason, because a refusal here is usually "no open
  /// till", which is a thing the cashier can fix.
  Future<ConsignorPayout?> disburse({String method = 'cash'}) async {
    if (!canDisburse) {
      return null;
    }
    _isDisbursing = true;
    notifyListeners();
    final ids = _selected.toList()..sort();
    final result = await _repository.disburse(
      unitId: ids.first,
      alsoUnitIds: ids.skip(1).toList(growable: false),
      method: method,
    );
    _isDisbursing = false;
    switch (result) {
      case Ok<ConsignorPayout>(:final value):
        _selected.clear();
        unawaited(load());
        return value;
      case Error<ConsignorPayout>():
        notifyListeners();
        return null;
    }
  }

  /// Print *سند استلام أمانة* — the page both parties sign.
  ///
  /// The clause on it is the one stored when the voucher was submitted, printed
  /// verbatim. A shop that rewords its template next year has not reworded this
  /// page, and printing the live template instead would quietly make that
  /// untrue.
  Future<bool> printVoucher(ConsignmentAgreement agreement) async {
    final settings = await _loadShopSettings();
    return _documents.printVoucher(
      agreement: agreement,
      units: agreement.units,
      shopSettings: settings,
      shopLogoBytes: await _loadShopLogoBytes(settings),
      printingRepository: _printingRepository,
    );
  }

  /// Print *سند صرف أمانة* — the receipt for money handed across the counter.
  Future<bool> printPayout(ConsignorPayout payout) async {
    final settings = await _loadShopSettings();
    return _documents.printPayout(
      payout: payout,
      shopSettings: settings,
      shopLogoBytes: await _loadShopLogoBytes(settings),
      printingRepository: _printingRepository,
    );
  }

  Future<ShopSettings?> _loadShopSettings() async {
    final repository = _shopSettings;
    if (repository == null) {
      return null;
    }
    final result = await repository.loadSettings();
    return switch (result) {
      Ok<ShopSettings>(value: final settings) => settings,
      Error<ShopSettings>() => null,
    };
  }

  Future<Uint8List?> _loadShopLogoBytes(ShopSettings? settings) async {
    final repository = _shopSettings;
    if (repository == null) {
      return null;
    }
    final result = await repository.loadLogoBytes(settings);
    return switch (result) {
      Ok<Uint8List?>(value: final bytes) => bytes,
      Error<Uint8List?>() => null,
    };
  }

  Future<bool> resendSms(ConsignmentPayable row) async {
    final result = await _repository.resendSaleSms(row.unitId);
    return result is Ok<bool> && result.value;
  }
}
