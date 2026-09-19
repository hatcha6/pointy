import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/stock_batch.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';

/// The morning a recall notice arrives (§6.8.1).
///
/// Three things have to happen and this screen is all three: stop the sale
/// everywhere in one write, show where the goods came from and where they are
/// now, and tell every buyer on file to stop using them. The audit is answered
/// against **one lot row** whatever branches its goods passed through, which
/// is the whole argument for the identity/balance split.
class BatchRecallScreen extends StatefulWidget {
  const BatchRecallScreen({
    super.key,
    required this.batch,
    required this.repository,
    this.canQuarantine = false,
  });

  final StockBatch batch;
  final TrackedStockRepository repository;
  final bool canQuarantine;

  @override
  State<BatchRecallScreen> createState() => _BatchRecallScreenState();
}

class _BatchRecallScreenState extends State<BatchRecallScreen> {
  BatchRecallReport? _report;
  bool _isLoading = true;
  bool _hasError = false;
  bool _isBusy = false;
  late bool _isLocked = widget.batch.isLocked;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _hasError = false;
    });
    final result = await widget.repository.loadRecallReport(widget.batch.id);
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      if (result is Ok<BatchRecallReport>) {
        _report = result.value;
        _isLocked = result.value.isLocked;
      } else {
        _hasError = true;
      }
    });
  }

  Future<void> _toggleQuarantine() async {
    setState(() => _isBusy = true);
    final result = await widget.repository.setQuarantine(
      widget.batch.id,
      locked: !_isLocked,
    );
    if (!mounted) return;
    setState(() {
      _isBusy = false;
      if (result is Ok<StockBatch>) {
        _isLocked = result.value.isLocked;
      }
    });
    await _load();
  }

  Future<void> _notify() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isBusy = true);
    final result = await widget.repository.notifyAffectedCustomers(
      widget.batch.id,
    );
    if (!mounted) return;
    setState(() => _isBusy = false);
    if (result is Ok<RecallNotifyResult>) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.recallNotifyQueued(result.value.queued))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final report = _report;

    return PointyScaffold(
      appBar: PointyAppBar(title: Text(l10n.recallTitle), isLoading: _isBusy),
      body: _isLoading
          ? const Center(child: PointySpinner())
          : _hasError || report == null
          ? PointyErrorState(
              title: l10n.recallTitle,
              action: OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.retryButton),
              ),
            )
          : ListView(
              padding: spacing.pagePadding,
              children: [
                AdaptiveMaxWidth(
                  width: AppContentWidth.detail,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      PointyDetailHero(
                        icon: Icons.inventory_2_outlined,
                        title: report.batchCode,
                        description: report.productName,
                      ),
                      SizedBox(height: spacing.lg),
                      if (widget.canQuarantine)
                        // One write, on the lot identity, which propagates to
                        // every balance in the same transaction. There is no
                        // window in which one branch is quarantined and
                        // another is still selling, because there is no second
                        // row to forget.
                        FilledButton.icon(
                          onPressed: _isBusy ? null : _toggleQuarantine,
                          icon: Icon(_isLocked ? Icons.lock_open : Icons.block),
                          label: Text(
                            _isLocked
                                ? l10n.recallRelease
                                : l10n.recallQuarantine,
                          ),
                        ),
                      SizedBox(height: spacing.lg),
                      _Section(
                        title: l10n.recallInward,
                        children: [
                          for (final row in report.inward)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(
                                Icons.local_shipping_outlined,
                              ),
                              title: Text(
                                row.supplierName.isEmpty
                                    ? row.batchCode
                                    : row.supplierName,
                              ),
                              subtitle: Text(
                                '${row.quantity} · ${_date(row.receivedAt)}',
                              ),
                            ),
                        ],
                      ),
                      _Section(
                        title: l10n.recallRemaining,
                        children: [
                          for (final row in report.remaining)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                row.isSellable
                                    ? Icons.store_outlined
                                    : Icons.block,
                              ),
                              title: Text(row.warehouseName),
                              trailing: Text('${row.remaining}'),
                            ),
                        ],
                      ),
                      if (report.subLots.isNotEmpty)
                        _Section(
                          title: l10n.recallSubLots,
                          children: [
                            for (final lot in report.subLots)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.call_split_outlined),
                                title: Text(lot.code),
                              ),
                          ],
                        ),
                      _Section(
                        title: l10n.recallOutward,
                        children: [
                          for (final row in report.outward)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.receipt_long_outlined),
                              title: Text(
                                row.customerName.isEmpty
                                    ? row.invoiceNumber
                                    : row.customerName,
                              ),
                              subtitle: Text(
                                [
                                  row.invoiceNumber,
                                  // Under `serial_batch` the recall names the
                                  // exact pack, which is what lets a pharmacist
                                  // tell a customer whether *their* box is the
                                  // recalled one.
                                  row.unitCode,
                                  _date(row.soldAt),
                                ].where((part) => part.isNotEmpty).join(' · '),
                              ),
                            ),
                        ],
                      ),
                      SizedBox(height: spacing.lg),
                      if (report.customersUnreachable > 0)
                        PointyInlineMessage.warning(
                          message: l10n.recallUnreachable(
                            report.customersUnreachable,
                          ),
                          compact: true,
                        ),
                      if (report.walkInSales > 0) ...[
                        SizedBox(height: spacing.sm),
                        PointyInlineMessage.warning(
                          message: l10n.recallWalkIns(report.walkInSales),
                          compact: true,
                        ),
                      ],
                      SizedBox(height: spacing.lg),
                      if (widget.canQuarantine)
                        FilledButton.icon(
                          onPressed: _isBusy || report.customersReachable == 0
                              ? null
                              : _notify,
                          icon: const Icon(Icons.sms_outlined),
                          label: Text(l10n.recallNotify),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  static String _date(DateTime? value) {
    if (value == null) {
      return '';
    }
    return '${value.year}-${value.month.toString().padLeft(2, '0')}'
        '-${value.day.toString().padLeft(2, '0')}';
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }
    final spacing = AdaptiveSpacing.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.only(bottom: spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointySectionHeader(title: title),
          ...children,
        ],
      ),
    );
  }
}
