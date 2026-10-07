import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/expense_ledger_entry.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/payments/bank_account_row.dart';

/// One line of money out: what it was, who recorded it and when, and — as
/// links — the drawer shift and the document it came from.
///
/// Tapping the line opens where it came from: a till pay-out opens its drawer
/// session, a purchase its order, a payroll payment its run. An expense
/// recorded on this screen is its own document, so tapping it still edits it
/// (for whoever may); its shift, when it was paid out of a drawer, is the link
/// beside it. A link whose screen this user may not open is left as plain
/// text rather than a tap onto a denied screen.
class ExpenseLedgerTile extends StatelessWidget {
  const ExpenseLedgerTile({
    super.key,
    required this.entry,
    required this.canManage,
    required this.isBusy,
    required this.onEdit,
    required this.onDelete,
    this.onOpenRegisterSession,
    this.onOpenPurchaseOrder,
    this.onOpenPayrollRun,
    this.onOpenRecorder,
  });

  final ExpenseLedgerEntry entry;
  final bool canManage;
  final bool isBusy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<int>? onOpenRegisterSession;
  final ValueChanged<int>? onOpenPurchaseOrder;
  final ValueChanged<int>? onOpenPayrollRun;

  /// The recorder's profile, by user id and the name the row already carries.
  final void Function(int userId, String name)? onOpenRecorder;

  /// Below this width the amount moves up beside the title and the row's
  /// actions under it: beside a phone-width line, the trailing amount, badge
  /// and buttons squeezed the recorder and the links down to an ellipsis.
  static const _compactWidth = 560.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) =>
          _buildTile(context, compact: constraints.maxWidth < _compactWidth),
    );
  }

  Widget _buildTile(BuildContext context, {required bool compact}) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final color = expenseSourceColor(colors, entry.source);
    final subtitleParts = <String>[
      formatDate(entry.date),
      if (entry.category != null && entry.category!.isNotEmpty) entry.category!,
      if (entry.source == ExpenseLedgerSource.expense &&
          entry.paymentMethod.isNotEmpty)
        expensePaymentMethodLabel(l10n, entry.paymentMethod),
    ];
    final editable = canManage && entry.isEditable;
    final links = _links(l10n);
    final recorder = _recorderLine(l10n);
    final title = Text(
      entry.description.isEmpty
          ? expenseSourceLabel(l10n, entry.source)
          : entry.description,
    );
    final amount = Text(
      formatMoney(entry.amount),
      style: theme.textTheme.titleMedium,
    );
    final actions = editable
        ? [
            IconButton(
              tooltip: l10n.editButton,
              onPressed: isBusy ? null : onEdit,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: l10n.deleteButton,
              onPressed: isBusy ? null : onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ]
        : const <Widget>[];

    return ListTile(
      key: ValueKey(
        'expense_ledger_row_${entry.source.apiValue}_'
        '${entry.relatedId ?? entry.description}',
      ),
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: color.withValues(alpha: 0.16),
        child: Icon(expenseSourceIcon(entry.source), size: 18, color: color),
      ),
      title: compact
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: title),
                const SizedBox(width: 8),
                amount,
              ],
            )
          : title,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(subtitleParts.join(' · ')),
          if (recorder != null) ...[const SizedBox(height: 2), recorder],
          if (entry.bankAccount != null) ...[
            const SizedBox(height: 2),
            // Which bank it left, with that bank's own mark. Only ever drawn
            // when the row names one, so a shop with a single account sees
            // the list it always saw.
            BankAccountRow(
              account: entry.bankAccount!,
              compact: true,
              markSize: 16,
            ),
          ],
          if (links.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(spacing: 6, runSpacing: 4, children: links),
          ],
          // The source's own icon and colour lead the line; on a phone that
          // is all the room the badge would have repeated.
          if (compact && actions.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Row(mainAxisSize: MainAxisSize.min, children: actions),
            ),
        ],
      ),
      trailing: compact
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                amount,
                if (editable) ...[
                  const SizedBox(width: 4),
                  ...actions,
                ] else
                  _SourceBadge(
                    label: expenseSourceLabel(l10n, entry.source),
                    color: color,
                  ),
              ],
            ),
      onTap: isBusy ? null : _primaryAction(editable),
    );
  }

  VoidCallback? get _openSession {
    final id = entry.registerSessionId;
    final open = onOpenRegisterSession;
    return id == null || open == null ? null : () => open(id);
  }

  VoidCallback? get _openPurchaseOrder {
    final id = entry.purchaseOrderId;
    final open = onOpenPurchaseOrder;
    return id == null || open == null ? null : () => open(id);
  }

  VoidCallback? get _openPayrollRun {
    final id = entry.payrollRunId;
    final open = onOpenPayrollRun;
    return id == null || open == null ? null : () => open(id);
  }

  /// Where a tap on the line goes: the screen the money was put out on.
  VoidCallback? _primaryAction(bool editable) {
    return switch (entry.source) {
      ExpenseLedgerSource.registerPayout => _openSession,
      ExpenseLedgerSource.purchase => _openPurchaseOrder,
      ExpenseLedgerSource.payroll => _openPayrollRun,
      ExpenseLedgerSource.expense => editable ? onEdit : _openSession,
      ExpenseLedgerSource.commission || ExpenseLedgerSource.unknown => null,
    };
  }

  List<Widget> _links(AppLocalizations l10n) {
    final number = entry.documentNumber.trim();
    return [
      if (entry.purchaseOrderId != null)
        _LedgerLink(
          key: const ValueKey('expense_link_purchase_order'),
          icon: Icons.local_shipping_outlined,
          label: l10n.purchaseOrderNumberValue(
            number.isEmpty ? '#${entry.purchaseOrderId}' : number,
          ),
          onTap: _openPurchaseOrder,
        ),
      if (entry.payrollRunId != null)
        _LedgerLink(
          key: const ValueKey('expense_link_payroll_run'),
          icon: Icons.badge_outlined,
          label: l10n.expenseLinkPayrollRun(
            number.isEmpty ? '#${entry.payrollRunId}' : number,
          ),
          onTap: _openPayrollRun,
        ),
      if (entry.registerSessionId != null)
        _LedgerLink(
          key: const ValueKey('expense_link_register_session'),
          icon: Icons.point_of_sale_outlined,
          label: l10n.expenseLinkRegisterSession(
            entry.registerSessionNumber.isEmpty
                ? '#${entry.registerSessionId}'
                : entry.registerSessionNumber,
          ),
          onTap: _openSession,
        ),
    ];
  }

  /// "بواسطة سالم — 14:32": the time alone when it was entered on the day the
  /// line is dated, the date as well when it was entered on another (an
  /// expense dated back to the day it was spent).
  Widget? _recorderLine(AppLocalizations l10n) {
    final name = entry.recordedByName;
    final at = entry.recordedAt;
    if (name.isEmpty && at == null) {
      return null;
    }
    final when = at == null
        ? null
        : DateUtils.isSameDay(at, entry.date)
        ? formatTime(at)
        : formatDateTime(at);
    final String text;
    if (name.isNotEmpty && when != null) {
      text = l10n.expenseRecordedByLine(name, when);
    } else if (name.isNotEmpty) {
      text = l10n.expenseRecordedByName(name);
    } else {
      text = l10n.expenseRecordedAtLine(when!);
    }
    final recorderId = entry.recordedById;
    final open = onOpenRecorder;
    return _RecorderLine(
      text: text,
      onTap: name.isEmpty || recorderId == null || open == null
          ? null
          : () => open(recorderId, name),
    );
  }
}

