import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/integration_provider.dart';
import '../../../data/models/service_kinds.dart';
import '../../../data/models/voucher_menu.dart';
import '../../../data/repositories/integrations_repository.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/pos_service_shelves.dart';
import '../view_models/voucher_menu_search.dart';
import '../view_models/pos_view_model.dart';
import '../../settings/views/voucher_pricing_screen.dart';
import 'direct_services/airtime_flow_sheet.dart';
import 'direct_services/airtime_launcher.dart';
import 'direct_services/bill_flow_sheet.dart';
import 'direct_services/bill_types_grid.dart';
import 'direct_services/service_add_request.dart';
import 'direct_services/service_card_art.dart';
import 'direct_services/services_strip.dart';
import 'pos_voucher_brand_card.dart';
import 'pos_voucher_brand_sheet.dart';
import 'voucher_card_art.dart';

/// The «كروت دفتر» menu in the catalog's place, read through the till's view
/// model: picking a brand opens its sheet, and the card picked there goes into
/// the open invoice like any line — bought only once the invoice is paid.
class PosVoucherMenuPane extends StatefulWidget {
  const PosVoucherMenuPane({
    super.key,
    required this.viewModel,
    required this.capabilities,
    this.fallback,
    this.onTransferVoucherBalance,
  });

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  /// Moves money from the wallet into the voucher balance and says whether any
  /// moved; null for a user who cannot do it from the till.
  final Future<bool> Function()? onTransferVoucherBalance;

  /// The ordinary product grid, under the error when the menu cannot be read:
  /// the cards are still products, so the till can keep selling them.
  final Widget? fallback;

  @override
  State<PosVoucherMenuPane> createState() => _PosVoucherMenuPaneState();
}

class _PosVoucherMenuPaneState extends State<PosVoucherMenuPane> {
  @override
  void initState() {
    super.initState();
    // After the frame: starting a read notifies, and this runs mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.viewModel.voucherMenu.ensureLoaded());
      }
    });
  }

  Future<void> _sell(BuildContext context, VoucherBrand brand) {
    final viewModel = widget.viewModel;
    final menu = viewModel.voucherMenu.menu;
    if (menu == null) {
      return Future.value();
    }
    // A background refresh must not reshuffle the till under the sheet.
    return viewModel.duringCriticalInteraction(() async {
      final card = await showPosVoucherBrandSheet(
        context,
        brand: brand,
        menu: menu,
        showsProfit: viewModel.isCostRevealed,
      );
      if (card != null && context.mounted) {
        // One card, one line: a card never merges into another.
        viewModel.addVariant(card, source: 'voucher_menu');
      }
    });
  }

  /// A priced airtime top-up or bill payment goes in the cart as a line. False
  /// when the cart could not take it.
  bool _addService(BuildContext context, ServiceAddRequest request) {
    final l10n = AppLocalizations.of(context)!;
    return widget.viewModel.addServiceLine(
      quote: request.quote,
      variantId: request.variantId,
      title: request.kind == ServiceKind.airtime
          ? l10n.posServicesAirtimeLineTitle
          : l10n.posServicesBillLineTitle,
      testMode: request.testMode,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.viewModel.voucherMenu;
    final shelves = widget.viewModel.serviceShelves;
    return CheckoutCapabilityBuilder(
      capabilities: widget.capabilities,
      builder: (context, canCheckout) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => PosVoucherMenuView(
          menu: controller.menu,
          hasError: controller.hasError,
          onRetry: controller.refresh,
          fallback: widget.fallback,
          search: widget.viewModel.voucherMenuSearch,
          onClearSearch: widget.viewModel.requestSearchReset,
          onBrandSelected: canCheckout
              ? (brand) => _sell(context, brand)
              : null,
          shelves: shelves.isSupported ? shelves : null,
          onServiceAdd: canCheckout
              ? (request) => _addService(context, request)
              : null,
          onTransferVoucherBalance: canCheckout
              ? widget.onTransferVoucherBalance
              : null,
        ),
      ),
    );
  }
}

/// The menu itself, driven by parameters only — so the preview harness, the
/// capture test and widget tests can draw every state without a till.
///
/// The company's category tabs (when it has more than one), then its brands
/// as gift cards, both in the order the company chose. Skeleton cards while
/// the first read is on its way, an inline error with a retry when it failed,
/// and an empty state when there is nothing to sell.
class PosVoucherMenuView extends StatefulWidget {
  const PosVoucherMenuView({
    super.key,
    required this.menu,
    this.hasError = false,
    this.onRetry,
    this.onBrandSelected,
    this.animateSkeleton = true,
    this.fallback,
    this.shelves,
    this.onServiceAdd,
    this.onTransferVoucherBalance,
    this.search = '',
    this.onClearSearch,
  });

