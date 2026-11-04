import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/voucher_account.dart';
import '../../../data/models/voucher_availability.dart';
import '../../../data/models/voucher_menu.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/pos_view_model.dart';
import '../view_models/voucher_account_form_model.dart';
import 'pos_voucher_brand_sheet.dart';

/// What a sale of a card sent to an account puts on its line.
class VoucherAccountPick {
  const VoucherAccountPick({
    required this.variant,
    required this.item,
    required this.account,
    required this.subscriberRef,
    this.accountName = '',
  });

  final ProductVariant variant;
  final VoucherItem item;
  final Map<String, String> account;
  final String subscriberRef;
  final String accountName;
}

Future<VoucherAccountPick?> showPosVoucherAccountSheet(
  BuildContext context, {
  required VoucherBrand brand,
  required VoucherTarget target,
  required VoucherMenu menu,
  required PosViewModel viewModel,
  Future<VoucherAvailability?> Function()? checkAvailability,
}) {
  final repository = viewModel.serviceShelves.repository;
  return showAdaptiveModalBottomSheet<VoucherAccountPick>(
    context: context,
    size: AdaptiveModalSize.expanded,
    builder: (sheetContext) => PosVoucherAccountPicker(
      brand: brand,
      target: target,
      showsProfit: viewModel.isCostRevealed,
      customerId: viewModel.selectedCustomer?.id,
      checkAvailability: checkAvailability,
      loadSaved: repository?.loadSavedVoucherAccounts,
      check: repository?.checkVoucherAccount,
      rename: repository?.renameSavedVoucherAccount,
      forget: repository?.deleteSavedVoucherAccount,
      onPicked: (pick) => Navigator.of(sheetContext).pop(pick),
    ),
  );
}

/// A card sent to an account: whose account, then how much.
///
/// Side by side when there is room, so the shop's book and the amounts are in
/// view together and a regular's second top-up is two taps. Public and
/// callback-driven, so the preview harness and widget tests draw every state.
class PosVoucherAccountPicker extends StatefulWidget {
  const PosVoucherAccountPicker({
    super.key,
    required this.brand,
    required this.target,
    required this.onPicked,
    this.showsProfit = false,
    this.customerId,
    this.checkAvailability,
    this.loadSaved,
    this.check,
    this.rename,
    this.forget,
  });

  final VoucherBrand brand;
  final VoucherTarget target;
  final ValueChanged<VoucherAccountPick> onPicked;
  final bool showsProfit;

  /// The sale's customer, whose accounts come first.
  final int? customerId;
  final Future<VoucherAvailability?> Function()? checkAvailability;
  final Future<Result<SavedVoucherAccountPage>> Function({
    required String brand,
    String search,
    int? customer,
  })?
  loadSaved;
  final Future<Result<VoucherAccountCheck>> Function({
    required int variantId,
    required Map<String, String> values,
  })?
  check;
  final Future<Result<SavedVoucherAccount>> Function(int id, String label)?
  rename;
  final Future<Result<void>> Function(int id)? forget;

  @override
  State<PosVoucherAccountPicker> createState() =>
      _PosVoucherAccountPickerState();
}

class _PosVoucherAccountPickerState extends State<PosVoucherAccountPicker> {
  late final VoucherAccountFormModel _form;
  VoucherAvailability? _live;

