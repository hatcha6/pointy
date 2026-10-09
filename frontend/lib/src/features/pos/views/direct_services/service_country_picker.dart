import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/services_directory.dart';
import '../../../../shared/barcode/barcode_scan_listener.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/responsive/responsive.dart';
import '../../direct_services/country_search.dart';
import 'service_flag.dart';
import 'service_text_scale.dart';

/// Choosing a country the way a cashier looks for one.
///
/// One box takes the name in whatever spelling comes to hand, a two-letter
/// code, or the first digits of the calling code — `223` finds Mali, `1`
/// offers the United States and Canada. With nothing typed the popular
/// countries are on show as flags, then every country A to Z. A country the
/// services do not reach is still answered by name, greyed with the reason.
///
/// Public and parameter-driven, so the airtime pane, every bill flow and the
/// preview harness draw the same picker.
class ServiceCountryPicker extends StatefulWidget {
  const ServiceCountryPicker({
    super.key,
    required this.search,
    required this.onSelected,
    this.selectedCode,
    this.providerCount,
    this.showDial = true,
    this.tileRows = false,
    this.showSearch,
    this.autofocus = true,
    this.focusNode,
    this.maxHeight = 300,
    this.onCancel,
  });

  final CountrySearch search;
  final ValueChanged<ServiceCountry> onSelected;

  /// The country already chosen, marked in the list.
  final String? selectedCode;

  /// How many providers a country has, for the line under its name — bills.
  final int? Function(String code)? providerCount;

  /// Show each country's calling code (`+223`) at the end of its row.
  final bool showDial;

  /// Draw each country as a bordered tile with an arrow — a short list to
  /// choose one from — instead of a plain row of a long one.
  final bool tileRows;

  /// Show the search box; by default only when there are more than eight
  /// countries to choose from.
  final bool? showSearch;
  final bool autofocus;
  final FocusNode? focusNode;

  /// The most height the list takes; it scrolls inside it.
  final double maxHeight;

  /// Closes the picker without choosing, when it replaced a chosen country.
  final VoidCallback? onCancel;

  @override
  State<ServiceCountryPicker> createState() => _ServiceCountryPickerState();
}

class _ServiceCountryPickerState extends State<ServiceCountryPicker> {
  final TextEditingController _controller = TextEditingController();
  FocusNode? _ownFocus;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  bool get _hasSearch =>
      widget.showSearch ?? widget.search.countries.length > 8;

  @override
  void dispose() {
    _controller.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  void _submit(CountrySearchResult result) {
    final best = result.best;
    if (best != null) {
      widget.onSelected(best);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final result = widget.search.search(_controller.text);
    final children = _items(context, result);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_hasSearch || widget.onCancel != null) ...[
          Row(
            children: [
              if (_hasSearch)
                Expanded(
                  child: ScanWedgeTarget(
                    child: TextField(
                      key: const ValueKey('service_country_search'),
                      controller: _controller,
                      focusNode: _focus,
                      autofocus: widget.autofocus,
                      textInputAction: TextInputAction.search,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _submit(result),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: l10n.posServicesCountrySearchHint,
                        hintMaxLines: 1,
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _controller.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: l10n.clearButton,
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () {
                                  _controller.clear();
                                  setState(() {});
                                  _focus.requestFocus();
                                },
                              ),
                      ),
                    ),
                  ),
                )
              else
                const Spacer(),
              if (widget.onCancel != null) ...[
                SizedBox(width: spacing.xs),
                TextButton(
                  key: const ValueKey('service_country_cancel'),
                  onPressed: widget.onCancel,
                  child: Text(l10n.cancelButton),
                ),
              ],
            ],
          ),
          SizedBox(height: spacing.sm),
        ],
        if (result.isDialQuery && result.matches.isNotEmpty) ...[
          _DialHint(result: result),
          SizedBox(height: spacing.xs),
        ],
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxHeight),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: children.length,
              itemBuilder: (context, index) => children[index],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _items(BuildContext context, CountrySearchResult result) {
    final l10n = AppLocalizations.of(context)!;
    if (result.isEmpty) {
      final popular = widget.search.popularCountries;
      return [
        if (popular.isNotEmpty && widget.search.countries.length > 8) ...[
          _SectionTitle(l10n.posServicesCountryPopular),
          _PopularGrid(
            countries: popular,
            selectedCode: widget.selectedCode,
            onSelected: widget.onSelected,
          ),
          _SectionTitle(l10n.posServicesCountryAll),
        ],
        for (final country in widget.search.alphabetical)
          _CountryRow(
            country: country,
            selected: country.code == widget.selectedCode,
            showDial: widget.showDial,
            tile: widget.tileRows,
            providerCount: widget.providerCount?.call(country.code),
            onTap: () => widget.onSelected(country),
          ),
      ];
    }
    return [
      for (final match in result.matches)
        _CountryRow(
          country: match.country,
          selected: match.country.code == widget.selectedCode,
          showDial: widget.showDial,
          tile: widget.tileRows,
          highlightDial: match.dial,
          providerCount: widget.providerCount?.call(match.country.code),
          onTap: () => widget.onSelected(match.country),
        ),
      for (final country in result.unsupported)
        _UnsupportedRow(country: country),
      if (result.hasNoAnswer)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Text(
            l10n.posServicesCountryNoResults,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.pointyColors.mutedInk,
            ),
          ),
        ),
    ];
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: context.pointyColors.mutedInk,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The calling code the digits typed lead to, so the cashier sees why a
/// country is first — and is told when a code is shared.
class _DialHint extends StatelessWidget {
  const _DialHint({required this.result});