  /// What the cashier typed in the till's search box: the menu shows only what
  /// it finds (brands by name or alias, and the services it names).
  final String search;

  /// Empties the search box; offered when nothing matches.
  final VoidCallback? onClearSearch;

  /// Null until the first read lands.
  final VoucherMenu? menu;
  final bool hasError;
  final VoidCallback? onRetry;

  /// Shown under the error, so a failed read never leaves the till empty.
  final Widget? fallback;

  /// Null on a till that cannot sell.
  final ValueChanged<VoucherBrand>? onBrandSelected;

  /// Off for screenshots, where a shimmer mid-sweep is noise.
  final bool animateSkeleton;

  /// What the direct services — airtime, bills — need to run. Null leaves the
  /// services off the menu, whatever the server says.
  final PosServiceShelves? shelves;

  /// Puts a priced service in the cart. Null on a till that cannot sell.
  final ServiceAddCallback? onServiceAdd;

  /// Moves money from the wallet into the voucher balance and says whether any
  /// moved. Null for a user who cannot do it from the till.
  final Future<bool> Function()? onTransferVoucherBalance;

  @override
  State<PosVoucherMenuView> createState() => _PosVoucherMenuViewState();
}

/// The two tabs the direct services add after «الكل».
enum _ServiceTab { airtime, bills }

class _PosVoucherMenuViewState extends State<PosVoucherMenuView> {
  /// The selected category's key; null is «الكل».
  String? _category;

  /// The service tab selected, when one is; it wins over [_category].
  _ServiceTab? _serviceTab;

  @override
  void initState() {
    super.initState();
    widget.shelves?.addListener(_onShelvesChanged);
    _openRequestedTab();
    WidgetsBinding.instance.addPostFrameCallback((_) => _markServicesSeen());
  }

