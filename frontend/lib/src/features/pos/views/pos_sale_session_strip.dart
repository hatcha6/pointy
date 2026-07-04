import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/pos_view_model.dart';

class PosSaleSessionSwitcher extends StatelessWidget {
  const PosSaleSessionSwitcher({
    super.key,
    required this.sessions,
    required this.canStartNewSession,
    required this.isLocked,
    required this.onStartNewSession,
    required this.onSelectSession,
    required this.onDiscardSession,
  });

  final List<PosSaleSessionSummary> sessions;
  final bool canStartNewSession;
  final bool isLocked;
  final VoidCallback onStartNewSession;
  final ValueChanged<int> onSelectSession;
  final ValueChanged<int> onDiscardSession;

  @override
  Widget build(BuildContext context) {
    final shouldShow =
        sessions.length > 1 ||
        sessions.any((session) {
          return session.isActive && !session.isEmpty;
        });
    if (!shouldShow) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context)!;
    final activeSession = sessions.firstWhere((session) => session.isActive);
    final openCount = sessions.length;

    return Tooltip(
      message: l10n.saleSessionSwitcherTooltip,
      child: Badge(
        isLabelVisible: openCount > 1,
        label: Text('$openCount'),
        child: _SaleSessionSwitcherButton(
          label: l10n.saleSessionTitle(activeSession.number),
          isLocked: isLocked,
          isBusy: activeSession.itemCount > 0,
          onPressed: isLocked ? null : () => _showSaleSessionsSheet(context),
        ),
      ),
    );
  }

  Future<void> _showSaleSessionsSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        return _SaleSessionsSheet(
          sessions: sessions,
          canStartNewSession: canStartNewSession,
          isLocked: isLocked,
          onStartNewSession: onStartNewSession,
          onSelectSession: onSelectSession,
          onDiscardSession: onDiscardSession,
        );
      },
    );
  }
}

class _SaleSessionSwitcherButton extends StatelessWidget {
  const _SaleSessionSwitcherButton({
    required this.label,
    required this.isLocked,
    required this.isBusy,
    required this.onPressed,
  });

  final String label;
  final bool isLocked;
  final bool isBusy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final foreground = isBusy ? colors.primaryStrong : colors.ink;
    final background = isBusy ? colors.primaryContainer : colors.subtleFill;

    return Opacity(
      opacity: isLocked ? 0.55 : 1,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 112, minHeight: 40),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              border: Border.all(
                color: isBusy ? colors.primaryStrong : colors.line,
              ),
              borderRadius: BorderRadius.circular(PointyRadii.card),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.receipt_long_outlined,
                    size: 18,
                    color: foreground,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.expand_more, size: 16, color: foreground),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SaleSessionsSheet extends StatelessWidget {
  const _SaleSessionsSheet({
    required this.sessions,
    required this.canStartNewSession,
    required this.isLocked,
    required this.onStartNewSession,
    required this.onSelectSession,
    required this.onDiscardSession,
  });

  final List<PosSaleSessionSummary> sessions;
  final bool canStartNewSession;
  final bool isLocked;
  final VoidCallback onStartNewSession;
  final ValueChanged<int> onSelectSession;
  final ValueChanged<int> onDiscardSession;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            spacing.md,
            spacing.md,
            spacing.md,
            spacing.md,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.openSaleSessionsTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: canStartNewSession && !isLocked
                        ? () {
                            onStartNewSession();
                            Navigator.of(context).pop();
                          }
                        : null,
                    icon: const Icon(Icons.note_add_outlined),
                    label: Text(l10n.newSaleSessionButton, maxLines: 1),
                  ),
                ],
              ),
              SizedBox(height: spacing.sm),
              for (final session in sessions) ...[
                _SaleSessionRow(
                  session: session,
                  isLocked: isLocked,
                  onSelect: () {
                    onSelectSession(session.id);
                    Navigator.of(context).pop();
                  },
                  onDiscard: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (_) => PointyDestructiveConfirmationDialog(
                        icon: Icons.remove_shopping_cart_outlined,
                        title: l10n.discardSaleConfirmTitle,
                        message: l10n.discardSaleConfirmMessage,
                        confirmLabel: l10n.discardSaleConfirmButton,
                      ),
                    );
                    if (confirmed != true) {
                      return;
                    }
                    onDiscardSession(session.id);
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                  },
                ),
                if (session != sessions.last) const Divider(height: 1),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SaleSessionRow extends StatelessWidget {
  const _SaleSessionRow({
    required this.session,
    required this.isLocked,
    required this.onSelect,
    required this.onDiscard,
  });

  final PosSaleSessionSummary session;
  final bool isLocked;
  final VoidCallback onSelect;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final title = l10n.saleSessionTitle(session.number);
    final customerName = session.customerName?.trim();
    final subtitleParts = [
      session.isActive
          ? l10n.activeSaleSessionStatusLabel
          : l10n.parkedSaleSessionStatusLabel,
      l10n.lineItemCount(session.itemCount),
      if (customerName != null && customerName.isNotEmpty) customerName,
    ];

    return ListTile(
      contentPadding: EdgeInsetsDirectional.zero,
      dense: true,
      leading: Icon(
        session.isActive
            ? Icons.receipt_long_outlined
            : Icons.pause_circle_outline,
        color: session.isActive ? colors.primaryStrong : colors.mutedInk,
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: session.isActive ? colors.primaryStrong : colors.ink,
          fontWeight: FontWeight.w800,
        ),
      ),
      subtitle: Text(
        subtitleParts.join(' • '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatMoney(session.total),
            maxLines: 1,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colors.ink,
              fontWeight: FontWeight.w800,
            ),
          ),
          IconButton(
            tooltip: l10n.discardSaleSessionTooltip,
            onPressed: session.isActive || isLocked ? null : onDiscard,
            icon: const Icon(Icons.close, size: 18),
            color: colors.danger,
          ),
        ],
      ),
      onTap: session.isActive || isLocked ? null : onSelect,
      selected: session.isActive,
      selectedTileColor: Color.alphaBlend(
        colors.primaryStrong.withOpacity(0.08),
        colors.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
    );
  }
}

class PosSaleSessionStrip extends StatelessWidget {
  const PosSaleSessionStrip({
    super.key,
    required this.sessions,
    required this.canStartNewSession,
    required this.isLocked,
    required this.onStartNewSession,
    required this.onSelectSession,
    required this.onDiscardSession,
  });

  final List<PosSaleSessionSummary> sessions;
  final bool canStartNewSession;
  final bool isLocked;
  final VoidCallback onStartNewSession;
  final ValueChanged<int> onSelectSession;
  final ValueChanged<int> onDiscardSession;

  @override
  Widget build(BuildContext context) {
    return PosSaleSessionSwitcher(
      sessions: sessions,
      canStartNewSession: canStartNewSession,
      isLocked: isLocked,
      onStartNewSession: onStartNewSession,
      onSelectSession: onSelectSession,
      onDiscardSession: onDiscardSession,
    );
  }
}
