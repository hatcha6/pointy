import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/app_navigation_drawer.dart';
import '../view_models/catalog_view_model.dart';
import 'product_form.dart';
import 'product_list.dart';

class CatalogScreen extends StatelessWidget {
  const CatalogScreen({
    super.key,
    required this.viewModel,
    required this.onOpenPos,
  });

  final CatalogViewModel viewModel;
  final VoidCallback onOpenPos;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return Scaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.catalog,
            onOpenPos: onOpenPos,
            onOpenCatalog: () {},
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
            title: Text(l10n.catalogManagementTitle),
            actions: [
              IconButton(
                tooltip: l10n.refreshCatalogTooltip,
                onPressed: viewModel.loadProducts,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: SafeArea(child: ProductList(viewModel: viewModel)),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _showProductForm(context),
            icon: const Icon(Icons.add),
            label: Text(l10n.addProductButton),
          ),
        );
      },
    );
  }

  Future<void> _showProductForm(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: FractionallySizedBox(
            heightFactor: 0.9,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ProductForm(
                  viewModel: viewModel,
                  onCreated: () => Navigator.of(sheetContext).pop(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
