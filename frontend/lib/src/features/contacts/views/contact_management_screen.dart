import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/formatters.dart';
import '../view_models/contact_management_view_model.dart';
import 'supplier_details_screen.dart';

class ContactManagementScreen extends StatelessWidget {
  const ContactManagementScreen({
    super.key,
    required this.viewModel,
    required this.purchaseRepository,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenPurchasing,
    required this.onOpenCatalog,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenDiscounts,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final ContactManagementViewModel viewModel;
  final PurchaseRepository purchaseRepository;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenPurchasing;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenDiscounts;
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
          return Scaffold(
            drawer: AppNavigationDrawer(
              selectedDestination: AppNavigationDestination.contacts,
              currentUser: currentUser,
              capabilities: capabilities,
              onOpenPos: onOpenPos,
              onOpenPurchasing: onOpenPurchasing,
              onOpenContacts: () {},
              onOpenCatalog: onOpenCatalog,
              onOpenRegisterSessions: onOpenRegisterSessions,
              onOpenDeviceSettings: onOpenDeviceSettings,
              onOpenDiscounts: onOpenDiscounts,
              onOpenUsers: onOpenUsers,
              onOpenShopSettings: onOpenShopSettings,
              onLogout: onLogout,
            ),
            appBar: AppBar(
              leading: Builder(
                builder: (context) {
                  return IconButton(
                    tooltip: l10n.navigationMenuTooltip,
                    icon: const Icon(Icons.menu),
                    onPressed: Scaffold.of(context).openDrawer,
                  );
                },
              ),
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
            body: SafeArea(
              child: AuthorizationGuard(
                capabilities: capabilities,
                capability: AppCapability.manageContacts,
                child: _ContactManagementBody(
                  viewModel: viewModel,
                  purchaseRepository: purchaseRepository,
                  capabilities: capabilities,
                ),
              ),
            ),
            floatingActionButton: AuthorizationGuard(
              capabilities: capabilities,
              capability: AppCapability.manageContacts,
              fallback: const SizedBox.shrink(),
              child: _ContactFab(viewModel: viewModel),
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

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            decoration: InputDecoration(
              hintText: l10n.contactSearchHint,
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: viewModel.updateSearch,
          ),
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

class _ContactFab extends StatelessWidget {
  const _ContactFab({required this.viewModel});

  final ContactManagementViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final controller = DefaultTabController.of(context);
    final l10n = AppLocalizations.of(context)!;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final isCustomersTab = controller.index == 0;
        return FloatingActionButton.extended(
          onPressed: viewModel.isSaving
              ? null
              : () async {
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
                },
          icon: Icon(
            isCustomersTab
                ? Icons.person_add_alt_1
                : Icons.add_business_outlined,
          ),
          label: Text(
            isCustomersTab ? l10n.addCustomerButton : l10n.addSupplierButton,
          ),
        );
      },
    );
  }
}

class _CustomerList extends StatelessWidget {
  const _CustomerList({required this.viewModel});

  final ContactManagementViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      itemCount: viewModel.customers.isEmpty ? 1 : viewModel.customers.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (viewModel.customers.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Text(l10n.emptyCustomers)),
          );
        }

        final customer = viewModel.customers[index];
        return Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: Icon(
              customer.marketingConsent
                  ? Icons.campaign_outlined
                  : Icons.person_outline,
            ),
            title: Text(customer.fullName),
            subtitle: Text(
              [
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
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
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

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      itemCount: viewModel.suppliers.isEmpty ? 1 : viewModel.suppliers.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (viewModel.suppliers.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Text(l10n.emptySuppliers)),
          );
        }

        final supplier = viewModel.suppliers[index];
        return Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.local_shipping_outlined),
            title: Text(supplier.name),
            subtitle: Text(
              [
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
                  l10n.supplierNetBalanceValue(
                    formatMoney(supplier.netBalance),
                  ),
                if (!supplier.isActive) l10n.inactiveContactLabel,
              ].join(' • '),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
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
