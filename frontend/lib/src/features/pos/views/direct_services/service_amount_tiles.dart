import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../shared/barcode/barcode_scan_listener.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../direct_services/arabic_search_text.dart';

/// How many tiles of at least [minWidth] fit [width], and how wide each is.
({int columns, double tileWidth}) serviceTileColumns(
  double width, {
  required double minWidth,
  required double gap,
  int maxColumns = 6,
}) {
  final usable = width.isFinite && width > 0;
  final columns = usable
      ? ((width + gap) / (minWidth + gap)).floor().clamp(1, maxColumns)
      : 2;
  final tileWidth = usable ? (width - gap * (columns - 1)) / columns : minWidth;
  return (columns: columns, tileWidth: tileWidth);
}

/// One amount to pick: what the recipient gets, big, and what the customer
/// pays, small. A network that converts at its own rate marks the amount «≈».
class ServiceAmountTile extends StatelessWidget {
  const ServiceAmountTile({
    super.key,
    required this.amountText,
    this.unitText = '',
    this.price,
    this.selected = false,
    this.approximate = false,
    this.onTap,
    this.focusNode,
  });

  /// The amount as it reads: `5,000`.
  final String amountText;

  /// The currency, in Arabic: «فرنك أفريقي».
  final String unitText;

  /// What the customer pays, in the shop's currency; null before it is known.
  final double? price;
  final bool selected;
  final bool approximate;
  final VoidCallback? onTap;

  /// Lets the keyboard be taken here: Enter in the number goes to the amounts.
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? colors.primaryContainer : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PointyRadii.input),
          side: BorderSide(
            color: selected ? colors.primaryStrong : colors.line,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          focusNode: focusNode,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  approximate ? '\u{2248}\u{2009}$amountText' : amountText,
                  textDirection: TextDirection.ltr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PointyTypography.numeric(
                    (textTheme.titleLarge ?? const TextStyle()).copyWith(
                      color: selected ? colors.primaryDark : colors.ink,
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                    ),
                  ),
                ),
                if (unitText.isNotEmpty)
                  Text(
                    unitText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelSmall?.copyWith(
                      color: colors.mutedInk,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                const SizedBox(height: 6),
                if (price != null)
                  Text(
                    formatMoney(price!),
                    maxLines: 1,
                    style: PointyTypography.numeric(
                      (textTheme.labelLarge ?? const TextStyle()).copyWith(
                        color: colors.primaryStrong,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The «another amount» tile, which opens the field.
class ServiceOtherAmountTile extends StatelessWidget {
  const ServiceOtherAmountTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? colors.primaryContainer : colors.subtleFill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PointyRadii.input),
          side: BorderSide(
            color: selected ? colors.primaryStrong : colors.lineStrong,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.edit_rounded,
                size: 22,
                color: selected ? colors.primaryStrong : colors.mutedInk,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                style: textTheme.labelLarge?.copyWith(
                  color: selected ? colors.primaryDark : colors.ink,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A plan to pick — a television package, a subscription: its Arabic
/// description and what it costs, in a row of its own.
class ServicePlanTile extends StatelessWidget {
  const ServicePlanTile({
    super.key,
    required this.description,
    required this.amountText,
    required this.unitText,
    this.price,
    this.selected = false,
    this.onTap,
  });

  final String description;
  final String amountText;
  final String unitText;
  final double? price;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? colors.primaryContainer : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PointyRadii.input),
          side: BorderSide(
            color: selected ? colors.primaryStrong : colors.line,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(
                          color: selected ? colors.primaryDark : colors.ink,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$amountText $unitText',
                        textDirection: TextDirection.rtl,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                if (price != null)
                  Text(
                    formatMoney(price!),
                    style: PointyTypography.numeric(
                      (textTheme.titleSmall ?? const TextStyle()).copyWith(
                        color: colors.primaryStrong,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                if (selected) ...[
                  const SizedBox(width: 8),
                  Icon(
                    Icons.check_circle_rounded,
                    size: 20,
                    color: colors.primaryStrong,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps an amount field to what an amount is made of: digits (Arabic ones
/// become ASCII), one decimal mark, grouping marks.
class ForeignAmountInputFormatter extends TextInputFormatter {
  const ForeignAmountInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final cleaned = asciiDigits(newValue.text)
        .replaceAll('\u{066B}', '.')
        .replaceAll('\u{066C}', ',')
        .replaceAll(RegExp(r'[^0-9.,]'), '');
    final limited = cleaned.length > 14 ? cleaned.substring(0, 14) : cleaned;
    if (limited == newValue.text) {
      return newValue;
    }
    final removed = newValue.text.length - limited.length;
    final offset = (newValue.selection.baseOffset - removed).clamp(
      0,
      limited.length,
    );
    return TextEditingValue(
      text: limited,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}

/// The field for an amount of the cashier's own, with the limits said in it
/// and the price shown as it is typed.
class ServiceCustomAmountField extends StatefulWidget {
  const ServiceCustomAmountField({
    super.key,
    required this.label,
    required this.hint,
    required this.onChanged,
    this.initialText = '',
    this.errorText,
    this.priceText,
    this.helperText,
    this.autofocus = true,
    this.focusNode,
    this.onSubmitted,
  });

  final String label;
  final String hint;
  final String initialText;
  final ValueChanged<String> onChanged;
  final VoidCallback? onSubmitted;
  final String? errorText;

  /// What the customer pays for the amount typed, once the server said.
  final String? priceText;
  final String? helperText;
  final bool autofocus;

  /// Lets the keyboard be taken here from outside.
  final FocusNode? focusNode;

  @override
  State<ServiceCustomAmountField> createState() =>
      _ServiceCustomAmountFieldState();
}

class _ServiceCustomAmountFieldState extends State<ServiceCustomAmountField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ScanWedgeTarget(
          child: TextField(
            key: const ValueKey('service_custom_amount'),
            controller: _controller,
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.start,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: const [ForeignAmountInputFormatter()],
            onChanged: widget.onChanged,
            // Enter is the caller's to answer: the cursor stays where it is
            // unless the line goes in the cart.
            onEditingComplete: widget.onSubmitted == null ? null : () {},
            onSubmitted: (_) => widget.onSubmitted?.call(),
            decoration: InputDecoration(
              isDense: true,
              labelText: widget.label,
              hintText: widget.hint,
              hintTextDirection: TextDirection.ltr,
              errorText: widget.errorText,
              helperText: widget.helperText,
              helperMaxLines: 2,
              suffixIcon: widget.priceText == null
                  ? null
                  : Padding(
                      padding: const EdgeInsetsDirectional.only(end: 12),
                      child: Center(
                        widthFactor: 1,
                        child: Text(
                          widget.priceText!,
                          style: PointyTypography.numeric(
                            Theme.of(context).textTheme.labelLarge!.copyWith(
                              color: colors.primaryStrong,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}
