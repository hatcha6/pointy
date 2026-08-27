import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/purchase_submission.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../shared/navigation/app_navigation.dart';
import '../view_models/purchase_view_model.dart';
import 'purchasing_screen.dart';
import '../../../shared/components/pointy_progress.dart';

/// Hosts an isolated editing session for a single **draft** purchase order.
///
/// Editing reuses the full purchasing workspace ([PurchasingScreen]) but with a
/// dedicated, non-persisted [PurchaseViewModel] so it never disturbs the
/// long-lived "build a new purchase order" draft (which is persisted per user).
/// The order is fetched fresh by id, loaded into the workspace, and the
/// workspace returns here — popping back to where editing started — once saved.
class PurchaseOrderEditScreen extends StatefulWidget {
  const PurchaseOrderEditScreen({
    super.key,
    required this.purchaseOrderId,
    required this.catalogRepository,
    required this.purchaseRepository,
    required this.contactRepository,
    required this.analyticsEngine,
    required this.capabilities,
    required this.navigation,
  });

  final int purchaseOrderId;
  final CatalogRepository catalogRepository;
  final PurchaseRepository purchaseRepository;
  final ContactRepository contactRepository;
  final AnalyticsEngine analyticsEngine;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;

  @override
  State<PurchaseOrderEditScreen> createState() =>
      _PurchaseOrderEditScreenState();
}

enum _EditLoadState { loading, ready, loadError, notEditable }

class _PurchaseOrderEditScreenState extends State<PurchaseOrderEditScreen> {
  // A dedicated, non-persisted workspace just for this edit session — disposed
  // when the screen closes, leaving the shared "new purchase" draft untouched.
  late final PurchaseViewModel _viewModel = PurchaseViewModel(
    widget.catalogRepository,
    widget.purchaseRepository,
    analyticsEngine: widget.analyticsEngine,
  );
  _EditLoadState _state = _EditLoadState.loading;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    setState(() => _state = _EditLoadState.loading);
    // Always reload by id rather than trusting a possibly-stale list summary,
    // so the editor opens on the order's current contents.
    final result = await widget.purchaseRepository.loadPurchaseOrder(
      widget.purchaseOrderId,
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<PurchaseOrder>(:final value):
        // Same rule as the Edit buttons that lead here (and the backend):
        // the fresh fetch can still refuse when the order was received or
        // paid since the button was drawn.
        if (!value.isEditable) {
          setState(() => _state = _EditLoadState.notEditable);
          return;
        }
        await _viewModel.loadOrderForEditing(value);
        if (!mounted) {
          return;
        }
        setState(() => _state = _EditLoadState.ready);
      case Error<PurchaseOrder>():
        setState(() => _state = _EditLoadState.loadError);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_state == _EditLoadState.ready) {
      return PurchasingScreen(
        viewModel: _viewModel,
        contactRepository: widget.contactRepository,
        capabilities: widget.capabilities,
        navigation: widget.navigation,
        showBackButton: true,
        onSaved: () => Navigator.of(context).maybePop(),
      );
    }

    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: l10n.backTooltip,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.editPurchaseOrderTitle),
      ),
      body: Center(
        child: switch (_state) {
          _EditLoadState.loading => const PointySpinner(),
          _EditLoadState.notEditable => _EditLoadMessage(
            message: l10n.editPurchaseOrderNotEditableError,
          ),
          _EditLoadState.loadError => _EditLoadMessage(
            message: l10n.editPurchaseOrderLoadError,
            retryLabel: l10n.retryButton,
            onRetry: () => unawaited(_prepare()),
          ),
          _EditLoadState.ready => const SizedBox.shrink(),
        },
      ),
    );
  }
}

class _EditLoadMessage extends StatelessWidget {
  const _EditLoadMessage({
    required this.message,
    this.onRetry,
    this.retryLabel,
  });

  final String message;
  final VoidCallback? onRetry;
  final String? retryLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 40),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (onRetry != null && retryLabel != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: Text(retryLabel!)),
          ],
        ],
      ),
    );
  }
}
