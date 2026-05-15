import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/app_navigation_drawer.dart';
import '../view_models/pos_view_model.dart';
import 'pos_cart_pane.dart';
import 'pos_catalog_pane.dart';

class PosScreen extends StatelessWidget {
  const PosScreen({
    super.key,
    required this.viewModel,
    required this.onOpenCatalog,
  });

  final PosViewModel viewModel;
  final VoidCallback onOpenCatalog;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;

        return Scaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.pos,
            onOpenPos: () {},
            onOpenCatalog: onOpenCatalog,
          ),
          appBar: AppBar(
            leading: Builder(
              builder: (context) {
                return IconButton(
                  tooltip: l10n.navigationMenuTooltip,
                  onPressed: Scaffold.of(context).openDrawer,
                  icon: const Icon(Icons.menu),
                );
              },
            ),
            title: Text(l10n.appTitle),
            actions: [
              IconButton(
                tooltip: l10n.refreshCatalogTooltip,
                onPressed: viewModel.loadCatalog,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: SafeArea(child: _PosWorkspace(viewModel: viewModel)),
        );
      },
    );
  }
}

class _PosWorkspace extends StatelessWidget {
  const _PosWorkspace({required this.viewModel});

  final PosViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final catalog = PosCatalogPane(viewModel: viewModel);
        final cart = PosCartPane(viewModel: viewModel);

        if (constraints.maxWidth >= 900) {
          return Row(
            children: [
              Expanded(flex: 3, child: catalog),
              const VerticalDivider(width: 1),
              SizedBox(width: 420, child: cart),
            ],
          );
        }

        return Column(
          children: [
            Expanded(flex: 2, child: catalog),
            const Divider(height: 1),
            Expanded(flex: 3, child: cart),
          ],
        );
      },
    );
  }
}
