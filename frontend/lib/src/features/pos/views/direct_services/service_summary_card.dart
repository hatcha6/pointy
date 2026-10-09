import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import 'service_text_scale.dart';
import 'service_timeline.dart';

/// One line of the summary the cashier reads back to the customer.
class ServiceSummaryRow {
  const ServiceSummaryRow({
    required this.label,
    required this.value,
    this.ltr = false,
    this.leading,
    this.emphasis = false,
  });

  final String label;

  /// Null before it is known: drawn as a dash.
  final String? value;

  /// A number or a code: held left to right inside the Arabic line.
  final bool ltr;
  final Widget? leading;

  /// The line the eye should land on.
  final bool emphasis;
}

/// What the cashier is about to put in the cart, in the words they will say to
/// the customer: where, who, how much arrives, how much is paid — and, plainly,
/// that it cannot be taken back. Under the button, the one thing still missing.
///
/// As a card beside the steps on a wide pane; as a bar pinned under them on a
/// narrow one ([compact]).
class ServiceSummaryCard extends StatelessWidget {
  const ServiceSummaryCard({
    super.key,
    required this.title,
    required this.rows,
    required this.priceLabel,
    required this.truth,
    required this.addLabel,
    this.price,
    this.isPricing = false,
    this.balanceText,
    this.exceedsBalance = false,
    this.onTransferBalance,
    this.readBack,
    this.blockerText,
    this.blockerIsWaiting = false,
    this.onRetry,
    this.retryLabel,
    this.onAdd,
    this.compact = false,
    this.extraNotice,
    this.showTimeline = false,
  });

  final String title;
  final List<ServiceSummaryRow> rows;

  /// «يدفع الزبون».
  final String priceLabel;

  /// The server's price; null until it has priced exactly this.
  final double? price;
  final bool isPricing;

  /// «رصيد الكروت: 345.50 د.ل», near the price: the money the service is
  /// paid from, as last read.
  final String? balanceText;

  /// The voucher balance cannot pay for this: a strong warning instead of the
  /// quiet balance line. Warned, never refused — the balance is as old as the
  /// last read, and money may have been moved in since.
  final bool exceedsBalance;

  /// Opens the transfer from the wallet into the voucher balance; null when
  /// this user cannot, and the warning then says where it is done instead.
  final VoidCallback? onTransferBalance;

  /// What the customer is read back — the number, the country, the network —
  /// at the top of a [compact] bar, or above the rows of a card.
  final Widget? readBack;

  /// The one line that says it cannot be taken back.
  final String truth;

  /// A reassurance that belongs to this service: «ستظهر على الإيصال شيفرة…».
  final String? extraNotice;
  final String addLabel;

  /// Why the button is off, or null when it is on.
  final String? blockerText;
  final bool blockerIsWaiting;
  final VoidCallback? onRetry;

  /// What the retry button says; «إعادة المحاولة» unless the fix is another
  /// one — «تحديث القائمة» for a list that is out of date.
  final String? retryLabel;

  /// Null disables the button.
  final VoidCallback? onAdd;
  final bool compact;

  /// A single small line under the button saying what happens next.
  final bool showTimeline;

  @override
  Widget build(BuildContext context) {
    return compact ? _bar(context) : _card(context);
  }