  @override
  void didUpdateWidget(covariant PosVoucherMenuView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.shelves, widget.shelves)) {
      oldWidget.shelves?.removeListener(_onShelvesChanged);
      widget.shelves?.addListener(_onShelvesChanged);
    }
    if (!identical(oldWidget.menu, widget.menu) ||
        !identical(oldWidget.shelves, widget.shelves)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _markServicesSeen());
    }
  }

  @override
  void dispose() {
    widget.shelves?.removeListener(_onShelvesChanged);
    super.dispose();
  }

  void _onShelvesChanged() {
    _openRequestedTab();
    // The tab asked for, or which services are still new, may have changed.
    if (mounted) {
      setState(() {});
    }
  }

  /// Opens the tab something asked for; true when it did.
  bool _openRequestedTab() {
    final kind = widget.shelves?.takeRequestedTab();
    if (kind == null) {
      return false;
    }
    _serviceTab = kind == ServiceKind.airtime
        ? _ServiceTab.airtime
        : _ServiceTab.bills;
    return true;
  }

  /// The relay is buying from its test supplier — fake money, nothing really
  /// sent — as the menu says, or the directory or [country] does once read.
  bool _isTestMode({String? country}) {
    final menu = widget.menu;
    return (menu?.isTestMode ?? false) ||
        (widget.shelves?.catalog?.isTestMode(country: country) ?? false);
  }

  /// Opens the stepped direct top-up, and puts the top-up in the cart when the
  /// cashier finishes it.
  Future<void> _openAirtime(VoucherMenuService airtime) async {
    final vm = widget.shelves?.airtime;
    if (vm == null) {
      return;
    }
    final quote = await showAirtimeFlow(
      context,
      viewModel: vm,
      canSell: widget.onServiceAdd != null,
      testMode: _isTestMode(),
      onAdd: (quote) =>
          widget.onServiceAdd?.call(
            ServiceAddRequest(
              kind: ServiceKind.airtime,
              quote: quote,
              variantId: airtime.variantId > 0
                  ? airtime.variantId
                  : quote.serviceVariantId,
              testMode: _isTestMode(country: quote.request?.country),
            ),
          ) ??
          false,
      onTransferBalance: widget.onTransferVoucherBalance,
    );
    if (quote == null || !mounted) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.maybeOf(context)
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(l10n.posAirtimeAdded)));
  }

  /// Opens the flow for paying one type of bill, and puts the bill in the cart
  /// when the cashier finishes it.
  Future<void> _openBill(VoucherMenuService service) async {
    final shelves = widget.shelves;
    if (shelves == null) {
      return;
    }
    final quote = await showBillFlow(
      context,
      create: () => shelves.newBillFlow(service.billType)!,
      canSell: widget.onServiceAdd != null,
      testMode: _isTestMode(),
      // The cart answers inside the dialog: a bill it cannot take keeps the
      // dialog open, with everything the cashier typed.
      onAdd: (quote) =>
          widget.onServiceAdd?.call(
            ServiceAddRequest(
              kind: ServiceKind.bill,
              billType: service.billType,
              quote: quote,
              variantId: service.variantId > 0
                  ? service.variantId
                  : quote.serviceVariantId,
              testMode: _isTestMode(country: quote.request?.country),
            ),
          ) ??
          false,
      onTransferBalance: widget.onTransferVoucherBalance,
    );
    if (quote == null || !mounted) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.maybeOf(context)
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(l10n.posBillAdded)));
  }

  /// One card per service, in the order the shop sells them: airtime, then
  /// each type of bill. A bill card opens its flow; the airtime card opens
  /// its tab.
  List<ServiceStripEntry> _serviceCards(
    VoucherMenu menu, {
    required bool includeAirtime,
  }) {
    final airtime = menu.airtimeService;
    final novelty = widget.shelves?.novelty;
    bool isNew(ServiceCardKind kind) => novelty?.isNew(kind.name) ?? true;
    return [
      if (includeAirtime && airtime != null)
        ServiceStripEntry(
          kind: ServiceCardKind.airtime,
          countries: airtime.countries,
          providers: airtime.providers,
          onTap: () => setState(() => _serviceTab = _ServiceTab.airtime),
          isNew: isNew(ServiceCardKind.airtime),
        ),
      for (final service in menu.billServices)
        if (serviceCardKindOf(service) case final kind?)
          ServiceStripEntry(
            kind: kind,
            countries: service.countries,
            providers: service.providers,
            onTap: () => _openBill(service),
            isNew: isNew(kind),
          ),
    ];
  }

  /// Notes today as the day the cards of [menu] were first shown, for the
  /// month their «جديد» badge lasts. The day is only ever the first.
  void _markServicesSeen() {
    final shelves = widget.shelves;
    final menu = widget.menu;
    if (shelves == null || menu == null) {
      return;
    }
    final kinds = [
      if (menu.airtimeService != null && shelves.airtime != null)
        ServiceCardKind.airtime,
      if (shelves.isSupported)
        for (final service in menu.billServices) ?serviceCardKindOf(service),
    ];
    if (kinds.isNotEmpty) {
      unawaited(
        shelves.novelty.markSeen([for (final kind in kinds) kind.name]),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final menu = widget.menu;
    if (menu == null) {
      if (widget.hasError) {
        final error = PointyInlineMessage.error(
          key: const ValueKey('voucher_menu_error'),
          message: l10n.posVoucherMenuLoadError,
          icon: Icons.cloud_off_outlined,
          trailing: TextButton.icon(
            onPressed: widget.onRetry,
            icon: const Icon(Icons.sync),
            label: Text(l10n.retryButton),
          ),
        );
        final fallback = widget.fallback;
        if (fallback == null) {
          return Align(alignment: AlignmentDirectional.topCenter, child: error);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            error,
            SizedBox(height: AdaptiveSpacing.of(context).sm),
            Expanded(child: fallback),
          ],
        );
      }
      return _SkeletonGrid(animate: widget.animateSkeleton);
    }
    final shelves = widget.shelves;
    final hasAirtime = shelves?.airtime != null && menu.airtimeService != null;
    final hasBills = shelves != null && menu.hasBills;
    final hasServices = hasAirtime || hasBills;
    if (!menu.hasBrands && !hasServices) {
      return PointyEmptyState(
        icon: Icons.card_giftcard_outlined,
        title: l10n.posVoucherMenuEmptyTitle,
        message: switch (menu.errorCode) {
          IntegrationErrorCode.switchedOff =>
            l10n.posVoucherMenuSwitchedOffMessage,
          IntegrationErrorCode.notConfigured =>
            l10n.posVoucherMenuDisabledMessage,
          _ => l10n.posVoucherMenuEmptyMessage,
        },
      );
    }

    final query = widget.search.trim();
    final found = query.isEmpty ? null : searchVoucherMenu(menu, query);
    final categories = menu.usedCategories;
    final selected =
        found == null && categories.any((category) => category.key == _category)
        ? _category
        : null;
    final brands = found?.brands ?? menu.brandsIn(selected);
    final onSelected = widget.onBrandSelected;
    final serviceTab = found != null
        ? null
        : switch (_serviceTab) {
            _ServiceTab.airtime when hasAirtime => _ServiceTab.airtime,
            _ServiceTab.bills when hasBills => _ServiceTab.bills,
            _ => null,
          };
    final serviceCards = hasServices
        ? _serviceCards(menu, includeAirtime: hasAirtime)
        : const <ServiceStripEntry>[];

    final pricingRepository = shelves?.repository;
    final canEditPricing = menu.canEditPricing && pricingRepository != null;

    Widget content;
    if (found != null) {
      final matching = [
        for (final entry in _serviceCards(menu, includeAirtime: hasAirtime))
          if (_serviceHit(found, entry.kind))
            entry.kind == ServiceCardKind.airtime
                // A search opens the dialog itself rather than the tab.
                ? ServiceStripEntry(
                    kind: entry.kind,
                    countries: entry.countries,
                    providers: entry.providers,
                    isNew: entry.isNew,
                    onTap: () => _openAirtime(menu.airtimeService!),
                  )
                : entry,
      ];
      content = found.isEmpty || (brands.isEmpty && matching.isEmpty)
          ? PointyEmptyState(
              key: const ValueKey('voucher_search_empty'),
              icon: Icons.search_off_rounded,
              title: l10n.posVoucherSearchEmptyTitle(query),
              message: l10n.posVoucherSearchEmptyMessage,
              action: widget.onClearSearch == null
                  ? null
                  : OutlinedButton.icon(
                      key: const ValueKey('voucher_search_clear'),
                      onPressed: widget.onClearSearch,
                      icon: const Icon(Icons.close_rounded),
                      label: Text(l10n.posVoucherSearchClear),
                    ),
            )
          : _BrandGrid(
              header: matching.isEmpty
                  ? null
                  : ServicesStrip(
                      entries: matching,
                      testMode: _isTestMode(),
                      showHeading: false,
                    ),
              itemCount: brands.length,
              itemBuilder: (context, index) =>
                  _brandCard(menu, brands[index], onSelected),
            );
    } else {
      content = _browseContent(
        menu,
        serviceTab: serviceTab,
        selected: selected,
        brands: brands,
        serviceCards: serviceCards,
        hasAirtime: hasAirtime,
        shelves: shelves,
        onSelected: onSelected,
      );
    }
    final header = _tabsRow(
      l10n,
      menu,
      categories: categories,
      selected: selected,
      serviceTab: serviceTab,
      hasAirtime: hasAirtime,
      hasBills: hasBills,
      hasServices: hasServices,
      canEditPricing: canEditPricing,
      pricingRepository: pricingRepository,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?header,
        Expanded(child: content),
      ],
    );
  }

  bool _serviceHit(VoucherMenuSearchResult found, ServiceCardKind kind) =>
      switch (kind) {
        ServiceCardKind.airtime => found.airtime,
        ServiceCardKind.electricity => found.bills.contains(
          BillType.electricity,
        ),
        ServiceCardKind.water => found.bills.contains(BillType.water),
        ServiceCardKind.tv => found.bills.contains(BillType.tv),
        ServiceCardKind.internet => found.bills.contains(BillType.internet),
      };

  Widget _brandCard(
    VoucherMenu menu,
    VoucherBrand brand,
    ValueChanged<VoucherBrand>? onSelected,
  ) => PosVoucherBrandCard(
    key: ValueKey('voucher_brand_${brand.key}'),
    brand: brand,
    countryFor: menu.country,
    onTap: onSelected == null || !brand.isAvailable
        ? null
        : () => onSelected(brand),
  );

  Widget _browseContent(
    VoucherMenu menu, {
    required _ServiceTab? serviceTab,
    required String? selected,
    required List<VoucherBrand> brands,
    required List<ServiceStripEntry> serviceCards,
    required bool hasAirtime,
    required PosServiceShelves? shelves,
    required ValueChanged<VoucherBrand>? onSelected,
  }) {
    Widget content;
    switch (serviceTab) {
      case _ServiceTab.airtime:
        final airtime = menu.airtimeService!;
        content = AirtimeLauncher(
          viewModel: shelves!.airtime!,
          testMode: _isTestMode(),
          onStart: () => _openAirtime(airtime),
        );
      case _ServiceTab.bills:
        content = BillTypesGrid(
          entries: _serviceCards(menu, includeAirtime: false),
          explainers: shelves!.explainers,
          testMode: _isTestMode(),
        );
      case null:
        content = _BrandGrid(
          header: serviceCards.isEmpty || selected != null
              ? null
              : ServicesStrip(entries: serviceCards, testMode: _isTestMode()),
          itemCount: brands.length,
          itemBuilder: (context, index) =>
              _brandCard(menu, brands[index], onSelected),
        );
    }
    return content;
  }

  /// The tab row above the menu (categories, services, pricing); null when
  /// there is nothing to choose between.
  Widget? _tabsRow(
    AppLocalizations l10n,
    VoucherMenu menu, {
    required List<VoucherMenuCategory> categories,
    required String? selected,
    required _ServiceTab? serviceTab,
    required bool hasAirtime,
    required bool hasBills,
    required bool hasServices,
    required bool canEditPricing,
    required IntegrationsRepository? pricingRepository,
  }) {
    if (!(categories.length > 1 || hasServices || canEditPricing)) {
      return null;
    }

    return Row(
      children: [
        Expanded(
          child: _CategoryTabs(
            allLabel: l10n.posVoucherMenuAll,
            categories: categories,
            selected: serviceTab == null ? selected : null,
            serviceTabs: [
              if (hasAirtime)
                _ServiceTabSpec(
                  key: 'airtime',
                  label: l10n.posServicesTabAirtime,
                  icon: Icons.bolt_rounded,
                  selected: serviceTab == _ServiceTab.airtime,
                  onTap: () =>
                      setState(() => _serviceTab = _ServiceTab.airtime),
                ),
              if (hasBills)
                _ServiceTabSpec(
                  key: 'bills',
                  label: l10n.posServicesTabBills,
                  icon: Icons.receipt_long_rounded,
                  selected: serviceTab == _ServiceTab.bills,
                  onTap: () => setState(() => _serviceTab = _ServiceTab.bills),
                ),
            ],
            onSelected: (key) => setState(() {
              _category = key;
              _serviceTab = null;
            }),
          ),
        ),
        if (canEditPricing)
          IconButton(
            key: const ValueKey('voucher_pricing_open'),
            tooltip: l10n.voucherPricingOpen,
            onPressed: () =>
                showVoucherPricingScreen(context, pricingRepository!),
            icon: const Icon(Icons.tune_rounded),
          ),
      ],
    );
  }
}

