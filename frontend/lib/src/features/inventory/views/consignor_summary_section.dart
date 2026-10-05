import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/consignor_statement.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import 'consignor_statement_launcher.dart';

/// The customer page's view of their consignments: what is owed them, what is
/// held, and the way into the whole statement.
///
/// Shows nothing at all for a customer who never consigned anything — which
/// is most customers — so it reads the headline once and decides. It carries
/// its own bottom spacing for the same reason: an absent section leaves no
/// gap.
class ConsignorSummarySection extends StatefulWidget {
  const ConsignorSummarySection({
    super.key,
    required this.launcher,
    required this.consignorId,
    this.consignorName = '',
  });

  final ConsignorStatementLauncher launcher;
  final int consignorId;
  final String consignorName;

  @override
  State<ConsignorSummarySection> createState() =>
      _ConsignorSummarySectionState();
}

class _ConsignorSummarySectionState extends State<ConsignorSummarySection> {
  ConsignorStatementFigures? _figures;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ConsignorSummarySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.consignorId != widget.consignorId) {
      _figures = null;
      _load();
    }
  }

  Future<void> _load() async {
    final consignorId = widget.consignorId;
    final result = await widget.launcher.loadSummary(consignorId);
    if (!mounted || consignorId != widget.consignorId) {
      return;
    }
    if (result case Ok<ConsignorStatementPage>(:final value)) {
      setState(() => _figures = value.statement.figures);
    }
  }

  Future<void> _open() async {
    await widget.launcher.open(
      context,
      consignorId: widget.consignorId,
      consignorName: widget.consignorName,
    );
    // A payout may have happened in there; the headline is the server's.
    if (mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final figures = _figures;
    if (figures == null || !figures.hasHistory) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    return Padding(
      padding: EdgeInsetsDirectional.only(bottom: spacing.md),
      child: PointyDetailSection(
        title: l10n.consignorSummaryTitle,
        icon: Icons.handshake_outlined,
        trailing: TextButton.icon(
          onPressed: _open,
          icon: const Icon(Icons.receipt_long_outlined, size: 18),
          label: Text(l10n.consignorStatementOpen),
        ),
        child: PointySummaryList(
          rows: [
            PointySummaryRow(
              label: l10n.consignorSummaryHeld,
              value: '${figures.heldCount}',
            ),
            if (figures.heldDeclaredValue > 0)
              PointySummaryRow(
                label: l10n.consignorLineDeclared,
                value: formatMoney(figures.heldDeclaredValue),
              ),
            PointySummaryRow(
              label: l10n.consignorSummaryAwaiting,
              value: '${figures.awaitingCount}',
            ),
            PointySummaryRow(
              label: l10n.consignorSummaryOwed,
              value: formatMoney(figures.payable),
              emphasized: true,
              dividerAbove: true,
              valueColor: figures.payable > 0 ? colors.primaryStrong : null,
            ),
          ],
        ),
      ),
    );
  }
}
