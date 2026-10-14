import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/exchange_rate.dart';
import '../components/components.dart';
import '../design/design.dart';
import '../formatters.dart';
import 'calculator_controller.dart';
import 'calculator_number.dart';
import 'currency_converter.dart';

/// Convert mode's display: two rows, each an amount over its currency, with
/// ⇅ between them — Calculator.app's layout. The input row shows what is
/// typed; the other the converted amount, padded to its currency's decimals.
class CalculatorConverterDisplay extends StatelessWidget {
  const CalculatorConverterDisplay({
    super.key,
    required this.controller,
    required this.converter,
    required this.focused,
    required this.copied,
    required this.onCopy,
    required this.onPickCurrency,
    required this.onTapRow,
  });

  final CalculatorController controller;
  final CurrencyConverter converter;
  final bool focused;
  final bool copied;
  final VoidCallback? onCopy;

  /// Opens the picker for the top (true) or bottom row.
  final ValueChanged<bool> onPickCurrency;

  /// A tap on the top (true) or bottom row's amount.
  final ValueChanged<bool> onTapRow;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedContainer(
          duration: PointyMotion.fast,
          decoration: BoxDecoration(
            color: colors.surfaceSunken,
            borderRadius: BorderRadius.circular(PointyRadii.input),
            border: Border.all(
              color: focused
                  ? colors.primary.withValues(alpha: 0.45)
                  : colors.surfaceSunken,
            ),
          ),
          child: converter.isReady
              ? Directionality(
                  textDirection: TextDirection.ltr,
                  child: Column(
                    children: [
                      _row(context, top: true),
                      Row(
                        children: [
                          IconButton(
                            key: const ValueKey('calculator_converter_swap'),
                            onPressed: converter.swap,
                            visualDensity: VisualDensity.compact,
                            color: colors.primaryStrong,
                            icon: Icon(
                              Icons.swap_vert_rounded,
                              semanticLabel: l10n.calculatorSwapCurrencies,
                            ),
                          ),
                          Expanded(
                            child: Divider(height: 1, color: colors.line),
                          ),
                          const SizedBox(width: 14),
                        ],
                      ),
                      _row(context, top: false),
                    ],
                  ),
                )
              : _ConverterUnavailable(converter: converter),
        ),
        if (converter.isReady) ...[
          const SizedBox(height: 6),
          ConverterRateLine(converter: converter),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, {required bool top}) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;
    final isInput = converter.inputIsTop == top;
    final code = top ? converter.topCode! : converter.bottomCode!;
    final currency = converter.currency(code)!;

    final String text;
    final Color color;
    if (isInput) {
      final error = controller.error;
      if (error != null) {
        text = switch (error) {
          CalculatorErrorKind.undefined => l10n.calculatorUndefined,
          CalculatorErrorKind.overflow => l10n.calculatorTooLarge,
        };
        color = colors.danger;
      } else if (controller.result != null) {
        text = controller.result!.format();
        color = colors.ink;
      } else {
        final typed = controller.expressionText;
        text = typed.isEmpty ? '0' : typed;
        color = typed.isEmpty ? colors.mutedInk : colors.ink;
      }
    } else {
      final converted = converter.convertRounded(
        controller.conversionInput ?? CalculatorNumber.zero,
      );
      text = controller.error != null || converted == null
          ? '—'
          : converted.formatMoney(currency.decimals);
      color = colors.primaryStrong;
    }

    final style = PointyTypography.numeric(
      theme.textTheme.headlineSmall!.copyWith(
        color: color,
        fontWeight: isInput ? FontWeight.w700 : FontWeight.w800,
        height: 1.15,
      ),
    );

