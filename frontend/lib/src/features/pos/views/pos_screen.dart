import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/cart_line.dart';
import '../../../data/models/product.dart';
import '../view_models/pos_view_model.dart';

String _formatMoney(double value) => 'د.ل ${value.toStringAsFixed(2)}';

class PosScreen extends StatelessWidget {
  const PosScreen({super.key, required this.viewModel});

  final PosViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;

        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.appTitle),
            actions: [
              IconButton(
                tooltip: l10n.refreshCatalogTooltip,
                onPressed: viewModel.loadCatalog,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 900;
              final catalog = _CatalogPane(viewModel: viewModel);
              final cart = _CartPane(viewModel: viewModel);

              if (isWide) {
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
          ),
        );
      },
    );
  }
}

class _CatalogPane extends StatelessWidget {
  const _CatalogPane({required this.viewModel});

  final PosViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                AppLocalizations.of(context)!.catalogTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              if (viewModel.isLoading)
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (viewModel.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                AppLocalizations.of(context)!.sampleCatalogNotice,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: viewModel.products.isEmpty && !viewModel.isLoading
                ? Center(
                    child: Text(AppLocalizations.of(context)!.emptyCatalog),
                  )
                : GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 220,
                          mainAxisExtent: 132,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                    itemCount: viewModel.products.length,
                    itemBuilder: (context, index) {
                      final product = viewModel.products[index];
                      return _ProductTile(
                        product: product,
                        onTap: () => viewModel.addProduct(product),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.product, required this.onTap});

  final Product product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(product.sku, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  product.name,
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(_formatMoney(product.unitPrice)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CartPane extends StatelessWidget {
  const _CartPane({required this.viewModel});

  final PosViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ColoredBox(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  l10n.currentSaleTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                IconButton(
                  tooltip: l10n.clearCartTooltip,
                  onPressed: viewModel.cart.isEmpty
                      ? null
                      : viewModel.clearCart,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: viewModel.cart.isEmpty
                  ? Center(child: Text(l10n.emptyCart))
                  : ListView.separated(
                      itemCount: viewModel.cart.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final line = viewModel.cart[index];
                        return _CartLineTile(
                          line: line,
                          onAdd: () => viewModel.addProduct(line.product),
                          onRemove: () =>
                              viewModel.decrementProduct(line.product),
                        );
                      },
                    ),
            ),
            _Totals(viewModel: viewModel),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: viewModel.cart.isEmpty ? null : () {},
              icon: const Icon(Icons.payments_outlined),
              label: Text(l10n.payAmount(_formatMoney(viewModel.total))),
            ),
          ],
        ),
      ),
    );
  }
}

class _CartLineTile extends StatelessWidget {
  const _CartLineTile({
    required this.line,
    required this.onAdd,
    required this.onRemove,
  });

  final CartLine line;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.product.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  l10n.unitPriceEach(_formatMoney(line.product.unitPrice)),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton.filledTonal(
            tooltip: l10n.removeOneTooltip,
            onPressed: onRemove,
            icon: const Icon(Icons.remove),
          ),
          SizedBox(width: 36, child: Center(child: Text('${line.quantity}'))),
          IconButton.filledTonal(
            tooltip: l10n.addOneTooltip,
            onPressed: onAdd,
            icon: const Icon(Icons.add),
          ),
          SizedBox(
            width: 72,
            child: Text(_formatMoney(line.total), textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.viewModel});

  final PosViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        _TotalRow(label: l10n.subtotal, value: viewModel.subtotal),
        _TotalRow(label: l10n.tax, value: viewModel.taxTotal),
        const Divider(),
        _TotalRow(label: l10n.total, value: viewModel.total, isStrong: true),
      ],
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow({
    required this.label,
    required this.value,
    this.isStrong = false,
  });

  final String label;
  final double value;
  final bool isStrong;

  @override
  Widget build(BuildContext context) {
    final style = isStrong
        ? Theme.of(context).textTheme.titleLarge
        : Theme.of(context).textTheme.bodyMedium;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(label, style: style),
          const Spacer(),
          Text(_formatMoney(value), style: style),
        ],
      ),
    );
  }
}
