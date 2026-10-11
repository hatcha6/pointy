import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/return_search.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../invoices/view_models/invoice_details_view_model.dart';

/// Builds the details view model for an invoice the desk opens.
typedef InvoiceDetailsFactory = InvoiceDetailsViewModel Function(SaleOrder);

/// The returns desk: one search box, then either the invoice it named or the
/// invoices and sold lines it can mean, then the invoice the cashier picks.
///
/// Every request carries a sequence number and a reply that is no longer the
/// latest is dropped — a slow search must never replace the invoice the
/// cashier has since opened, or swap results under their finger.
class ReturnsDeskViewModel extends ChangeNotifier {
  ReturnsDeskViewModel(
    this._saleRepository, {
    required InvoiceDetailsFactory detailsFactory,
  }) : _detailsFactory = detailsFactory;

  final SaleRepository _saleRepository;
  final InvoiceDetailsFactory _detailsFactory;

  int _requestSequence = 0;
  bool _disposed = false;

  String _query = '';
  bool _searching = false;
  ReturnSearchResult? _result;
  Exception? _searchFailure;

  /// The invoice on screen, when one is.
  InvoiceDetailsViewModel? _details;
  int? _preselectedLineId;

  /// Opening a picked result: which invoice, and whether it failed.
  int? _openingOrderId;
  Exception? _openFailure;

  String get query => _query;
  bool get isSearching => _searching;
  ReturnSearchResult? get result => _result;
  Exception? get searchFailure => _searchFailure;
  InvoiceDetailsViewModel? get details => _details;
  int? get preselectedLineId => _preselectedLineId;
  int? get openingOrderId => _openingOrderId;
  Exception? get openFailure => _openFailure;
  bool get isOpening => _openingOrderId != null;

  /// The open invoice came from a list of choices the cashier can go back to
  /// (a direct receipt hit has nothing to go back to).
  bool get canGoBackToResults {
    final result = _result;
    return _details != null &&
        result != null &&
        result.order == null &&
        !result.isEmpty;
  }

  /// Searches for [query]. A whole receipt number or the receipt's QR link
  /// opens that invoice straight away; anything else lists the choices.
  Future<void> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final request = ++_requestSequence;
    _query = trimmed;
    _searching = true;
    _searchFailure = null;
    _openFailure = null;
    _openingOrderId = null;
    _notify();

    final outcome = await _saleRepository.searchReturns(trimmed);
    if (_disposed || request != _requestSequence) {
      return;
    }
    _searching = false;
    switch (outcome) {
      case Ok<ReturnSearchResult>(value: final result):
        _result = result;
        final exact = result.order;
        _showDetails(exact, preselectedLineId: null);
      case Error<ReturnSearchResult>(exception: final exception):
        _result = null;
        _searchFailure = exception;
        _showDetails(null, preselectedLineId: null);
    }
    _notify();
  }

  /// Runs the last search again — the retry after a failure, and how the list
  /// catches up after a return changed what is left on its lines.
  Future<void> retry() => search(_query);

  /// Opens the invoice behind a listed invoice or sold line. The row is not
  /// the document: it is fetched whole (with its lines) before it is shown.
  Future<void> openInvoice(int orderId, {int? lineId}) async {
    final request = ++_requestSequence;
    _openingOrderId = orderId;
    _openFailure = null;
    _notify();

    final outcome = await _saleRepository.loadOrder(orderId);
    if (_disposed || request != _requestSequence) {
      return;
    }
    _openingOrderId = null;
    switch (outcome) {
      case Ok<SaleOrder>(value: final order):
        _showDetails(order, preselectedLineId: lineId);
      case Error<SaleOrder>(exception: final exception):
        _openFailure = exception;
    }
    _notify();
  }

  /// Leaves the open invoice for the list it was picked from, searching again
  /// so quantities a return just took are not offered twice.
  Future<void> backToResults() {
    _showDetails(null, preselectedLineId: null);
    _notify();
    return retry();
  }

  void dismissOpenFailure() {
    if (_openFailure == null) {
      return;
    }
    _openFailure = null;
    _notify();
  }

  void _showDetails(SaleOrder? order, {required int? preselectedLineId}) {
    _details?.dispose();
    _details = order == null ? null : _detailsFactory(order);
    _preselectedLineId = order == null ? null : preselectedLineId;
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _details?.dispose();
    super.dispose();
  }
}