/// Who recorded the line, and when — a link to their profile when this user
/// may open it.
class _RecorderLine extends StatelessWidget {
  const _RecorderLine({required this.text, this.onTap});

  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: onTap == null ? colors.mutedInk : colors.primaryStrong,
      decoration: onTap == null ? null : TextDecoration.underline,
      decorationColor: colors.primaryStrong,
    );
    final line = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.person_outline,
          size: 14,
          color: onTap == null ? colors.mutedInk : colors.primaryStrong,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            key: const ValueKey('expense_recorded_by'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
    if (onTap == null) {
      return line;
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: line,
    );
  }
}

/// A record the line came from, in the app's link style (the invoice's
/// cashier and drawer-session links): underlined, with an open-in-new mark.
class _LedgerLink extends StatelessWidget {
  const _LedgerLink({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final enabled = onTap != null;
    final tint = enabled ? colors.primaryStrong : colors.mutedInk;
    return Material(
      color: Color.alphaBlend(tint.withValues(alpha: 0.08), colors.surface),
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: tint),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: tint,
                    fontWeight: FontWeight.w600,
                    decoration: enabled ? TextDecoration.underline : null,
                    decorationColor: tint,
                  ),
                ),
              ),
              if (enabled) ...[
                const SizedBox(width: 4),
                Icon(Icons.open_in_new, size: 12, color: tint),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: color),
        ),
      ),
    );
  }
}

// --- source presentation helpers --------------------------------------------

String expenseSourceLabel(AppLocalizations l10n, ExpenseLedgerSource source) {
  return switch (source) {
    ExpenseLedgerSource.expense => l10n.expenseSourceAdHoc,
    ExpenseLedgerSource.registerPayout => l10n.expenseSourceRegisterPayout,
    ExpenseLedgerSource.purchase => l10n.expenseSourcePurchase,
    ExpenseLedgerSource.payroll => l10n.expenseSourcePayroll,
    ExpenseLedgerSource.commission => l10n.expenseSourceCommission,
    ExpenseLedgerSource.unknown => l10n.expenseSourceOther,
  };
}

IconData expenseSourceIcon(ExpenseLedgerSource source) {
  return switch (source) {
    ExpenseLedgerSource.expense => Icons.receipt_outlined,
    ExpenseLedgerSource.registerPayout => Icons.point_of_sale_outlined,
    ExpenseLedgerSource.purchase => Icons.local_shipping_outlined,
    ExpenseLedgerSource.payroll => Icons.badge_outlined,
    ExpenseLedgerSource.commission => Icons.credit_card_outlined,
    ExpenseLedgerSource.unknown => Icons.payments_outlined,
  };
}

Color expenseSourceColor(
  PointySemanticColors colors,
  ExpenseLedgerSource source,
) {
  // Distinct, palette-driven hues per ledger source so the badges read
  // correctly in both light and dark mode (raw Material colors did not adapt).
  return switch (source) {
    ExpenseLedgerSource.expense => colors.primary,
    ExpenseLedgerSource.registerPayout => colors.warning,
    ExpenseLedgerSource.purchase => colors.accentAmber,
    ExpenseLedgerSource.payroll => colors.success,
    ExpenseLedgerSource.commission => colors.danger,
    ExpenseLedgerSource.unknown => colors.mutedInk,
  };
}

String expensePaymentMethodLabel(AppLocalizations l10n, String method) {
  return switch (method) {
    'cash' => l10n.expensePaymentCash,
    'card' => l10n.expensePaymentCard,
    'transfer' => l10n.expensePaymentTransfer,
    _ => method,
  };
}
