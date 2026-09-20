import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/error_messages.dart';
import '../../../data/models/integration_card.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../settings/views/integration_presentation.dart';
import '../view_models/integration_recharge_view_model.dart';
import 'integration_recharge_parts.dart';

/// The till's top-up flow: find a subscriber, read their subscription, and put
/// a renewal in the cart.
///
/// It sells; it does not perform. The cart line it produces records that the
/// shop took the money, and the provider side is a later, separate step — the
/// footer says so, because a cashier who believes the TV is already on will
/// tell the customer it is.
///
/// Returns the chosen [IntegrationRechargeDraft] to the POS, or null.
Future<IntegrationRechargeDraft?> showIntegrationRecharge({
  required BuildContext context,
  required IntegrationRechargeViewModel viewModel,
}) {
  // A dialog wherever there is room, a page only on a phone.
  //
  // Taking over the whole window for this on a till is wrong twice: the
  // cashier loses sight of the cart they are building, and coming back means
  // a navigation rather than a dismiss. On a phone there is no room for a
  // dialog that holds a hero, a price grid and a paginated history, so there
  // it stays a page.
  final isPhone = MediaQuery.sizeOf(context).width < AppBreakpoints.tabletMin;
  if (isPhone) {
    return Navigator.of(context).push<IntegrationRechargeDraft>(
      MaterialPageRoute<IntegrationRechargeDraft>(
        builder: (_) => IntegrationRechargeScreen(viewModel: viewModel),
      ),
    );
  }
  return showDialog<IntegrationRechargeDraft>(
    context: context,
    builder: (_) => AdaptiveDialogSurface(
      size: AdaptiveModalSize.expanded,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: IntegrationRechargeScreen(viewModel: viewModel, isDialog: true),
      ),
    ),
  );
}

class IntegrationRechargeScreen extends StatefulWidget {
  const IntegrationRechargeScreen({
    super.key,
    required this.viewModel,
    this.isDialog = false,
  });

  final IntegrationRechargeViewModel viewModel;

  /// Shown inside a dialog rather than pushed as a page. Only changes the
  /// dismiss affordance: a back arrow in a dialog reads as "go somewhere
  /// else" when the only thing it does is close.
  final bool isDialog;

  @override
  State<IntegrationRechargeScreen> createState() =>
      _IntegrationRechargeScreenState();
}

