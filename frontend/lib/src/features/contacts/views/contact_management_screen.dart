import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/contact.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/services/payment_proof_printer.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/customer_rank_presentation.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/query_controls/debounced_search_field.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/contact_management_view_model.dart';
import '../view_models/customer_details_view_model.dart';
import '../view_models/supplier_details_view_model.dart';
import 'customer_details_screen.dart';
import 'supplier_details_screen.dart';

class ContactManagementScreen extends StatefulWidget {
  const ContactManagementScreen({
    super.key,
    required this.viewModel,
    required this.purchaseRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.navigation,
    required this.capabilities,
  });

  final ContactManagementViewModel viewModel;
  final PurchaseRepository purchaseRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final AppNavigation navigation;
  final AuthorizationCapabilities capabilities;

  @override
  State<ContactManagementScreen> createState() =>
      _ContactManagementScreenState();
}

class _ContactManagementScreenState extends State<ContactManagementScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  Customer? _selectedCustomer;
  CustomerDetailsViewModel? _selectedCustomerViewModel;
  SupplierContact? _selectedSupplier;
  SupplierDetailsViewModel? _selectedSupplierViewModel;

  ContactManagementViewModel get viewModel => widget.viewModel;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_handleTabChanged);
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _handleTabChanged() {
    if (_selectedCustomer == null && _selectedSupplier == null) {
      return;
    }
    setState(() {
      _selectedCustomer = null;
      _selectedCustomerViewModel = null;
      _selectedSupplier = null;
      _selectedSupplierViewModel = null;
    });
  }

  void _selectCustomer(Customer customer) {
    setState(() {
      _selectedCustomer = customer;
      _selectedCustomerViewModel = CustomerDetailsViewModel(
        contactRepository: viewModel.repository,
        initialCustomer: customer,
        shopSettingsRepository: widget.shopSettingsRepository,
        printingRepository: widget.printingRepository,
      );
    });
  }

  void _selectSupplier(SupplierContact supplier) {
    setState(() {
      _selectedSupplier = supplier;
      _selectedSupplierViewModel = SupplierDetailsViewModel(
        contactRepository: viewModel.repository,
        purchaseRepository: widget.purchaseRepository,
        initialSupplier: supplier,
        proofPrinter: PaymentProofPrinter(
          printingRepository: widget.printingRepository,
          shopSettingsRepository: widget.shopSettingsRepository,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.contacts,
            navigation: widget.navigation,
          ),
          appBar: AppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.contactsTitle),
            bottom: TabBar(
              controller: _tabController,
              tabs: [
                Tab(text: l10n.customersTab),
                Tab(text: l10n.suppliersTab),
              ],
            ),
            actions: [
              AuthorizationGuard(
                capabilities: widget.capabilities,
                capability: AppCapability.manageContacts,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.refreshContactsTooltip,
                  onPressed: viewModel.loadContacts,
                  icon: const Icon(Icons.sync),
                ),
              ),
            ],
          ),
          body: AuthorizationGuard(
            capabilities: widget.capabilities,
            capability: AppCapability.manageContacts,
            child: _ContactManagementBody(
              viewModel: viewModel,
              tabController: _tabController,
              customerDetailPane: _buildCustomerDetailPane(),
              supplierDetailPane: _buildSupplierDetailPane(),
              onSelectCustomer: _selectCustomer,
              onSelectSupplier: _selectSupplier,
              selectedCustomerId: _selectedCustomer?.id,
              selectedSupplierId: _selectedSupplier?.id,
              purchaseRepository: widget.purchaseRepository,
              printingRepository: widget.printingRepository,
              shopSettingsRepository: widget.shopSettingsRepository,
              capabilities: widget.capabilities,
            ),
          ),
        );
      },
    );
  }

  Widget? _buildCustomerDetailPane() {
    final customer = _selectedCustomer;
    final customerViewModel = _selectedCustomerViewModel;
    if (customer == null || customerViewModel == null) {
      return null;
    }
    return CustomerDetailsView(
      key: ValueKey('contact_detail_customer_${customer.id}'),
      viewModel: customerViewModel,
      capabilities: widget.capabilities,
      onMerged: () {
        setState(() {
          _selectedCustomer = null;
          _selectedCustomerViewModel = null;
        });
        viewModel.loadContacts();
      },
      onClaimed: viewModel.loadContacts,
      onEdited: viewModel.loadContacts,
    );
  }

  Widget? _buildSupplierDetailPane() {
    final supplier = _selectedSupplier;
    final supplierViewModel = _selectedSupplierViewModel;
    if (supplier == null || supplierViewModel == null) {
      return null;
    }
    return SupplierDetailsView(
      key: ValueKey('contact_detail_supplier_${supplier.id}'),
      viewModel: supplierViewModel,
      purchaseRepository: widget.purchaseRepository,
      printingRepository: widget.printingRepository,
      shopSettingsRepository: widget.shopSettingsRepository,
      capabilities: widget.capabilities,
      onEdited: viewModel.loadContacts,
    );
  }
}