  Widget _blocker(BuildContext context) {
    final colors = context.pointyColors;
    final text = blockerText;
    if (text == null) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (blockerIsWaiting)
            const Padding(
              padding: EdgeInsets.only(top: 3),
              child: SizedBox.square(
                dimension: 14,
                child: PointySpinner(strokeWidth: 2),
              ),
            )
          else
            Icon(Icons.info_outline_rounded, size: 17, color: colors.warning),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              key: const ValueKey('service_blocker'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: blockerIsWaiting ? colors.mutedInk : colors.warning,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
          ),
          if (onRetry != null)
            TextButton(
              key: const ValueKey('service_retry'),
              onPressed: onRetry,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(retryLabel ?? l10n.retryButton),
            ),
        ],
      ),
    );
  }

  bool get _hasBalanceNote => exceedsBalance || balanceText != null;

  /// The balance the service is paid from: a quiet line, or — when it cannot
  /// cover this — a warning that says what to do, with the button when this
  /// user can do it from here.
  Widget _balanceNote(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context)!;
    final balance = balanceText;
    if (!exceedsBalance) {
      return balance == null
          ? const SizedBox.shrink()
          : Text(
              balance,
              key: const ValueKey('service_balance'),
              style: textTheme.labelMedium?.copyWith(color: colors.mutedInk),
            );
    }
    return DecoratedBox(
      key: const ValueKey('service_balance_warning'),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(PointyRadii.input),
        border: Border.all(color: colors.warning),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.warning_amber_rounded, size: 22, color: colors.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.posServicesBalanceShort,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w800,
                      height: 1.35,
                    ),
                  ),
                  if (balance != null)
                    Text(
                      balance,
                      key: const ValueKey('service_balance'),
                      style: textTheme.labelSmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                  if (onTransferBalance == null)
                    Text(
                      l10n.posServicesBalanceWhere,
                      style: textTheme.labelSmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                ],
              ),
            ),
            if (onTransferBalance != null) ...[
              const SizedBox(width: 8),
              FilledButton.tonal(
                key: const ValueKey('service_balance_transfer'),
                onPressed: onTransferBalance,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(l10n.walletVouchersAllocateButton),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _truth(BuildContext context, {int? maxLines}) {
    final colors = context.pointyColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            Icons.lock_clock_rounded,
            size: 15,
            color: colors.mutedInk,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            truth,
            maxLines: maxLines,
            overflow: maxLines == null ? null : TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.mutedInk,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }

  Widget _addButton(BuildContext context) {
    return SizedBox(
      height: 48,
      child: FilledButton.icon(
        key: const ValueKey('service_add_to_cart'),
        onPressed: onAdd,
        icon: const Icon(Icons.add_shopping_cart_rounded),
        label: Text(addLabel),
      ),
    );
  }

  Widget _priceText(BuildContext context, {required double size}) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final style = PointyTypography.numeric(
      (textTheme.titleLarge ?? const TextStyle()).copyWith(
        fontSize: size,
        color: price == null ? colors.mutedInk : colors.primaryStrong,
        fontWeight: FontWeight.w800,
        height: 1.1,
      ),
    );
    if (price == null && isPricing) {
      return const SizedBox.square(
        dimension: 18,
        child: PointySpinner(strokeWidth: 2),
      );
    }
    return Text(
      price == null ? '\u{2014}' : formatMoney(price!),
      key: const ValueKey('service_price'),
      style: style,
    );
  }

  Widget _card(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(PointyRadii.card + 4),
        border: Border.all(color: colors.line),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: textTheme.titleSmall?.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: colors.line),
            const SizedBox(height: 8),
            if (readBack case final readBack?) ...[
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceSunken,
                  borderRadius: BorderRadius.circular(PointyRadii.input),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: readBack,
                ),
              ),
              const SizedBox(height: 8),
            ],
            for (final row in rows) _SummaryLine(row: row),
            const SizedBox(height: 6),
            Divider(height: 1, color: colors.line),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    priceLabel,
                    style: textTheme.titleSmall?.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                _priceText(context, size: 24),
              ],
            ),
            if (_hasBalanceNote) ...[
              const SizedBox(height: 6),
              _balanceNote(context),
            ],
            const SizedBox(height: 10),
            _truth(context),
            if (extraNotice case final notice?) ...[
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      Icons.confirmation_number_outlined,
                      size: 15,
                      color: colors.primaryStrong,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      notice,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.primaryDark,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            _blocker(context),
            _addButton(context),
          ],
        ),
      ),
    );
  }

  Widget _bar(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context)!;
    // The two things the customer is told; the rest is in the steps above.
    final highlights = [
      for (final row in rows)
        if (row.emphasis) row,
    ];
    final text = blockerText;

    Widget pair(String label, Widget value) => FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            label,
            style: textTheme.labelMedium?.copyWith(color: colors.mutedInk),
          ),
          const SizedBox(width: 6),
          value,
        ],
      ),
    );

    final blockerRow = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (blockerIsWaiting)
          const SizedBox.square(
            dimension: 16,
            child: PointySpinner(strokeWidth: 2),
          )
        else
          Icon(Icons.info_outline_rounded, size: 18, color: colors.warning),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text ?? '',
            key: const ValueKey('service_blocker'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(
              color: blockerIsWaiting ? colors.mutedInk : colors.warning,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
        ),
        if (onRetry != null)
          TextButton(
            key: const ValueKey('service_retry'),
            onPressed: onRetry,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(retryLabel ?? l10n.retryButton),
          ),
      ],
    );

    // What arrives and what is paid on one wrapping line, the balance quietly
    // beside them; the warning, when the balance cannot cover it, has a row of
    // its own under the button.
    final money = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 14,
      runSpacing: 2,
      children: [
        for (final row in highlights)
          pair(
            row.label,
            Text(
              row.value ?? '\u{2014}',
              textDirection: row.ltr ? TextDirection.ltr : null,
              maxLines: 1,
              style: PointyTypography.numeric(
                (textTheme.titleSmall ?? const TextStyle()).copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        pair(priceLabel, _priceText(context, size: 20)),
        if (balanceText != null && !exceedsBalance)
          Text(
            balanceText!,
            key: const ValueKey('service_balance'),
            style: textTheme.labelMedium?.copyWith(color: colors.mutedInk),
          ),
      ],
    );

    final left = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (readBack case final readBack?) ...[
          readBack,
          const SizedBox(height: 4),
        ],
        text != null ? blockerRow : money,
      ],
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.line)),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final button = FilledButton.icon(
                  key: const ValueKey('service_add_to_cart'),
                  onPressed: onAdd,
                  icon: const Icon(Icons.add_shopping_cart_rounded, size: 20),
                  label: Text(
                    addLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
                // Enlarged text on a narrow screen: the button takes a line
                // of its own rather than squeezing what is being bought.
                final stacked =
                    MediaQuery.textScalerOf(context).scale(1) > 1.15 &&
                    constraints.maxWidth < 460;
                if (stacked) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      left,
                      const SizedBox(height: 8),
                      SizedBox(height: 48, child: button),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: left),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: textBoundExtent(context, 168),
                      height: 48,
                      child: button,
                    ),
                  ],
                );
              },
            ),
            if (exceedsBalance) ...[
              const SizedBox(height: 6),
              _balanceNote(context),
            ],
            if (showTimeline) ...[
              const SizedBox(height: 5),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: const ServiceTimeline(compact: true, singleLine: true),
              ),
            ],
            const SizedBox(height: 4),
            _truth(context, maxLines: 2),
          ],
        ),
      ),
    );
  }
}

class _SummaryLine extends StatelessWidget {
  const _SummaryLine({required this.row});

  final ServiceSummaryRow row;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final value = row.value;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              row.label,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
          ),
          if (row.leading case final leading?) ...[
            leading,
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              value ?? '\u{2014}',
              textDirection: row.ltr && value != null
                  ? TextDirection.ltr
                  : null,
              textAlign: row.ltr && value != null ? TextAlign.end : null,
              style: PointyTypography.numeric(
                (textTheme.bodyMedium ?? const TextStyle()).copyWith(
                  color: value == null ? colors.mutedInk : colors.ink,
                  fontWeight: row.emphasis ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