    return InkWell(
      key: ValueKey('calculator_converter_row_${top ? 'top' : 'bottom'}'),
      canRequestFocus: false,
      borderRadius: BorderRadius.circular(PointyRadii.input),
      onTap: () => onTapRow(top),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Copy sits beside the converted amount — the answer.
            SizedBox(
              width: 40,
              child: isInput
                  ? null
                  : IconButton(
                      key: const ValueKey('floating_calculator_copy'),
                      onPressed: onCopy,
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      color: copied ? colors.success : colors.mutedInk,
                      icon: Icon(
                        copied ? Icons.check_rounded : Icons.copy_rounded,
                        semanticLabel: copied
                            ? l10n.calculatorCopied
                            : l10n.calculatorCopy,
                      ),
                    ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: isInput && controller.result == null
                        ? SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            reverse: true,
                            child: Text(
                              ltrIsolated(text),
                              key: ValueKey(
                                'calculator_converter_value_${top ? 'top' : 'bottom'}',
                              ),
                              maxLines: 1,
                              softWrap: false,
                              style: style,
                            ),
                          )
                        : FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Text(
                              ltrIsolated(text),
                              key: ValueKey(
                                'calculator_converter_value_${top ? 'top' : 'bottom'}',
                              ),
                              maxLines: 1,
                              style: style,
                            ),
                          ),
                  ),
                  const SizedBox(height: 4),
                  _CurrencyChip(
                    key: ValueKey(
                      'calculator_currency_${top ? 'top' : 'bottom'}',
                    ),
                    currency: currency,
                    emphasised: isInput,
                    onTap: () => onPickCurrency(top),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrencyChip extends StatelessWidget {
  const _CurrencyChip({
    super.key,
    required this.currency,
    required this.emphasised,
    required this.onTap,
  });

  final ConverterCurrency currency;
  final bool emphasised;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    return Semantics(
      button: true,
      label: '${currency.name} ${currency.code}',
      excludeSemantics: true,
      child: Material(
        color: emphasised ? colors.primaryContainer : colors.subtleFill,
        borderRadius: BorderRadius.circular(PointyRadii.pill),
        child: InkWell(
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(PointyRadii.pill),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 3, 6, 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  currency.code,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: emphasised ? colors.primaryStrong : colors.ink,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.unfold_more_rounded,
                  size: 16,
                  color: emphasised ? colors.primaryStrong : colors.mutedInk,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Loading, failed, or nothing to convert with — in place of the two rows.
class _ConverterUnavailable extends StatelessWidget {
  const _ConverterUnavailable({required this.converter});

  final CurrencyConverter converter;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final loading =
        converter.status == ConverterStatus.loading ||
        converter.status == ConverterStatus.idle;
    final message = loading
        ? l10n.calculatorRatesLoading
        : converter.status == ConverterStatus.failed
        ? l10n.calculatorRatesUnavailable
        : l10n.exchangeRatesEmpty;
    return Padding(
      key: const ValueKey('calculator_converter_unavailable'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
      child: Column(
        children: [
          if (loading)
            const SizedBox.square(
              dimension: 22,
              child: PointySpinner(strokeWidth: 2.4),
            )
          else
            Icon(Icons.currency_exchange_rounded, color: colors.mutedInk),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
          ),
          if (!loading) ...[
            const SizedBox(height: 6),
            TextButton.icon(
              key: const ValueKey('calculator_converter_retry'),
              onPressed: () => converter.refresh(force: true),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(l10n.calculatorRatesRetry),
            ),
          ],
        ],
      ),
    );
  }
}

/// Under the rows: the rates the conversion rests on, where they came from
/// and how old they are — "1 USD = 7.15 LYD · نقدًا · منذ 2 ساعة" — plus
/// refresh. An old rate still converts but says "سعر قديم"; a failed refresh
/// says the last known rates are in use.
class ConverterRateLine extends StatelessWidget {
  const ConverterRateLine({super.key, required this.converter});

  final CurrencyConverter converter;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final rates = converter.rates!;
    final pair = converter.pairRates;
    final stale = pair.any((rate) => rate.isStale);
    final substituted = pair.where((rate) => rate.isSubstituted);
    final manual = pair.any((rate) => rate.source == RateSource.manual);
    final oldest = pair.fold<double>(
      0,
      (age, rate) => rate.ageHours > age ? rate.ageHours : age,
    );
    final quotes = pair
        .map(
          (rate) => ltrIsolated(
            '1 ${rate.code} = ${rate.valueInBase.format(maxFractionDigits: 6)} ${rates.baseCode}',
          ),
        )
        .join('  ');
    final source = manual
        ? l10n.exchangeRateSourceManual
        : rates.instrument == SettlementInstrument.bank
        ? l10n.settlementInstrumentBank
        : l10n.settlementInstrumentCash;
    final age = oldest >= 48
        ? l10n.exchangeRateAgeDays((oldest / 24).round())
        : l10n.exchangeRateAgeHours(oldest.round());

    final small = theme.textTheme.labelSmall!;
    return Column(
      key: const ValueKey('calculator_converter_rate_line'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    if (stale)
                      TextSpan(
                        text: '${l10n.exchangeRateStaleBadge} · ',
                        style: TextStyle(
                          color: colors.warning,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    TextSpan(text: '$quotes · $source · $age'),
                  ],
                ),
                maxLines: 2,
                style: small.copyWith(
                  color: stale ? colors.warning : colors.mutedInk,
                ),
              ),
            ),
            SizedBox.square(
              dimension: 30,
              child: converter.status == ConverterStatus.loading
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: PointySpinner(strokeWidth: 2),
                    )
                  : IconButton(
                      key: const ValueKey('calculator_converter_refresh'),
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      color: colors.mutedInk,
                      onPressed: () => converter.refresh(force: true),
                      icon: Icon(
                        Icons.refresh_rounded,
                        semanticLabel: l10n.calculatorRatesRefresh,
                      ),
                    ),
            ),
          ],
        ),
        if (converter.lastRefreshFailed)
          Text(
            l10n.exchangeRatesSyncError,
            key: const ValueKey('calculator_converter_refresh_failed'),
            style: small.copyWith(color: colors.warning),
          ),
        for (final rate in substituted)
          Text(
            l10n.exchangeRateSubstitutedWarning(
              rate.instrument == SettlementInstrument.bank
                  ? l10n.settlementInstrumentBank
                  : l10n.settlementInstrumentCash,
            ),
            style: small.copyWith(color: colors.warning),
          ),
      ],
    );
  }
}

