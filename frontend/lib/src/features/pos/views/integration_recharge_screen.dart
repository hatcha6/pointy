import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/error_messages.dart';
import '../../../data/models/integration_card.dart';
import '../../../data/models/integration_provider.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/query_controls/debounced_search_field.dart';
import '../../../shared/responsive/responsive.dart';
import '../../settings/views/integration_presentation.dart';
import '../view_models/integration_recharge_view_model.dart';
import 'integration_recent_searches.dart';
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
  final _cardFocus = FocusNode();

  /// Empties the search box outright, including keystrokes its debounce has
  /// not reported yet — which telling it "the text is now empty" cannot do
  /// when the view model already believes it is.
  final _clearBox = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    // The screen opens on what was searched before, not on an empty box.
    widget.viewModel.recentSearches.load();
    // The card field is the resting focus: a cashier's first act here is
    // always to type or scan a number, and a scanner types into whatever has
    // focus. Same rule the POS catalog search follows.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cardFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _clearBox.dispose();
    _cardFocus.dispose();
    super.dispose();
  }

  /// Ask the provider. Keeps the text in the box, so the cashier can see
  /// what was searched while the answer comes back.
  bool _search(String value) {
    final term = value.trim();
    if (term.isNotEmpty) widget.viewModel.lookup(term);
    return false;
  }

  void _changeCard() {
    _clearBox.value++;
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
        animation: Listenable.merge([
          widget.viewModel,
          widget.viewModel.recentSearches,
        ]),
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
    final viewModel = widget.viewModel;
    return Column(
      children: [
        // Pinned above whatever is below it, not scrolled with it. It is how
        // every state on this screen is left, and it must not live inside the
        // recent-searches list: that list's loading, empty and loaded states
        // are different trees, and each would build the box from scratch —
        // dropping the very text whose typing had changed the state.
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            spacing.pageHorizontal,
            spacing.pageVertical,
            spacing.pageHorizontal,
            spacing.sm,
          ),
          child: AdaptiveMaxWidth(
            width: AppContentWidth.detail,
            child: _buildSearchField(context, l10n),
          ),
        ),
        Expanded(
          child: viewModel.lookupState == RechargeLookupState.idle
              ? RechargeRecentSearches(
                  viewModel: viewModel.recentSearches,
                  provider: viewModel.provider,
                  onRun: viewModel.runRecentSearch,
                  onLookUp: viewModel.lookup,
                )
              : ListView(
                  padding: EdgeInsetsDirectional.fromSTEB(
                    spacing.pageHorizontal,
                    spacing.sm,
                    spacing.pageHorizontal,
                    spacing.pageVertical,
                  ),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    AdaptiveMaxWidth(
                      width: AppContentWidth.detail,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _buildState(context, l10n, spacing),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildSearchField(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final prompt = integrationSubscriberPrompt(viewModel.provider, l10n);
    // The picker says which number this is, so the hint saying "phone or
    // username or contract" would be repeating it — and on a phone-width
    // till the two together leave the hint as an ellipsis.
    final hasPicker = viewModel.searchModes.length >= 2;
    // Debounced: typing narrows the recent searches below once the cashier
    // pauses, and only the search key or the button asks the provider — a
    // lookup costs seconds against somebody else's portal, a filter does not.
    return DebouncedSearchField(
      value: viewModel.searchText,
      focusNode: _cardFocus,
      resetSignal: _clearBox,
      onChanged: viewModel.setSearchText,
      onSubmitted: _search,
      clearTooltip: l10n.queryClearSearchButton,
      // A username has letters in it; a phone number and a contract number do
      // not, and a digits-only field is what stops a cashier mistyping one.
      // So the keyboard follows the picker rather than being fixed.
      keyboardType: viewModel.allowsLetters
          ? TextInputType.text
          : TextInputType.number,
      inputFormatters: viewModel.allowsLetters
          ? const []
          : [FilteringTextInputFormatter.digitsOnly],
      textDirection: TextDirection.ltr,
      // The label says what the field holds; the picker says which kind
      // this one is. Repeating the mode in both reads as a bug, and the
      // hint repeating it a third time is what left it as an ellipsis.
      labelText: prompt.label,
      hintText: hasPicker ? '' : prompt.hint,
      prefix: _buildSearchModePicker(context, l10n),
      // The picker is a control, not an icon, so it needs room to be one —
      // but only it does. A plain icon keeps the default box, or it ends up
      // squashed against the border on every provider that has no picker.
      prefixConstraints: hasPicker
          ? const BoxConstraints(minWidth: 0, minHeight: 0)
          : null,
      trailingBuilder: (context, submit) => IconButton(
        icon: viewModel.isSearching
            ? const SizedBox.square(
                dimension: 18,
                child: PointySpinner(strokeWidth: 2),
              )
            : const Icon(Icons.search),
        onPressed: viewModel.isSearching ? null : submit,
        tooltip: l10n.rechargeSearchAction,
      ),
    );
  }

  /// What the cashier says the number IS, in front of the box they type it in.
  ///
  /// The person holding the number knows whether it is a phone number or a
  /// contract number; the server cannot tell — they are both digits — and
  /// guessing costs it a round trip to the portal per wrong guess, measured
  /// at three trips and ~4.4s on a real till. So the till asks, once, and the
  /// ordinary lookup becomes a single request.
  ///
  /// Shown only where the provider really offers a choice: HD Box knows a
  /// subscriber by the number on their card and nothing else, and a picker
  /// with one row in it is worse than no picker.
  Widget _buildSearchModePicker(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final modes = viewModel.searchModes;
    if (modes.length < 2) return const Icon(Icons.sim_card_outlined);

    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final selected = integrationSearchModeLabel(viewModel.searchMode, l10n);
    return Padding(
      padding: EdgeInsetsDirectional.only(start: spacing.sm, end: spacing.xs),
      child: PopupMenuButton<IntegrationSearchMode>(
        key: const ValueKey('recharge_search_mode_picker'),
        tooltip: l10n.rechargeSearchByLabel,
        enabled: !viewModel.isSearching,
        initialValue: viewModel.searchMode,
        onSelected: (mode) {
          viewModel.selectSearchMode(mode);
          // The field's formatter changes with the pick, and a contract
          // number left in the box when the cashier switches to "username"
          // is not what they are about to search for.
          _clearBox.value++;
          _cardFocus.requestFocus();
        },
        itemBuilder: (context) => [
          for (final mode in modes)
            PopupMenuItem<IntegrationSearchMode>(
              value: mode,
              child: Row(
                children: [
                  Icon(integrationSearchModeLabel(mode, l10n).icon, size: 18),
                  SizedBox(width: spacing.sm),
                  Text(integrationSearchModeLabel(mode, l10n).label),
                ],
              ),
            ),
        ],
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(selected.icon, size: 20, color: theme.colorScheme.primary),
            SizedBox(width: spacing.xs),
            Text(
              selected.label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            Icon(
              Icons.arrow_drop_down,
              size: 20,
              color: theme.colorScheme.primary,
            ),
          ],
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
        // Never reached: while nothing is looked up the body is the recent
        // searches, which carries the "type or scan" prompt when it is empty.
        return const [];
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
              onPressed: viewModel.retry,
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

    if (viewModel.needsLineSelection) {
      // Several lines matched. Nothing is priced and nothing is in a cart yet
      // — the hero would have to pick one line to describe, and picking is
      // exactly what has not happened.
      return [
        RechargeLinePicker(
          lines: viewModel.candidates,
          onSelect: viewModel.selectLine,
        ),
      ];
    }

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

    // No buttons is only a problem when buttons are all there is. An
    // open-amount provider whose owner cleared the quick-picks is saying "we
    // always type it", and the field below is still there — warning would be
    // telling a cashier the provider is broken when it is working.
    if (!snapshot.hasOffers && !snapshot.allowsOpenAmount) {
      return [
        PointyInlineMessage.warning(
          message: l10n.rechargeOffersUnavailable,
          compact: true,
        ),
      ];
    }

    final openAmount = viewModel.openAmount;
    final isTopUp = openAmount != null;
    return [
      PointyDetailSection(
        title: isTopUp ? l10n.rechargeTopUpHeading : l10n.rechargeRenewHeading,
        icon: isTopUp ? Icons.account_balance_wallet_outlined : Icons.autorenew,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RechargeOfferGrid(
              offers: viewModel.sellableOffers,
              selected: viewModel.selectedOffer,
              onSelect: viewModel.selectOffer,
            ),
            if (openAmount != null) ...[
              SizedBox(height: spacing.sm),
              RechargeAmountField(
                spec: openAmount,
                value: viewModel.customAmount,
                problem: viewModel.customAmountProblem,
                onChanged: viewModel.setCustomAmount,
              ),
            ],
            SizedBox(height: spacing.sm),
            Text(
              isTopUp ? l10n.rechargeTopUpNote : l10n.rechargePriceLiveNote,
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
            // Only the feeds this provider really has. LNET keeps no state
            // log, and one tab is a label, not a choice.
            if (viewModel.hasStatusHistory) ...[
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
            ],
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
    // A stored-value top-up is one number, not a thing plus its price: "37
    // LYD · 37.00 د.ل" says the same figure twice in two notations.
    final summary = switch (offer) {
      // While several lines are still on offer nothing has been priced, so
      // naming a duration or an amount would be asking for the wrong thing.
      null when viewModel.needsLineSelection => l10n.rechargeChooseLineHeading,
      null =>
        viewModel.allowsCustomAmount
            ? l10n.rechargeSelectAmountFirst
            : l10n.rechargeSelectFirst,
      final chosen when chosen.months > 0 =>
        '${l10n.rechargeMonths(chosen.months)} · ${formatMoney(chosen.price)}',
      final chosen when chosen.isTopUp => formatMoney(chosen.price),
      final chosen => '${chosen.label} · ${formatMoney(chosen.price)}',
    };

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
