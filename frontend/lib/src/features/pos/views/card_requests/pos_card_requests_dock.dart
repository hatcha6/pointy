import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/card_request.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../../settings/views/integration_presentation.dart';
import '../../view_models/pos_card_requests_controller.dart';

/// The floating requests panel over the catalog: a pill that says what is open,
/// a notice when something ends, and the list when asked for. Nothing here is
/// modal: the grid, the cart and the scanner keep working under it, which is
/// the whole point — the cashier keeps selling while a card takes its minutes.
class PosCardRequestsDock extends StatefulWidget {
  const PosCardRequestsDock({
    super.key,
    required this.controller,
    required this.child,
    this.onPrint,
    this.showsWhenIdle = false,
  });

  final PosCardRequestsController controller;

  /// What it floats over.
  final Widget child;

  /// Prints a delivered request's sale again.
  final Future<Object?> Function(CardRequest request)? onPrint;

  /// Whether the pill stays when nothing is happening (on the cards' own menu);
  /// elsewhere a quiet till shows no sign of it.
  final bool showsWhenIdle;

  @override
  State<PosCardRequestsDock> createState() => _PosCardRequestsDockState();
}

class _PosCardRequestsDockState extends State<PosCardRequestsDock> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.controller.start());
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Stack(
      // It stands in for the pane it floats over: the pane's whole size, with
      // nothing to show or not.
      fit: StackFit.expand,
      children: [
        widget.child,
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final open = controller.panelOpen;
            final shows =
                open ||
                controller.openCount > 0 ||
                controller.unseenFailed > 0 ||
                controller.unseenSucceeded > 0 ||
                controller.notices.isNotEmpty ||
                (widget.showsWhenIdle && controller.hasAny);
            if (!shows) {
              return const SizedBox.shrink();
            }
            return Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = (constraints.maxWidth - 24).clamp(240.0, 400.0);
                  final height = (constraints.maxHeight - 84).clamp(
                    160.0,
                    480.0,
                  );
                  return Align(
                    alignment: AlignmentDirectional.bottomStart,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (open)
                            SizedBox(
                              width: width,
                              height: height,
                              child: CardRequestsPanel(
                                controller: controller,
                                onPrint: widget.onPrint,
                              ),
                            )
                          else
                            for (final notice in controller.notices)
                              SizedBox(
                                width: width,
                                child: _Notice(
                                  key: ValueKey(
                                    'card_request_notice_${notice.orderLine}',
                                  ),
                                  request: notice,
                                  onOpen: () => controller.setPanelOpen(true),
                                  onDismiss: () => controller.dismissNotice(
                                    notice.orderLine,
                                  ),
                                ),
                              ),
                          const SizedBox(height: 8),
                          _Pill(controller: controller),
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.controller});

  final PosCardRequestsController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final working = controller.openCount;
    final failed = controller.unseenFailed;
    final done = controller.unseenSucceeded;
    return Material(
      key: const ValueKey('card_requests_pill'),
      elevation: 4,
      color: colors.surface,
      shape: StadiumBorder(
        side: BorderSide(color: failed > 0 ? colors.danger : colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => controller.setPanelOpen(!controller.panelOpen),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (working > 0)
                const SizedBox.square(
                  dimension: 16,
                  child: PointySpinner(strokeWidth: 2),
                )
              else
                Icon(
                  Icons.receipt_long_rounded,
                  size: 18,
                  color: colors.mutedInk,
                ),
              const SizedBox(width: 6),
              Text(
                working > 0
                    ? l10n.cardRequestsPillOpen(working)
                    : l10n.cardRequestsPillIdle,
                style: textTheme.labelLarge?.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (done > 0) ...[
                const SizedBox(width: 8),
                _Count(
                  icon: Icons.check_rounded,
                  count: done,
                  color: colors.success,
                ),
              ],
              if (failed > 0) ...[
                const SizedBox(width: 8),
                _Count(
                  icon: Icons.close_rounded,
                  count: failed,
                  color: colors.danger,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.icon, required this.count, required this.color});

  final IconData icon;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16, color: color),
      Text(
        '$count',
        style: PointyTypography.numeric(
          (Theme.of(context).textTheme.labelLarge ?? const TextStyle())
              .copyWith(color: color, fontWeight: FontWeight.w800),
        ),
      ),
    ],
  );
}

/// What just ended, in a line the cashier can read while serving someone else.
class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.request,
    required this.onOpen,
    required this.onDismiss,
  });

  final CardRequest request;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final ok = request.isSucceeded;
    final tone = ok ? colors.success : colors.danger;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        elevation: 4,
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PointyRadii.input),
          side: BorderSide(color: tone),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 2, 8),
            child: Row(
              children: [
                Icon(
                  ok ? Icons.check_circle_rounded : Icons.error_rounded,
                  size: 20,
                  color: tone,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ok
                            ? l10n.cardRequestNoticeDone(request.label)
                            : l10n.cardRequestNoticeFailed(request.label),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleSmall?.copyWith(
                          color: colors.ink,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (_accountText(request) case final account?)
                        Text(
                          account,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.mutedInk,
                          ),
                        ),
                      if (!ok)
                        Text(
                          _refundText(l10n, request),
                          style: textTheme.bodySmall?.copyWith(
                            color: colors.danger,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: l10n.cardRequestNoticeDismiss,
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String? _accountText(CardRequest request) {
  if (request.account.isEmpty) {
    return null;
  }
  final id = ltrIsolated(request.account);
  return request.accountName.isEmpty ? id : '${request.accountName} $id';
}

String _refundText(AppLocalizations l10n, CardRequest request) {
  final refund = request.refundAmount;
  if (refund == null) {
    return l10n.cardRequestNotRefunded;
  }
  return request.refundToAccount
      ? l10n.cardRequestRefundedToAccount(formatMoney(refund))
      : l10n.cardRequestRefunded(formatMoney(refund));
}

class CardRequestsPanel extends StatelessWidget {
  const CardRequestsPanel({super.key, required this.controller, this.onPrint});

  final PosCardRequestsController controller;
  final Future<Object?> Function(CardRequest request)? onPrint;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final requests = controller.requests;
    return Material(
      key: const ValueKey('card_requests_panel'),
      elevation: 8,
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        side: BorderSide(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 4, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.cardRequestsTitle,
                    style: textTheme.titleSmall?.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.cardRequestsClose,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => controller.setPanelOpen(false),
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.line),
          Expanded(
            child: requests.isEmpty
                ? Center(
                    child: Text(
                      l10n.cardRequestsEmpty,
                      style: textTheme.bodyMedium?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: requests.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: colors.line),
                    itemBuilder: (context, index) => _RequestRow(
                      key: ValueKey(
                        'card_request_${requests[index].orderLine}',
                      ),
                      request: requests[index],
                      onSend: () =>
                          unawaited(controller.sendQueued(requests[index])),
                      onPrint: onPrint,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _RequestRow extends StatelessWidget {
  const _RequestRow({
    super.key,
    required this.request,
    required this.onSend,
    this.onPrint,
  });

  final CardRequest request;
  final VoidCallback onSend;
  final Future<Object?> Function(CardRequest request)? onPrint;

  /// A request still unsent this long after its sale did not leave by itself.
  static const Duration _stuckAfter = Duration(minutes: 1);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final muted = textTheme.bodySmall?.copyWith(color: colors.mutedInk);
    final created = request.createdAt;
    final stuck =
        request.state == CardRequestState.queued &&
        created != null &&
        DateTime.now().difference(created) > _stuckAfter;
    final code = request.code;
    final details = request.receiptNumber.isEmpty
        ? null
        : l10n.cardRequestReceipt(ltrIsolated(request.receiptNumber));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  request.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall?.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _StateChip(request: request),
            ],
          ),
          if (_accountText(request) case final account?)
            Text(
              account,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
          Row(
            children: [
              if (details != null)
                Flexible(
                  child: Text(
                    details,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                ),
              if (details != null && created != null) Text(' · ', style: muted),
              if (created != null)
                request.isOpen
                    ? _Elapsed(since: created, style: muted)
                    : Text(formatClock(created), style: muted),
            ],
          ),
          if (request.late) ...[
            const SizedBox(height: 4),
            Text(
              l10n.cardRequestLateHint,
              style: textTheme.bodySmall?.copyWith(color: colors.warning),
            ),
          ],
          if (stuck)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('card_request_send'),
                onPressed: onSend,
                icon: const Icon(Icons.send_rounded, size: 16),
                label: Text(l10n.cardRequestSend),
              ),
            ),
          if (request.isFailed) ...[
            const SizedBox(height: 4),
            Text(
              integrationErrorText(
                request.errorCode,
                l10n,
                provider: cardRequestsProvider,
              ),
              style: textTheme.bodySmall?.copyWith(color: colors.danger),
            ),
            Text(
              _refundText(l10n, request),
              style: textTheme.bodySmall?.copyWith(
                color: colors.danger,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          if (code.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: PointyFittedToken(
                    code: code,
                    style: PointyTypography.numeric(
                      (textTheme.titleMedium ?? const TextStyle()).copyWith(
                        color: colors.primaryDark,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.cardRequestCopy,
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: () =>
                      unawaited(Clipboard.setData(ClipboardData(text: code))),
                  icon: const Icon(Icons.copy_rounded),
                ),
              ],
            ),
          ],
          if (request.isSucceeded && onPrint != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('card_request_print'),
                onPressed: () => unawaited(onPrint!(request)),
                icon: const Icon(Icons.print_outlined, size: 16),
                label: Text(l10n.cardRequestPrint),
              ),
            ),
        ],
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.request});

  final CardRequest request;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final (Color color, String label) = switch (request.state) {
      CardRequestState.queued => (colors.warning, l10n.cardRequestStateQueued),
      CardRequestState.working =>
        request.late
            ? (colors.warning, l10n.cardRequestStateLate)
            : (colors.primaryStrong, l10n.cardRequestStateWorking),
      CardRequestState.succeeded => (
        colors.success,
        l10n.cardRequestStateSucceeded,
      ),
      CardRequestState.failed => (colors.danger, l10n.cardRequestStateFailed),
      CardRequestState.cancelled => (
        colors.mutedInk,
        l10n.cardRequestStateCancelled,
      ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (request.state == CardRequestState.working && !request.late) ...[
          const SizedBox.square(
            dimension: 12,
            child: PointySpinner(strokeWidth: 1.6),
          ),
          const SizedBox(width: 4),
        ],
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

/// How long a request has been open, ticking while the panel shows it: proof
/// the till has not hung. Only exists while the panel is open.
class _Elapsed extends StatefulWidget {
  const _Elapsed({required this.since, this.style});

  final DateTime since;
  final TextStyle? style;

  @override
  State<_Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<_Elapsed> {
  late final Timer _ticker = Timer.periodic(
    const Duration(seconds: 1),
    (_) => setState(() {}),
  );

  @override
  void initState() {
    super.initState();
    _ticker;
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final seconds = DateTime.now()
        .difference(widget.since)
        .inSeconds
        .clamp(0, 359999);
    final text =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return Text(
      l10n.cardRequestElapsed(ltrIsolated(text)),
      style: widget.style,
    );
  }
}

/// A clock time in 0–9 digits, the way the till shows times.
String formatClock(DateTime at) => ltrIsolated(
  '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}',
);
