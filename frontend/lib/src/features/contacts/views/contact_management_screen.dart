import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/contact_management_view_model.dart';
import 'customer_details_screen.dart';
import 'supplier_details_screen.dart';

class ContactManagementScreen extends StatelessWidget {
  const ContactManagementScreen({
    super.key,
    required this.viewModel,
    required this.purchaseRepository,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenInvoices,
    required this.onOpenPurchasing,
    required this.onOpenCatalog,
    required this.onOpenCategories,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenDashboard,
    this.onOpenDiscounts,
    this.onOpenReports,
    this.onOpenActivityLog,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final ContactManagementViewModel viewModel;
  final PurchaseRepository purchaseRepository;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenInvoices;
  final VoidCallback onOpenPurchasing;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenCategories;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenDashboard;
  final VoidCallback? onOpenDiscounts;
  final VoidCallback? onOpenReports;
  final VoidCallback? onOpenActivityLog;
  final VoidCallback? onOpenUsers;
  final VoidCallback? onOpenShopSettings;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return DefaultTabController(
      length: 2,
      child: ListenableBuilder(
        listenable: viewModel,
        builder: (context, _) {
          return PointyScaffold(
            drawer: AppNavigationDrawer(
              selectedDestination: AppNavigationDestination.contacts,
              currentUser: currentUser,
              capabilities: capabilities,
              onOpenDashboard: onOpenDashboard,
              onOpenPos: onOpenPos,
              onOpenInvoices: onOpenInvoices,
              onOpenPurchasing: onOpenPurchasing,
              onOpenContacts: () {},
              onOpenCatalog: onOpenCatalog,
              onOpenCategories: onOpenCategories,
              onOpenRegisterSessions: onOpenRegisterSessions,
              onOpenDeviceSettings: onOpenDeviceSettings,
              onOpenDiscounts: onOpenDiscounts,
              onOpenReports: onOpenReports,
              onOpenActivityLog: onOpenActivityLog,
              onOpenUsers: onOpenUsers,
              onOpenShopSettings: onOpenShopSettings,
              onLogout: onLogout,
            ),
            appBar: AppBar(
              leading: const PointyNavigationMenuButton(),
              title: Text(l10n.contactsTitle),
              bottom: TabBar(
                tabs: [
                  Tab(text: l10n.customersTab),
                  Tab(text: l10n.suppliersTab),
                ],
              ),
              actions: [
                AuthorizationGuard(
                  capabilities: capabilities,
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
              capabilities: capabilities,
              capability: AppCapability.manageContacts,
              child: _ContactManagementBody(
                viewModel: viewModel,
                purchaseRepository: purchaseRepository,
                capabilities: capabilities,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ContactManagementBody extends StatelessWidget {
  const _ContactManagementBody({
    required this.viewModel,
    required this.purchaseRepository,
    required this.capabilities,
  });

  final ContactManagementViewModel viewModel;
  final PurchaseRepository purchaseRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      children: [
        Padding(
          padding: spacing.pagePadding.copyWith(bottom: spacing.sm),
          child: _ContactActionBar(viewModel: viewModel),
        ),
        if (viewModel.hasError)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              l10n.contactsLoadError,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: viewModel.isLoading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  children: [
                    _CustomerList(viewModel: viewModel),
                    _SupplierList(
                      viewModel: viewModel,
                      purchaseRepository: purchaseRepository,
                      capabilities: capabilities,
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ContactActionBar extends StatelessWidget {
  const _ContactActionBar({required this.viewModel});

  final ContactManagementViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final controller = DefaultTabController.of(context);
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final isCustomersTab = controller.index == 0;
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
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: l10n.contactSearchHint,
                      prefixIcon: const Icon(Icons.search),
                    ),
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
      );
      if (created != null) {
        await viewModel.loadContacts();
      }
      return;
    }
    final created = await showCreateSupplierSheet(
      context: context,
      repository: viewModel.repository,
    );
    if (created != null) {
      await viewModel.loadContacts();
    }
  }
}

class _CustomerList extends StatelessWidget {
  const _CustomerList({required this.viewModel});

  final ContactManagementViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDataList<Customer>(
      items: viewModel.customers,
      onLoadMore: viewModel.loadMoreCustomers,
      hasMore: viewModel.hasMoreCustomers,
      isLoadingInitial: viewModel.isLoading,
      isLoadingMore: viewModel.isLoadingMoreCustomers,
      emptyBuilder: (context) => PointyEmptyState(
        icon: Icons.person_outline,
        title: l10n.emptyCustomers,
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      framed: false,
      itemBuilder: (context, customer) {
        return PointyDataRow(
          leading: Icon(
            customer.marketingConsent
                ? Icons.campaign_outlined
                : Icons.person_outline,
          ),
          title: customer.fullName,
          subtitle: [
            if (customer.customerNumber.isNotEmpty)
              '${l10n.customerNumberLabel}: ${customer.customerNumber}',
            if (customer.phone.isNotEmpty) customer.phone,
            if (customer.email.isNotEmpty) customer.email,
            genderLabel(l10n, customer.gender),
            if (customer.birthday != null)
              '${l10n.customerBirthdayLabel}: ${_formatDate(customer.birthday!)}',
            if (customer.marketingConsent) l10n.marketingAllowedLabel,
            if (!customer.isActive) l10n.inactiveContactLabel,
          ].join(' • '),
          trailing: const Icon(Icons.chevron_left),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => CustomerDetailsScreen(
                customer: customer,
                contactRepository: viewModel.repository,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SupplierList extends StatelessWidget {
  const _SupplierList({
    required this.viewModel,
    required this.purchaseRepository,
    required this.capabilities,
  });

  final ContactManagementViewModel viewModel;
  final PurchaseRepository purchaseRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PointyDataList<SupplierContact>(
      items: viewModel.suppliers,
      onLoadMore: viewModel.loadMoreSuppliers,
      hasMore: viewModel.hasMoreSuppliers,
      isLoadingInitial: viewModel.isLoading,
      isLoadingMore: viewModel.isLoadingMoreSuppliers,
      emptyBuilder: (context) => PointyEmptyState(
        icon: Icons.local_shipping_outlined,
        title: l10n.emptySuppliers,
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
          trailing: const Icon(Icons.chevron_left),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SupplierDetailsScreen(
                supplier: supplier,
                contactRepository: viewModel.repository,
                purchaseRepository: purchaseRepository,
                capabilities: capabilities,
              ),
            ),
          ),
        );
      },
    );
  }
}

String _formatDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}