class _IntegrationRechargeScreenState extends State<IntegrationRechargeScreen> {
  final _cardController = TextEditingController();
  final _cardFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // The card field is the resting focus: a cashier's first act here is
    // always to type or scan a number, and a scanner types into whatever has
    // focus. Same rule the POS catalog search follows.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cardFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _cardController.dispose();
    _cardFocus.dispose();
    super.dispose();
  }

  void _search() {
    final value = _cardController.text.trim();
    if (value.isEmpty) return;
    widget.viewModel.lookup(value);
  }

  void _changeCard() {
    _cardController.clear();
    widget.viewModel.reset();
    _cardFocus.requestFocus();
  }

  void _addToCart() {
    final draft = widget.viewModel.buildDraft();
    if (draft == null) return;
    Navigator.of(context).pop(draft);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.isDialog,
        leading: widget.isDialog
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: l10n.integrationCancel,
                onPressed: () => Navigator.of(context).pop(),
              )
            : null,
        title: Text(l10n.rechargeTitle),
        actions: [
          AnimatedBuilder(
            animation: widget.viewModel,
            builder: (context, _) => widget.viewModel.hasCard
                ? TextButton.icon(
                    onPressed: _changeCard,
                    icon: const Icon(Icons.restart_alt),
                    label: Text(l10n.rechargeChangeCard),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
      // The footer lives in the body rather than in `bottomNavigationBar`:
      // that slot sizes to a fixed bar height, and this one grows when the
      // float warning appears.
      body: AnimatedBuilder(
        animation: widget.viewModel,
        builder: (context, _) => Column(
          children: [
            Expanded(child: _buildBody(context, l10n)),
            _buildFooter(context, l10n),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final spacing = AdaptiveSpacing.of(context);
    return ListView(
      padding: spacing.pagePadding,
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.detail,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSearchField(context, l10n),
              SizedBox(height: spacing.md),
              ..._buildState(context, l10n, spacing),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSearchField(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    return TextField(
      controller: _cardController,
      focusNode: _cardFocus,
      // Digits only: the provider rejects anything else before it even looks,
      // so the keyboard should not offer the cashier a way to get it wrong.
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textDirection: TextDirection.ltr,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _search(),
      decoration: InputDecoration(
        labelText: l10n.rechargeSearchLabel,
        hintText: l10n.rechargeSearchHint,
        prefixIcon: const Icon(Icons.sim_card_outlined),
        suffixIcon: IconButton(
          icon: viewModel.isSearching
              ? const SizedBox.square(
                  dimension: 18,
                  child: PointySpinner(strokeWidth: 2),
                )
              : const Icon(Icons.search),
          onPressed: viewModel.isSearching ? null : _search,
          tooltip: l10n.rechargeSearchAction,
        ),
      ),
    );
  }

  List<Widget> _buildState(
    BuildContext context,
    AppLocalizations l10n,
    AdaptiveSpacing spacing,
  ) {
    final viewModel = widget.viewModel;
    switch (viewModel.lookupState) {
      case RechargeLookupState.idle:
        return [
          PointyEmptyState(
            icon: Icons.sim_card_outlined,
            title: l10n.rechargeIdlePrompt,
          ),
        ];
      case RechargeLookupState.searching:
        return [
          Padding(
            padding: EdgeInsets.symmetric(vertical: spacing.xl),
            child: Column(
              children: [
                const PointySpinner(),
                SizedBox(height: spacing.sm),
                Text(l10n.rechargeSearching),
              ],
            ),
          ),
        ];
      case RechargeLookupState.refused:
        return [
          PointyErrorState(
            icon: Icons.search_off,
            title: integrationErrorText(viewModel.refusalCode, l10n),
            action: FilledButton.icon(
              onPressed: _changeCard,
              icon: const Icon(Icons.restart_alt),
              label: Text(l10n.rechargeChangeCard),
            ),
          ),
        ];
      case RechargeLookupState.failed:
        return [
          PointyErrorState(
            icon: Icons.cloud_off,
            title: errorMessageFor(viewModel.failure ?? Exception(''), l10n),
            action: FilledButton.icon(
              onPressed: _search,
              icon: const Icon(Icons.sync),
              label: Text(l10n.rechargeSearchAction),
            ),
          ),
        ];
      case RechargeLookupState.found:
        return _buildFound(context, l10n, spacing);
    }
  }

  List<Widget> _buildFound(
    BuildContext context,
    AppLocalizations l10n,
    AdaptiveSpacing spacing,
  ) {
    final viewModel = widget.viewModel;
    final snapshot = viewModel.snapshot!;
    final offers = _buildOffersSection(context, l10n, spacing);
    final history = _buildHistorySection(context, l10n, spacing);
    final isWide = MediaQuery.sizeOf(context).width >= AppBreakpoints.tabletMin;

    return [
      RechargeCardHero(card: snapshot.card, balance: snapshot.balance),
      SizedBox(height: spacing.sm),
      RechargeSubscriberStrip(
        subscriber: snapshot.subscriber,
        onName: (name) => viewModel.identifySubscriber(displayName: name),
      ),
      SizedBox(height: spacing.md),
      if (isWide)
        // Side by side once there is room: on a till the cashier wants the
        // prices and the customer's history in one glance, not one scroll.
        //
        // Deliberately no IntrinsicHeight around this. Aligning to the start
        // already lets each column be its own height, and forcing them equal
        // made the taller one overflow by a few pixels whenever its intrinsic
        // measurement disagreed with the laid-out text — for a tidiness the
        // eye cannot see, at the cost of a second layout pass.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: offers,
              ),
            ),
            SizedBox(width: spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: history,
              ),
            ),
          ],
        )
      else ...[
        ...offers,
        SizedBox(height: spacing.md),
        ...history,
      ],
    ];
  }

  List<Widget> _buildOffersSection(
    BuildContext context,
    AppLocalizations l10n,
    AdaptiveSpacing spacing,
  ) {
    final viewModel = widget.viewModel;
    final snapshot = viewModel.snapshot!;

    if (!snapshot.hasOffers) {
      return [
        PointyInlineMessage.warning(
          message: l10n.rechargeOffersUnavailable,
          compact: true,
        ),
      ];
    }

    return [
      PointyDetailSection(
        title: l10n.rechargeRenewHeading,
        icon: Icons.autorenew,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RechargeOfferGrid(
              offers: viewModel.renewalOffers,
              selected: viewModel.selectedOffer,
              onSelect: viewModel.selectOffer,
            ),
            SizedBox(height: spacing.sm),
            Text(
              l10n.rechargePriceLiveNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.pointyColors.mutedInk,
              ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _buildHistorySection(
    BuildContext context,
    AppLocalizations l10n,
    AdaptiveSpacing spacing,
  ) {
    final viewModel = widget.viewModel;
    return [
      PointyDetailSection(
        title: l10n.rechargeHistoryTitle,
        icon: Icons.history,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<IntegrationHistoryKind>(
              segments: [
                ButtonSegment(
                  value: IntegrationHistoryKind.purchases,
                  label: Text(l10n.rechargeHistoryPurchases),
                ),
                ButtonSegment(
                  value: IntegrationHistoryKind.statuses,
                  label: Text(l10n.rechargeHistoryStatuses),
                ),
              ],
              selected: {viewModel.historyKind},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  viewModel.showHistoryKind(selection.first),
            ),
            SizedBox(height: spacing.sm),
            RechargeHistoryList(
              page: viewModel.historyPage,
              isLoading: viewModel.isHistoryLoading,
              onPrevious: viewModel.previousHistoryPage,
              onNext: viewModel.nextHistoryPage,
            ),
          ],
        ),
      ),
    ];
  }

  Widget _buildFooter(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    if (!viewModel.hasCard) return const SizedBox.shrink();

    final offer = viewModel.selectedOffer;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    // A phone-width till cannot fit "12 شهراً · 245.00 د.ل" beside the button,
    // so below this the two stack instead of colliding.
    final isNarrow =
        MediaQuery.sizeOf(context).width < AppBreakpoints.tabletMin;
    final summary = offer == null
        ? l10n.rechargeSelectFirst
        : '${offer.months > 0 ? l10n.rechargeMonths(offer.months) : offer.label}'
              ' · ${formatMoney(offer.price)}';

    return SafeArea(
      top: false,
      child: Container(
        padding: EdgeInsets.all(spacing.md),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.line)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (viewModel.exceedsBalance && offer != null) ...[
              PointyInlineMessage.warning(
                message: l10n.rechargeFloatShort(
                  formatMoney(viewModel.snapshot!.balance!),
                  formatMoney(offer.cost),
                ),
                compact: true,
              ),
              SizedBox(height: spacing.sm),
            ],
            // Said every time, not once in a tooltip: a cashier who thinks the
            // subscription is already live will tell the customer so.
            Text(
              l10n.rechargePendingNote,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
            SizedBox(height: spacing.sm),
            if (isNarrow) ...[
              Text(summary, style: Theme.of(context).textTheme.titleMedium),
              SizedBox(height: spacing.sm),
              FilledButton.icon(
                onPressed: offer == null ? null : _addToCart,
                icon: const Icon(Icons.add_shopping_cart),
                label: Text(l10n.rechargeAddToCart),
              ),
            ] else
              Row(
                children: [
                  Expanded(
                    child: Text(
                      summary,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  SizedBox(width: spacing.sm),
                  FilledButton.icon(
                    onPressed: offer == null ? null : _addToCart,
                    icon: const Icon(Icons.add_shopping_cart),
                    label: Text(l10n.rechargeAddToCart),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
