import 'package:flutter/foundation.dart';

import '../../../data/models/service_kinds.dart';
import '../../../data/repositories/integrations_repository.dart';
import 'airtime_view_model.dart';
import 'bill_flow_view_model.dart';
import 'services_catalog.dart';
import 'services_explainer_controller.dart';
import 'services_novelty_controller.dart';

/// Everything the till holds for «كروت دفتر»' direct services — airtime and
/// bills — for the length of the shift: the world they know, the airtime form
/// the cashier is half-way through, which explainers are hidden, and which
/// services are still new.
///
/// Held by the till's view model for the reason the voucher menu is: the
/// catalog pane is rebuilt whenever the window crosses the two-pane
/// breakpoint, and a number half typed must survive that.
class PosServiceShelves extends ChangeNotifier {
  PosServiceShelves({IntegrationsRepository? repository})
    : _repository = repository,
      catalog = repository == null
          ? null
          : ServicesCatalog(repository: repository),
      explainers = ServicesExplainerController(),
      novelty = ServicesNoveltyController() {
    novelty.addListener(notifyListeners);
    final catalog = this.catalog;
    airtime = catalog == null || repository == null
        ? null
        : AirtimeViewModel(catalog: catalog, repository: repository);
  }

  final IntegrationsRepository? _repository;

  /// For screens opened from the menu (the owner's pricing).
  IntegrationsRepository? get repository => _repository;

  /// Null in a till built without the integrations repository (tests, the
  /// learning sandbox): there are no services to sell.
  final ServicesCatalog? catalog;
  late final AirtimeViewModel? airtime;
  final ServicesExplainerController explainers;

  /// Which services still wear the «جديد» badge: a month from when this till
  /// first showed them.
  final ServicesNoveltyController novelty;

  bool get isSupported => catalog != null;

  /// Forgets what one person left on the till: the airtime form, the recipients
  /// they sold to lately, and the directory they were shown. The next person
  /// finds an empty form and reads the world afresh. Which explainers were
  /// hidden is the till's own, and stays.
  void reset() {
    final airtime = this.airtime;
    airtime
      ?..reset()
      ..forgetRecents();
    catalog?.clear();
    notifyListeners();
  }

  ServiceKind? _requestedTab;

  /// Asks the voucher menu to open the tab of [kind] — whenever it next can:
  /// the request waits for a menu that is not on screen yet.
  void requestTab(ServiceKind kind) {
    _requestedTab = kind;
    notifyListeners();
  }

  /// The tab asked for, once: the menu that opens it forgets the request.
  ServiceKind? takeRequestedTab() {
    final kind = _requestedTab;
    _requestedTab = null;
    return kind;
  }

  /// A bill flow for one type of bill; the caller disposes it.
  BillFlowViewModel? newBillFlow(BillType type) {
    final catalog = this.catalog;
    final repository = _repository;
    if (catalog == null || repository == null) {
      return null;
    }
    return BillFlowViewModel(
      type: type,
      catalog: catalog,
      repository: repository,
    );
  }

  @override
  void dispose() {
    airtime?.dispose();
    catalog?.dispose();
    explainers.dispose();
    novelty
      ..removeListener(notifyListeners)
      ..dispose();
    super.dispose();
  }
}