/// The currency picker, as a sheet inside the panel: search (Arabic or
/// English name, code or symbol — Arabic letter variants folded), recently
/// used first, the other row's currency greyed out, a "no results" state
/// like Apple's. ↑/↓ move, Enter picks, Esc closes.
class CurrencyPickerSheet extends StatefulWidget {
  const CurrencyPickerSheet({
    super.key,
    required this.converter,
    required this.top,
    required this.onPicked,
    required this.onClose,
  });

  final CurrencyConverter converter;

  /// Which row the pick is for.
  final bool top;
  final VoidCallback onPicked;
  final VoidCallback onClose;

  @override
  State<CurrencyPickerSheet> createState() => _CurrencyPickerSheetState();
}

class _CurrencyPickerSheetState extends State<CurrencyPickerSheet> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _search = FocusNode(debugLabel: 'calculator_currency_search');
  int _highlight = 0;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() => _highlight = 0));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _search.requestFocus();
    });
  }

  @override
  void dispose() {
    _query.dispose();
    _search.dispose();
    super.dispose();
  }

  List<ConverterCurrency> get _all =>
      widget.converter.rates?.currencies ?? const [];

  List<ConverterCurrency> get _matches {
    final query = foldForSearch(_query.text);
    if (query.isEmpty) {
      return _all;
    }
    return _all.where((c) {
      final haystack = foldForSearch(
        '${c.code} ${c.nameAr} ${c.nameEn} ${c.symbol}',
      );
      return query.split(' ').every(haystack.contains);
    }).toList();
  }

  List<ConverterCurrency> get _recents => _query.text.trim().isNotEmpty
      ? const []
      : [
          for (final code in widget.converter.recents)
            if (widget.converter.currency(code) != null)
              widget.converter.currency(code)!,
        ];

  /// Every row in screen order: recents (when not searching), then the
  /// matches. A recent currency appears twice, as a separate row each time.
  List<ConverterCurrency> get _rows => [..._recents, ..._matches];

  /// Positions in [_rows] that ↑/↓/Enter walk: the ones that can be picked.
  List<int> get _selectable => [
    for (final (index, c) in _rows.indexed)
      if (widget.converter.canPick(c.code, top: widget.top)) index,
  ];

  void _pick(ConverterCurrency currency) {
    if (widget.converter.pick(currency.code, top: widget.top)) {
      widget.onPicked();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final selectable = _selectable;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown && selectable.isNotEmpty) {
      setState(() => _highlight = (_highlight + 1) % selectable.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp && selectable.isNotEmpty) {
      setState(
        () => _highlight =
            (_highlight - 1 + selectable.length) % selectable.length,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final recents = _recents;
    final matches = _matches;
    final rows = _rows;
    final selectable = _selectable;
    final highlightedIndex = selectable.isEmpty
        ? null
        : selectable[_highlight.clamp(0, selectable.length - 1)];
    final highlighted = highlightedIndex == null
        ? null
        : rows[highlightedIndex];
    final current = widget.top
        ? widget.converter.topCode
        : widget.converter.bottomCode;

    Widget row(int index) {
      final currency = rows[index];
      final enabled = widget.converter.canPick(currency.code, top: widget.top);
      final selected = currency.code == current;
      final active = index == highlightedIndex;
      return Material(
        color: active ? colors.subtleFill : Colors.transparent,
        child: InkWell(
          key: ValueKey('calculator_currency_option_${currency.code}'),
          canRequestFocus: false,
          onTap: enabled ? () => _pick(currency) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        currency.name,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: !enabled
                              ? colors.mutedInk.withValues(alpha: 0.6)
                              : selected
                              ? colors.primaryStrong
                              : colors.ink,
                        ),
                      ),
                      Text(
                        enabled
                            ? ltrIsolated(
                                '${currency.code} · ${currency.symbol}',
                              )
                            : l10n.calculatorCurrencyOtherSide,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.mutedInk.withValues(
                            alpha: enabled ? 1 : 0.6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Icon(
                    Icons.check_rounded,
                    size: 20,
                    color: colors.primaryStrong,
                  ),
              ],
            ),
          ),
        ),
      );
    }

    Widget section(String title) => Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 2),
      child: Text(
        title,
        style: theme.textTheme.labelSmall?.copyWith(
          color: colors.mutedInk,
          fontWeight: FontWeight.w800,
        ),
      ),
    );

    return Material(
      key: const ValueKey('calculator_currency_picker'),
      color: colors.surface,
      elevation: 8,
      shadowColor: colors.shadow,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            onVerticalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) > 0) widget.onClose();
            },
            child: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 6),
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.lineStrong,
                    borderRadius: BorderRadius.circular(PointyRadii.pill),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Focus(
              onKeyEvent: _onKey,
              child: TextField(
                key: const ValueKey('calculator_currency_search'),
                controller: _query,
                focusNode: _search,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (highlighted != null) _pick(highlighted);
                },
                decoration: InputDecoration(
                  isDense: true,
                  hintText: l10n.calculatorCurrencySearch,
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _query.text.isEmpty
                      ? null
                      : IconButton(
                          onPressed: _query.clear,
                          icon: const Icon(Icons.cancel_rounded, size: 18),
                        ),
                ),
              ),
            ),
          ),
          Divider(height: 1, color: colors.line),
          Expanded(
            child: matches.isEmpty
                ? _NoResults(query: _query.text.trim())
                : ListView(
                    padding: const EdgeInsets.only(bottom: 6),
                    children: [
                      if (recents.isNotEmpty) ...[
                        section(l10n.calculatorCurrencyRecent),
                        for (var i = 0; i < recents.length; i++) row(i),
                        section(l10n.calculatorCurrencyAll),
                      ],
                      for (var i = recents.length; i < rows.length; i++) row(i),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  const _NoResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    return Center(
      key: const ValueKey('calculator_currency_no_results'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_rounded, size: 32, color: colors.mutedInk),
            const SizedBox(height: 8),
            Text(
              l10n.calculatorCurrencyNoResults(query),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.calculatorCurrencyNoResultsHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lower-case, Arabic letter variants folded (أ إ آ → ا, ة → ه, ى → ي),
/// diacritics and tatweel dropped — so "دينار", "الدينار" and "Dinar" all
/// find the dinar however they were typed.
String foldForSearch(String text) {
  final buffer = StringBuffer();
  for (final rune in text.trim().toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    if ((rune >= 0x064B && rune <= 0x065F) ||
        rune == 0x0670 ||
        rune == 0x0640) {
      continue;
    }
    buffer.write(switch (char) {
      'أ' || 'إ' || 'آ' || 'ٱ' => 'ا',
      'ة' => 'ه',
      'ى' => 'ي',
      _ => char,
    });
  }
  return buffer.toString().replaceAll(RegExp(r'\s+'), ' ');
}