class _ContactManagementBody extends StatelessWidget {
  const _ContactManagementBody({
    required this.viewModel,
    required this.tabController,
    required this.customerDetailPane,
    required this.supplierDetailPane,
    required this.onSelectCustomer,
    required this.onSelectSupplier,
    required this.selectedCustomerId,
    required this.selectedSupplierId,
    required this.purchaseRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.capabilities,
  });

  final ContactManagementViewModel viewModel;
  final TabController tabController;
  final Widget? customerDetailPane;
  final Widget? supplierDetailPane;
  final ValueChanged<Customer> onSelectCustomer;
  final ValueChanged<SupplierContact> onSelectSupplier;
  final int? selectedCustomerId;
  final int? selectedSupplierId;
  final PurchaseRepository purchaseRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    final placeholder = PointyEmptyState(
      icon: Icons.people_outline,
      title: l10n.contactsSelectContactPlaceholder,
    );

    return Column(
      children: [
        Padding(
          padding: spacing.pagePadding.copyWith(bottom: spacing.sm),
          child: _ContactActionBar(
            viewModel: viewModel,
            tabController: tabController,
            capabilities: capabilities,
          ),
        ),
        _CustomerStatusFilter(
          viewModel: viewModel,
          tabController: tabController,
        ),
        _CustomerRankFilter(viewModel: viewModel, tabController: tabController),
        if (viewModel.hasError)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              l10n.contactsLoadError,
              style: TextStyle(color: context.pointyColors.danger),
            ),
          ),
        Expanded(
          child: viewModel.isLoading
              ? const Center(child: PointySpinner())
              : TabBarView(
                  controller: tabController,
                  children: [
                    MasterDetailLayout(
                      listPaneBuilder: (paneContext, isDualPane) =>
                          _CustomerList(
                            viewModel: viewModel,
                            printingRepository: printingRepository,
                            shopSettingsRepository: shopSettingsRepository,
                            capabilities: capabilities,
                            onSelectCustomer: isDualPane
                                ? onSelectCustomer
                                : null,
                            selectedCustomerId: isDualPane
                                ? selectedCustomerId
                                : null,
                          ),
                      placeholder: placeholder,
                      detailPane: customerDetailPane,
                    ),
                    MasterDetailLayout(
                      listPaneBuilder: (paneContext, isDualPane) =>
                          _SupplierList(
                            viewModel: viewModel,
                            purchaseRepository: purchaseRepository,
                            printingRepository: printingRepository,
                            shopSettingsRepository: shopSettingsRepository,
                            capabilities: capabilities,
                            onSelectSupplier: isDualPane
                                ? onSelectSupplier
                                : null,
                            selectedSupplierId: isDualPane
                                ? selectedSupplierId
                                : null,
                          ),
                      placeholder: placeholder,
                      detailPane: supplierDetailPane,
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Customers-tab filter chips: switch between all real customers and the
/// hidden "unclaimed cards" placeholders awaiting a name or merge.
class _CustomerStatusFilter extends StatelessWidget {
  const _CustomerStatusFilter({
    required this.viewModel,
    required this.tabController,
  });

  final ContactManagementViewModel viewModel;
  final TabController tabController;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return AnimatedBuilder(
      animation: tabController,
      builder: (context, _) {
        if (tabController.index != 0) {
          return const SizedBox.shrink();
        }
        final status = viewModel.query.status;
        final isUnclaimed = status == ContactStatusFilter.unclaimedCards;
        return Padding(
          padding: EdgeInsets.fromLTRB(spacing.lg, 0, spacing.lg, spacing.sm),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Wrap(
              spacing: spacing.sm,
              children: [
                ChoiceChip(
                  label: Text(l10n.allCustomersFilterLabel),
                  selected: !isUnclaimed,
                  onSelected: (_) =>
                      viewModel.updateStatus(ContactStatusFilter.all),
                ),
                ChoiceChip(
                  avatar: const Icon(Icons.credit_card_outlined, size: 18),
                  label: Text(l10n.unclaimedCardsFilterLabel),
                  selected: isUnclaimed,
                  onSelected: (_) => viewModel.updateStatus(
                    ContactStatusFilter.unclaimedCards,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Customers-tab filter: pin the list to a single RFM rank (or all ranks).
/// Ranks are assigned automatically by the backend's nightly segmentation job.
class _CustomerRankFilter extends StatelessWidget {
  const _CustomerRankFilter({
    required this.viewModel,
    required this.tabController,
  });

  final ContactManagementViewModel viewModel;
  final TabController tabController;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);

    return AnimatedBuilder(
      animation: tabController,
      builder: (context, _) {
        if (tabController.index != 0) {
          return const SizedBox.shrink();
        }
        final selected = viewModel.query.rank;
        return Padding(
          padding: EdgeInsets.fromLTRB(spacing.lg, 0, spacing.lg, spacing.sm),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final filter in CustomerRankFilter.values) ...[
                  if (filter != CustomerRankFilter.values.first)
                    SizedBox(width: spacing.sm),
                  _RankChoiceChip(
                    filter: filter,
                    selected: filter == selected,
                    onSelected: () => viewModel.updateRank(filter),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RankChoiceChip extends StatelessWidget {
  const _RankChoiceChip({
    required this.filter,
    required this.selected,
    required this.onSelected,
  });

  final CustomerRankFilter filter;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final rank = filter.rank;
    if (rank == null) {
      return ChoiceChip(
        label: Text(l10n.allRanksFilterLabel),
        selected: selected,
        onSelected: (_) => onSelected(),
      );
    }
    final style = customerRankStyle(context, rank);
    return ChoiceChip(
      avatar: Icon(style.icon, size: 18, color: style.color),
      label: Text(style.label),
      selected: selected,
      onSelected: (_) => onSelected(),
    );
  }
}

class _ContactActionBar extends StatelessWidget {
  const _ContactActionBar({
    required this.viewModel,
    required this.tabController,
    required this.capabilities,
  });

  final ContactManagementViewModel viewModel;
  final TabController tabController;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return AnimatedBuilder(
      animation: tabController,
      builder: (context, _) {
        final isCustomersTab = tabController.index == 0;
        return LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= AppBreakpoints.tabletMin;
            return ResponsiveActionBar(
              compactBreakpoint: AppBreakpoints.tabletMin,
              actions: [
                SizedBox(
                  width: isWide
                      ? constraints.maxWidth - 210 - spacing.sm
                      : null,
                  // Debounced: a raw onChanged used to fire two paginated
                  // requests (customers + suppliers) per keystroke.
                  child: DebouncedSearchField(
                    value: viewModel.query.search,
                    hintText: l10n.contactSearchHint,
                    clearTooltip: l10n.clearSearchTooltip,
                    onChanged: viewModel.updateSearch,
                  ),
                ),
                FilledButton.icon(
                  onPressed: viewModel.isSaving
                      ? null
                      : () => _createContact(context, isCustomersTab),
                  icon: Icon(
                    isCustomersTab
                        ? Icons.person_add_alt_1
                        : Icons.add_business_outlined,
                  ),
                  label: Text(
                    isCustomersTab
                        ? l10n.addCustomerButton
                        : l10n.addSupplierButton,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _createContact(BuildContext context, bool isCustomersTab) async {
    if (isCustomersTab) {
      final created = await showCreateCustomerSheet(
        context: context,
        repository: viewModel.repository,
        allowOpeningBalance: capabilities.canManageCustomerBalances,
      );
      if (created != null) {
        await viewModel.loadContacts();
      }
      return;
    }
    final created = await showCreateSupplierSheet(
      context: context,
      repository: viewModel.repository,
      allowOpeningBalance: capabilities.canManageSupplierBalances,
    );
    if (created != null) {
      await viewModel.loadContacts();
    }
  }
}

class _CustomerList extends StatelessWidget {
  const _CustomerList({
    required this.viewModel,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.capabilities,
    this.onSelectCustomer,
    this.selectedCustomerId,
  });

  final ContactManagementViewModel viewModel;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final AuthorizationCapabilities capabilities;
  final ValueChanged<Customer>? onSelectCustomer;
  final int? selectedCustomerId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDataList<Customer>(
      items: viewModel.customers,
      onLoadMore: viewModel.loadMoreCustomers,
      hasMore: viewModel.hasMoreCustomers,
      isLoadingInitial: viewModel.isLoading,
      isLoadingMore: viewModel.isLoadingMoreCustomers,
      loadMoreFailed: viewModel.customerLoadMoreFailed,
      loadMoreErrorMessage: l10n.contactsLoadError,
      emptyBuilder: (context) => PointyEmptyState(
        icon: Icons.person_outline,
        title: l10n.emptyCustomers,
        action: FilledButton.icon(
          onPressed: viewModel.isSaving
              ? null
              : () async {
                  final created = await showCreateCustomerSheet(
                    context: context,
                    repository: viewModel.repository,
                    allowOpeningBalance: capabilities.canManageCustomerBalances,
                  );
                  if (created != null) {
                    await viewModel.loadContacts();
                  }
                },
          icon: const Icon(Icons.person_add_alt_1),
          label: Text(l10n.addCustomerButton),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      framed: false,
      itemBuilder: (context, customer) {
        return PointyDataRow(
          leading: Icon(
            customer.isAutoCreated
                ? Icons.credit_card_outlined
                : customer.marketingConsent
                ? Icons.campaign_outlined
                : Icons.person_outline,
          ),
          title: customer.fullName,
          subtitle: [
            if (customer.isAutoCreated) l10n.customerAutoCreatedBadge,
            if (customer.customerNumber.isNotEmpty)
              '${l10n.customerNumberLabel}: ${customer.customerNumber}',
            if (customer.phone.isNotEmpty) customer.phone,
            if (customer.email.isNotEmpty) customer.email,
            if (!customer.isAutoCreated) genderLabel(l10n, customer.gender),
            if (customer.birthday != null)
              '${l10n.customerBirthdayLabel}: ${_formatDate(customer.birthday!)}',
            if (customer.cardCount > 0)
              l10n.paymentCardCountValue(customer.cardCount),
            if (customer.marketingConsent) l10n.marketingAllowedLabel,
            if (!customer.isActive) l10n.inactiveContactLabel,
          ].join(' • '),
          trailing: const PointyDisclosureChevron(),
          badges: [
            if (customer.rank != CustomerRank.inactive)
              Builder(
                builder: (context) {
                  final style = customerRankStyle(context, customer.rank);
                  return PointyStatusPill(
                    label: style.label,
                    icon: style.icon,
                    color: style.color,
                  );
                },
              ),
          ],
          selected: customer.id == selectedCustomerId,
          onTap: () => _openCustomer(context, customer),
        );
      },
    );
  }

  void _openCustomer(BuildContext context, Customer customer) {
    final onSelect = onSelectCustomer;
    if (onSelect != null) {
      onSelect(customer);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CustomerDetailsScreen(
          customer: customer,
          contactRepository: viewModel.repository,
          printingRepository: printingRepository,
          shopSettingsRepository: shopSettingsRepository,
          capabilities: capabilities,
        ),
      ),
    );
  }
}

class _SupplierList extends StatelessWidget {
  const _SupplierList({
    required this.viewModel,
    required this.purchaseRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.capabilities,
    this.onSelectSupplier,
    this.selectedSupplierId,
  });

  final ContactManagementViewModel viewModel;
  final PurchaseRepository purchaseRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final AuthorizationCapabilities capabilities;
  final ValueChanged<SupplierContact>? onSelectSupplier;
  final int? selectedSupplierId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDataList<SupplierContact>(
      items: viewModel.suppliers,
      onLoadMore: viewModel.loadMoreSuppliers,
      hasMore: viewModel.hasMoreSuppliers,
      isLoadingInitial: viewModel.isLoading,
      isLoadingMore: viewModel.isLoadingMoreSuppliers,
      loadMoreFailed: viewModel.supplierLoadMoreFailed,
      loadMoreErrorMessage: l10n.contactsLoadError,
      emptyBuilder: (context) => PointyEmptyState(
        icon: Icons.local_shipping_outlined,
        title: l10n.emptySuppliers,
        action: FilledButton.icon(
          onPressed: viewModel.isSaving
              ? null
              : () async {
                  final created = await showCreateSupplierSheet(
                    context: context,
                    repository: viewModel.repository,
                    allowOpeningBalance: capabilities.canManageSupplierBalances,
                  );
                  if (created != null) {
                    await viewModel.loadContacts();
                  }
                },
          icon: const Icon(Icons.add_business_outlined),
          label: Text(l10n.addSupplierButton),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      framed: false,
      itemBuilder: (context, supplier) {
        return PointyDataRow(
          leading: const Icon(Icons.local_shipping_outlined),
          title: supplier.name,
          subtitle: [
            if (supplier.contactName.isNotEmpty)
              '${l10n.supplierContactLabel}: ${supplier.contactName}',
            if (supplier.phone.isNotEmpty) supplier.phone,
            if (supplier.email.isNotEmpty) supplier.email,
            if (supplier.address.isNotEmpty) supplier.address,
            if (supplier.payableBalance > 0)
              l10n.supplierPayableBalanceValue(
                formatMoney(supplier.payableBalance),
              ),
            if (supplier.creditBalance > 0)
              l10n.supplierCreditBalanceValue(
                formatMoney(supplier.creditBalance),
              ),
            if (supplier.netBalance != 0)
              l10n.supplierNetBalanceValue(formatMoney(supplier.netBalance)),
            if (!supplier.isActive) l10n.inactiveContactLabel,
          ].join(' • '),
          trailing: const PointyDisclosureChevron(),
          selected: supplier.id == selectedSupplierId,
          onTap: () => _openSupplier(context, supplier),
        );
      },
    );
  }

  void _openSupplier(BuildContext context, SupplierContact supplier) {
    final onSelect = onSelectSupplier;
    if (onSelect != null) {
      onSelect(supplier);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SupplierDetailsScreen(
          supplier: supplier,
          contactRepository: viewModel.repository,
          purchaseRepository: purchaseRepository,
          printingRepository: printingRepository,
          shopSettingsRepository: shopSettingsRepository,
          capabilities: capabilities,
        ),
      ),
    );
  }
}

String _formatDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}
