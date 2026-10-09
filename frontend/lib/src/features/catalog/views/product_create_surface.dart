import 'package:flutter/material.dart';

import '../../../data/models/product.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/catalog_view_model.dart';
import 'product_form.dart';

/// Opens the new-product panel — the one creation workflow every screen uses,
/// so the catalog and a purchase order offer the same form, pins, shortcuts
/// and «إنشاء وإضافة آخر» rather than two copies drifting apart.
///
/// Completes with the product a plain create made (the panel closes on it), or
/// null when the panel was dismissed. Products made with «إنشاء وإضافة آخر»
/// keep the panel open and arrive through [onCreatedAnother] one by one.
///
/// [disposeViewModel] hands [viewModel] to the panel to dispose when it is
/// gone — for a caller that made one just for this panel. It must outlive the
/// panel's exit animation, which runs after this future has completed.
Future<Product?> showProductCreateSurface(
  BuildContext context, {
  required CatalogViewModel viewModel,
  bool disposeViewModel = false,
  String? initialBarcode,
  Product? similarTo,
  bool showOpeningStock = false,
  bool offerAddAnother = true,
  ValueChanged<Product>? onCreatedAnother,
  void Function(BuildContext panelContext, Product product)? onOpenCreated,
}) {
  return showAdaptiveFormSurface<Product?>(
    context: context,
    size: AdaptiveModalSize.standard,
    desktopPresentation: AdaptiveFormPresentation.sidePanel,
    maxHeightFactor: 0.9,
    builder: (panelContext) => _ProductCreatePanel(
      viewModel: viewModel,
      disposeViewModel: disposeViewModel,
      form: (panelContext) => ProductForm(
        viewModel: viewModel,
        initialBarcode: initialBarcode,
        similarTo: similarTo,
        showOpeningStock: showOpeningStock,
        offerAddAnother: offerAddAnother,
        onCreatedAnother: onCreatedAnother,
        onCreated: (created) =>
            Navigator.of(panelContext).pop<Product?>(created),
        onOpenCreated: onOpenCreated == null
            ? null
            : (product) => onOpenCreated(panelContext, product),
      ),
    ),
  );
}

class _ProductCreatePanel extends StatefulWidget {
  const _ProductCreatePanel({
    required this.viewModel,
    required this.disposeViewModel,
    required this.form,
  });

  final CatalogViewModel viewModel;
  final bool disposeViewModel;
  final Widget Function(BuildContext panelContext) form;

  @override
  State<_ProductCreatePanel> createState() => _ProductCreatePanelState();
}

class _ProductCreatePanelState extends State<_ProductCreatePanel> {
  @override
  void dispose() {
    if (widget.disposeViewModel) {
      widget.viewModel.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: widget.form(context),
    );
  }
}