  @override
  void initState() {
    super.initState();
    final items = widget.brand.items;
    _form = VoucherAccountFormModel(
      brandKey: widget.brand.key,
      target: widget.target,
      checkVariantId: items.isEmpty ? null : items.first.variantId,
      customerId: widget.customerId,
      loadSaved: widget.loadSaved,
      check: widget.check,
      rename: widget.rename,
      forget: widget.forget,
    );
    unawaited(_form.load());
    final ask = widget.checkAvailability;
    if (ask != null) {
      unawaited(_readStock(ask));
    }
    // The cashier types the ID straight away.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final first = _form.searchField;
      if (mounted && first != null) {
        _form.focusOf(first.key).requestFocus();
      }
    });
  }

  Future<void> _readStock(Future<VoucherAvailability?> Function() ask) async {
    VoucherAvailability? live;
    try {
      live = await ask();
    } on Object {
      live = null;
    }
    if (mounted) {
      setState(() => _live = (live?.ok ?? false) ? live : null);
    }
  }

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  bool _available(VoucherItem item) {
    final live = _live;
    return live == null
        ? item.available
        : live.cardFor(item.variantId)?.isAvailable ?? false;
  }

  void _pick(ProductVariant variant) {
    if (!_form.ready) {
      setState(() => _form.showProblems = true);
      final missing = _form.problems.keys.firstOrNull;
      if (missing != null && !_isSelect(missing)) {
        _form.focusOf(missing).requestFocus();
      }
      return;
    }
    final item = widget.brand.items.firstWhere(
      (item) => item.variantId == variant.id,
    );
    widget.onPicked(
      VoucherAccountPick(
        variant: variant,
        item: item,
        account: _form.values,
        subscriberRef: _form.line,
        accountName: _form.playerName,
      ),
    );
  }

  bool _isSelect(String key) =>
      widget.target.fields.any((field) => field.key == key && field.isSelect);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final brand = widget.brand;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(spacing.md, 0, spacing.md, spacing.md),
        child: ListenableBuilder(
          listenable: _form,
          builder: (context, _) {
            final account = _AccountColumn(form: _form);
            final amounts = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                VoucherSectionTitle(text: l10n.voucherAccountPickAmount),
                if (!_form.ready)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      l10n.voucherAccountEnterFirst,
                      key: const ValueKey('voucher_account_enter_first'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.pointyColors.mutedInk,
                      ),
                    ),
                  ),
                SizedBox(height: spacing.xs),
                Opacity(
                  opacity: _form.ready ? 1 : 0.55,
                  child: VoucherDenominationGrid(
                    brand: brand,
                    items: brand.items,
                    isAvailable: _available,
                    showsProfit: widget.showsProfit,
                    onPicked: _pick,
                  ),
                ),
              ],
            );
            return LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 720;
                // One height whatever the list holds: the amounts must not move
                // under the cashier's hand with each digit typed.
                final height = MediaQuery.sizeOf(context).height * 0.72;
                return SizedBox(
                  height: constraints.hasBoundedHeight
                      ? height.clamp(0, constraints.maxHeight)
                      : height,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      VoucherBrandHeader(brand: brand),
                      SizedBox(height: spacing.md),
                      Expanded(
                        child: wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    flex: 5,
                                    child: SingleChildScrollView(
                                      child: account,
                                    ),
                                  ),
                                  SizedBox(width: spacing.lg),
                                  Expanded(
                                    flex: 6,
                                    child: SingleChildScrollView(
                                      child: amounts,
                                    ),
                                  ),
                                ],
                              )
                            : SingleChildScrollView(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    account,
                                    SizedBox(height: spacing.md),
                                    amounts,
                                  ],
                                ),
                              ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _AccountColumn extends StatelessWidget {
  const _AccountColumn({required this.form});

  final VoucherAccountFormModel form;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final target = form.target;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        VoucherSectionTitle(text: l10n.voucherAccountSectionTitle),
        SizedBox(height: spacing.xs),
        for (final field in target.fields) ...[
          field.isSelect
              ? _SelectField(form: form, field: field)
              : _TextField(form: form, field: field),
          SizedBox(height: spacing.xs),
        ],
        _CheckLine(form: form),
        if (target.hint.isNotEmpty && form.chosen == null) ...[
          SizedBox(height: spacing.xs),
          Text(
            target.hint,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
        if (target.remembers) ...[
          SizedBox(height: spacing.sm),
          _SavedList(form: form),
        ],
      ],
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({required this.form, required this.field});

  final VoucherAccountFormModel form;
  final VoucherTargetField field;

  String? _problem(AppLocalizations l10n) {
    if (!form.showProblems) {
      return null;
    }
    return voucherAccountProblemText(l10n, field, form.problems[field.key]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isSearch = identical(field, form.searchField);
    return Focus(
      // Arrow keys walk the saved list without leaving the field.
      onKeyEvent: !isSearch
          ? null
          : (_, event) {
              if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                return KeyEventResult.ignored;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                return form.moveHighlight(1)
                    ? KeyEventResult.handled
                    : KeyEventResult.ignored;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                return form.moveHighlight(-1)
                    ? KeyEventResult.handled
                    : KeyEventResult.ignored;
              }
              if (event.logicalKey == LogicalKeyboardKey.enter &&
                  form.useHighlighted()) {
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
      child: TextField(
        key: ValueKey('voucher_account_field_${field.key}'),
        controller: form.controllerOf(field.key),
        focusNode: form.focusOf(field.key),
        // An ID, a username or a link reads left to right on an Arabic screen.
        textDirection: TextDirection.ltr,
        keyboardType: TextInputType.visiblePassword,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: field.label,
          hintText: isSearch && form.target.remembers
              ? l10n.voucherAccountSearchHint
              : null,
          errorText: _problem(l10n),
          errorMaxLines: 2,
          isDense: true,
          suffixIcon: form.controllerOf(field.key).text.isEmpty
              ? null
              : IconButton(
                  tooltip: l10n.voucherAccountOther,
                  onPressed: form.clear,
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
        ),
      ),
    );
  }
}

class _SelectField extends StatelessWidget {
  const _SelectField({required this.form, required this.field});

  final VoucherAccountFormModel form;
  final VoucherTargetField field;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return DropdownButtonFormField<String>(
      key: ValueKey('voucher_account_field_${field.key}'),
      initialValue: form.selectedOf(field.key),
      isDense: true,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: field.label,
        isDense: true,
        errorText: form.showProblems
            ? voucherAccountProblemText(l10n, field, form.problems[field.key])
            : null,
      ),
      items: [
        for (final option in field.options)
          DropdownMenuItem(value: option.value, child: Text(option.label)),
      ],
      onChanged: (value) => form.setSelect(field.key, value),
    );
  }
}

String? voucherAccountProblemText(
  AppLocalizations l10n,
  VoucherTargetField field,
  VoucherAccountProblem? problem,
) => switch (problem) {
  null => null,
  VoucherAccountProblem.required => l10n.voucherAccountProblemRequired(
    field.label,
  ),
  VoucherAccountProblem.tooLong => l10n.voucherAccountProblemTooLong(
    field.label,
  ),
  VoucherAccountProblem.notAChoice => l10n.voucherAccountProblemChoice(
    field.label,
  ),
  VoucherAccountProblem.notTelegram => l10n.voucherAccountProblemTelegram,
  VoucherAccountProblem.notSteamLogin => l10n.voucherAccountProblemSteamLogin,
  VoucherAccountProblem.notInvite => l10n.voucherAccountProblemInvite,
};

/// What the look-up found: the name to read back to the customer.
class _CheckLine extends StatelessWidget {
  const _CheckLine({required this.form});

  final VoucherAccountFormModel form;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    if (!form.complete) {
      return const SizedBox.shrink();
    }
    final checked = form.checked;
    final (
      IconData? icon,
      Color color,
      String text,
    ) = switch (form.checkState) {
      VoucherAccountCheckState.checking => (
        null,
        colors.mutedInk,
        l10n.voucherAccountChecking,
      ),
      VoucherAccountCheckState.done => switch (checked?.status) {
        VoucherAccountStatus.valid => (
          Icons.check_circle_rounded,
          colors.success,
          (checked?.name ?? '').isEmpty
              ? l10n.voucherAccountFoundNoName
              : l10n.voucherAccountFound(checked!.name),
        ),
        VoucherAccountStatus.invalid => (
          Icons.error_rounded,
          colors.danger,
          (checked?.detail ?? '').isNotEmpty
              ? checked!.detail
              : l10n.voucherAccountNotFound,
        ),
        VoucherAccountStatus.unchecked => (
          Icons.info_outline_rounded,
          colors.warning,
          l10n.voucherAccountNoCheck,
        ),
        _ => (
          Icons.help_outline_rounded,
          colors.warning,
          l10n.voucherAccountCouldNotTell,
        ),
      },
      VoucherAccountCheckState.failed => (
        Icons.help_outline_rounded,
        colors.warning,
        l10n.voucherAccountCouldNotTell,
      ),
      VoucherAccountCheckState.idle =>
        form.target.checkable
            ? (null, colors.mutedInk, l10n.voucherAccountChecking)
            : (
                Icons.info_outline_rounded,
                colors.warning,
                l10n.voucherAccountNoCheck,
              ),
    };
    return Row(
      key: const ValueKey('voucher_account_check_line'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null)
          Icon(icon, size: 18, color: color)
        else
          const SizedBox.square(
            dimension: 16,
            child: PointySpinner(strokeWidth: 2),
          ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

/// The shop's book for this brand: rows to scan, found by typing above.
class _SavedList extends StatelessWidget {
  const _SavedList({required this.form});

  final VoucherAccountFormModel form;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final muted = textTheme.bodySmall?.copyWith(color: colors.mutedInk);
    final saved = form.saved;
    final searching =
        (form.controllerOf(form.searchField!.key).text).isNotEmpty;
    if (saved.isEmpty) {
      if (!form.savedLoaded) {
        return const SizedBox.shrink();
      }
      return Text(
        searching && form.chosen == null
            ? l10n.voucherAccountSavedNoMatch
            : l10n.voucherAccountSavedEmpty,
        key: const ValueKey('voucher_account_saved_empty'),
        style: muted,
      );
    }
    final forCustomer =
        form.customerId != null &&
        saved.any((row) => row.customerId == form.customerId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          forCustomer
              ? l10n.voucherAccountSavedForCustomer
              : l10n.voucherAccountSavedTitle,
          style: textTheme.labelMedium?.copyWith(
            color: colors.mutedInk,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(PointyRadii.input),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(PointyRadii.input),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, account) in saved.indexed) ...[
                  if (index > 0) Divider(height: 1, color: colors.line),
                  _SavedRow(
                    key: ValueKey('voucher_saved_${account.id}'),
                    form: form,
                    account: account,
                    highlighted: index == form.highlighted,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (form.savedHasMore) ...[
          const SizedBox(height: 4),
          Text(l10n.voucherAccountSavedMore, style: muted),
        ],
      ],
    );
  }
}

class _SavedRow extends StatelessWidget {
  const _SavedRow({
    super.key,
    required this.form,
    required this.account,
    required this.highlighted,
  });

  final VoucherAccountFormModel form;
  final SavedVoucherAccount account;
  final bool highlighted;

  Future<void> _rename(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: account.label);
    final label = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.voucherAccountRenameTitle),
        content: TextField(
          key: const ValueKey('voucher_saved_rename_field'),
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n.voucherAccountRenameHint),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.voucherAccountCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(l10n.voucherAccountSave),
          ),
        ],
      ),
    );
    controller.dispose();
    if (label != null) {
      await form.renameAccount(account, label);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final chosen = form.chosen?.id == account.id;
    final title = account.title;
    final others = [
      if (account.label.isNotEmpty && account.playerName.isNotEmpty)
        account.playerName,
      if (account.useCount > 1) l10n.voucherAccountUsedTimes(account.useCount),
      // Each isolated: a Latin name beside an Arabic count must not swap them.
    ].map((part) => '\u2068$part\u2069').join(' · ');
    return Material(
      color: chosen
          ? colors.primaryContainer
          : highlighted
          ? colors.line.withValues(alpha: 0.5)
          : colors.surface,
      child: InkWell(
        onTap: () => form.use(account),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 2, 6),
          child: Row(
            children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: colors.primaryContainer,
                child: Text(
                  title.isEmpty
                      ? account.ref.substring(0, 1).toUpperCase()
                      : String.fromCharCode(title.runes.first).toUpperCase(),
                  style: textTheme.labelLarge?.copyWith(
                    color: colors.primaryDark,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title.isNotEmpty)
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: colors.ink,
                        ),
                      ),
                    Text(
                      others.isEmpty
                          ? ltrIsolated(account.ref)
                          : '${ltrIsolated(account.ref)} · $others',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: PointyTypography.numeric(
                        (textTheme.bodySmall ?? const TextStyle()).copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (chosen)
                Icon(
                  Icons.check_circle_rounded,
                  size: 20,
                  color: colors.primaryStrong,
                ),
              PopupMenuButton<VoidCallback>(
                iconSize: 18,
                padding: EdgeInsets.zero,
                icon: Icon(Icons.more_vert_rounded, color: colors.mutedInk),
                onSelected: (action) => action(),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: () => unawaited(_rename(context)),
                    child: Text(l10n.voucherAccountRename),
                  ),
                  PopupMenuItem(
                    value: () => unawaited(form.forgetAccount(account)),
                    child: Text(l10n.voucherAccountForget),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