/// The company's categories as tabs with an underline — a level below the
/// till's own quick-access chips, and drawn differently so the two never read
/// as one row.
///
/// More tabs than the pane is wide is the normal case on a till, so the row
/// scrolls under a finger, a dragged mouse and the mouse wheel alike: no tab
/// is ever out of reach of the cashier's hand.
class _CategoryTabs extends StatefulWidget {
  const _CategoryTabs({
    required this.allLabel,
    required this.categories,
    required this.selected,
    required this.onSelected,
    this.serviceTabs = const [],
  });

  final String allLabel;
  final List<VoucherMenuCategory> categories;
  final String? selected;
  final ValueChanged<String?> onSelected;

  /// The direct services' tabs, right after «الكل».
  final List<_ServiceTabSpec> serviceTabs;

  @override
  State<_CategoryTabs> createState() => _CategoryTabsState();
}

class _CategoryTabsState extends State<_CategoryTabs> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// A wheel has no sideways axis: its turns move the row along.
  void _onWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final position = _controller.position;
      final delta = (event as PointerScrollEvent).scrollDelta;
      final turn = delta.dx != 0 ? delta.dx : delta.dy;
      _controller.jumpTo(
        (position.pixels + turn).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final tabs = <(String?, String)>[
      for (final category in widget.categories) (category.key, category.label),
    ];
    final anyService = widget.serviceTabs.any((tab) => tab.selected);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: SizedBox(
        height: 42,
        child: Listener(
          onPointerSignal: _onWheel,
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(dragDevices: PointerDeviceKind.values.toSet()),
            child: ListView(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              children: [
                _CategoryTab(
                  key: const ValueKey('voucher_category_all'),
                  label: widget.allLabel,
                  selected: widget.selected == null && !anyService,
                  onTap: () => widget.onSelected(null),
                ),
                for (final tab in widget.serviceTabs)
                  _CategoryTab(
                    key: ValueKey('voucher_service_tab_${tab.key}'),
                    label: tab.label,
                    icon: tab.icon,
                    selected: tab.selected,
                    onTap: tab.onTap,
                  ),
                for (final (key, label) in tabs)
                  _CategoryTab(
                    key: ValueKey('voucher_category_$key'),
                    label: label,
                    selected: key == widget.selected,
                    onTap: () => widget.onSelected(key),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One of the direct services' tabs: airtime, bills.
class _ServiceTabSpec {
  const _ServiceTabSpec({
    required this.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String key;
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
}

class _CategoryTab extends StatelessWidget {
  const _CategoryTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// A service tab wears its pictogram, which also tells it from a category.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(
                      icon,
                      size: 18,
                      color: selected
                          ? colors.primaryStrong
                          : colors.accentAmber,
                    ),
                    const SizedBox(width: 5),
                  ],
                  Text(
                    label,
                    maxLines: 1,
                    style: textTheme.labelLarge?.copyWith(
                      color: selected ? colors.primaryDark : colors.mutedInk,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ],
              ),
              PositionedDirectional(
                start: 0,
                end: 0,
                bottom: 0,
                child: AnimatedContainer(
                  duration: PointyMotion.fast,
                  height: 3,
                  decoration: BoxDecoration(
                    color: selected ? colors.primaryStrong : Colors.transparent,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(3),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Gift-card columns for the width at hand: two on a phone, three beside a
/// compact till's cart, more on a wide one.
class _BrandGrid extends StatelessWidget {
  const _BrandGrid({
    required this.itemCount,
    required this.itemBuilder,
    this.header,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// Above the cards, scrolling away with them: the strip of new services.
  final Widget? header;

  static const double minTileWidth = 150;
  static const int maxColumns = 6;

  static ({int columns, double tileWidth, double gap}) layoutFor(
    double width,
    AdaptiveSpacing spacing,
  ) {
    final gap = spacing.md;
    final columns = width.isFinite && width > 0
        ? ((width + gap) / (minTileWidth + gap)).floor().clamp(2, maxColumns)
        : 2;
    final tileWidth = width.isFinite && width > 0
        ? (width - gap * (columns - 1)) / columns
        : minTileWidth;
    return (columns: columns, tileWidth: tileWidth, gap: gap);
  }

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // The grid's own inset, so a lifted card's shadow is never cut off.
        const inset = 6.0;
        final layout = layoutFor(constraints.maxWidth - inset * 2, spacing);
        final header = this.header;
        return CustomScrollView(
          slivers: [
            if (header != null)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  inset,
                  spacing.sm + inset,
                  inset,
                  0,
                ),
                sliver: SliverToBoxAdapter(child: header),
              ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                inset,
                header == null ? spacing.sm + inset : spacing.sm,
                inset,
                spacing.md,
              ),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: layout.columns,
                  mainAxisExtent: PosVoucherBrandCard.extentFor(
                    layout.tileWidth,
                    scaler: MediaQuery.textScalerOf(context),
                  ),
                  crossAxisSpacing: layout.gap,
                  mainAxisSpacing: spacing.sm,
                ),
                delegate: SliverChildBuilderDelegate(
                  itemBuilder,
                  childCount: itemCount,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Card-shaped placeholders while the first read is on its way.
class _SkeletonGrid extends StatelessWidget {
  const _SkeletonGrid({required this.animate});

  final bool animate;

  @override
  Widget build(BuildContext context) {
    return PointySkeleton(
      enabled: animate,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final spacing = AdaptiveSpacing.of(context);
          final width = constraints.maxWidth - 12;
          final layout = _BrandGrid.layoutFor(width, spacing);
          final artHeight = layout.tileWidth / kVoucherArtAspectRatio;
          return GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(6, spacing.sm + 6, 6, spacing.md),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: layout.columns,
              mainAxisExtent: PosVoucherBrandCard.extentFor(
                layout.tileWidth,
                scaler: MediaQuery.textScalerOf(context),
              ),
              crossAxisSpacing: layout.gap,
              mainAxisSpacing: spacing.sm,
            ),
            itemCount: layout.columns * 3,
            itemBuilder: (context, index) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PointySkeletonBox(
                  width: layout.tileWidth,
                  height: artHeight,
                  borderRadius: 12,
                ),
                const SizedBox(height: 19),
                PointySkeletonBox(width: layout.tileWidth * 0.62, height: 14),
                const SizedBox(height: 22),
                PointySkeletonBox(width: layout.tileWidth * 0.42, height: 14),
              ],
            ),
          );
        },
      ),
    );
  }
}