  final CountrySearchResult result;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final first = result.matches.first;
    final shared =
        first.kind == CountryMatchKind.dialExact &&
        result.matches.length > 1 &&
        result.matches[1].kind == CountryMatchKind.dialExact;
    final text = switch ((first.kind, shared)) {
      (CountryMatchKind.dialExact, true) => l10n.posServicesCountrySharedCode(
        first.dial,
      ),
      (CountryMatchKind.dialExact, false) ||
      (
        CountryMatchKind.dialPrefixOfInput,
        _,
      ) => l10n.posServicesCountryDialMatch(first.dial, first.country.label),
      _ => null,
    };
    if (text == null) {
      return const SizedBox.shrink();
    }
    return Row(
      children: [
        Icon(Icons.dialpad_rounded, size: 16, color: colors.primaryStrong),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: colors.primaryStrong,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _PopularGrid extends StatelessWidget {
  const _PopularGrid({
    required this.countries,
    required this.selectedCode,
    required this.onSelected,
  });

  final List<ServiceCountry> countries;
  final String? selectedCode;
  final ValueChanged<ServiceCountry> onSelected;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // As many tiles across as fit at 84 wide or more, sharing the width.
        const gap = 8.0;
        final columns = constraints.maxWidth.isFinite
            ? ((constraints.maxWidth + gap) / (84 + gap)).floor().clamp(2, 6)
            : 3;
        final width = constraints.maxWidth.isFinite
            ? (constraints.maxWidth - gap * (columns - 1)) / columns
            : 96.0;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final country in countries)
              _PopularTile(
                key: ValueKey('service_country_popular_${country.code}'),
                country: country,
                width: width,
                selected: country.code == selectedCode,
                onTap: () => onSelected(country),
              ),
          ],
        );
      },
    );
  }
}

class _PopularTile extends StatelessWidget {
  const _PopularTile({
    super.key,
    required this.country,
    required this.width,
    required this.selected,
    required this.onTap,
  });

  final ServiceCountry country;
  final double width;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Semantics(
      button: true,
      selected: selected,
      label: country.label,
      child: ExcludeSemantics(
        child: Material(
          color: selected ? colors.primaryContainer : colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PointyRadii.input),
            side: BorderSide(
              color: selected ? colors.primaryStrong : colors.line,
              width: selected ? 1.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: width,
              height: textBoundExtent(context, 68),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ServiceFlag(code: country.code, width: 36, height: 24),
                    const SizedBox(height: 6),
                    Text(
                      country.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: selected ? colors.primaryDark : colors.ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CountryRow extends StatelessWidget {
  const _CountryRow({
    required this.country,
    required this.selected,
    required this.showDial,
    required this.onTap,
    this.tile = false,
    this.providerCount,
    this.highlightDial = '',
  });

  final ServiceCountry country;
  final bool selected;
  final bool showDial;
  final bool tile;
  final int? providerCount;
  final String highlightDial;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final dial = highlightDial.isNotEmpty ? highlightDial : country.primaryDial;
    return Semantics(
      button: true,
      selected: selected,
      label: country.label,
      child: ExcludeSemantics(
        child: InkWell(
          key: ValueKey('service_country_${country.code}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(PointyRadii.chip),
          child: Container(
            constraints: BoxConstraints(minHeight: tile ? 58 : 46),
            margin: tile ? const EdgeInsets.only(bottom: 8) : null,
            padding: EdgeInsets.symmetric(
              horizontal: tile ? 12 : 10,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? colors.primaryContainer
                  : (tile ? colors.surface : null),
              borderRadius: BorderRadius.circular(
                tile ? PointyRadii.input : PointyRadii.chip,
              ),
              border: tile
                  ? Border.all(
                      color: selected ? colors.primaryStrong : colors.line,
                      width: selected ? 1.5 : 1,
                    )
                  : null,
            ),
            child: Row(
              children: [
                ServiceFlag(code: country.code),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        country.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(
                          color: colors.ink,
                          fontWeight: selected
                              ? FontWeight.w800
                              : FontWeight.w600,
                        ),
                      ),
                      if (providerCount != null)
                        Text(
                          l10n.posServicesProvidersCount(providerCount!),
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.mutedInk,
                          ),
                        ),
                    ],
                  ),
                ),
                if (showDial && dial.isNotEmpty)
                  Text(
                    '+$dial',
                    textDirection: TextDirection.ltr,
                    style: PointyTypography.numeric(
                      (textTheme.bodyMedium ?? const TextStyle()).copyWith(
                        color: colors.mutedInk,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (selected) ...[
                  const SizedBox(width: 8),
                  Icon(
                    Icons.check_circle_rounded,
                    size: 18,
                    color: colors.primaryStrong,
                  ),
                ] else if (tile) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right_rounded, color: colors.mutedInk),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UnsupportedRow extends StatelessWidget {
  const _UnsupportedRow({required this.country});

  final UnsupportedServiceCountry country;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Opacity(
      opacity: 0.62,
      child: Container(
        key: ValueKey('service_country_unsupported_${country.code}'),
        constraints: const BoxConstraints(minHeight: 46),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            ServiceFlag(code: country.code),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                country.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium?.copyWith(
                  color: colors.mutedInk,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceSunken,
                borderRadius: BorderRadius.circular(PointyRadii.pill),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Text(
                  l10n.posServicesCountryUnavailable,
                  style: textTheme.labelSmall?.copyWith(
                    color: colors.mutedInk,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
