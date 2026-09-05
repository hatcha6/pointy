import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/companion.dart';
import '../../../data/repositories/companion_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../companion_bridge.dart';
import '../companion_scope.dart';
import 'companion_pairing_sheet.dart';

/// Asks the paired phone for one photo and waits for it to arrive.
///
/// Returns the id of the attachment the phone produced, or null if the operator
/// backed out. The photo has already filed itself against [ownerType]/[ownerId]
/// by the time this returns — the till named the destination when it asked, so
/// nothing has to be moved afterwards.
Future<int?> showCompanionCaptureSheet(
  BuildContext context, {
  required String prompt,
  String ownerType = '',
  int? ownerId,
  String role = '',
  bool isPrimary = false,
}) async {
  final scope = CompanionScope.maybeOf(context);
  final bridge = scope?.bridge;
  final repository = scope?.repository;
  final l10n = AppLocalizations.of(context)!;
  if (bridge == null || repository == null) return null;

  // Nothing to ask if no phone is listening — send the operator to the pairing
  // sheet instead of opening a dialog that could only ever time out.
  if (!bridge.status.value.hasDevice) {
    await showCompanionPairingSheet(
      context,
      repository: repository,
      bridge: bridge,
    );
    if (!context.mounted || !bridge.status.value.hasDevice) return null;
  }

  if (!context.mounted) return null;
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => _CompanionCaptureSheet(
      repository: repository,
      bridge: bridge,
      prompt: prompt.isEmpty ? l10n.companionCaptureRequested : prompt,
      ownerType: ownerType,
      ownerId: ownerId,
      role: role,
      isPrimary: isPrimary,
    ),
  );
}

class _CompanionCaptureSheet extends StatefulWidget {
  const _CompanionCaptureSheet({
    required this.repository,
    required this.bridge,
    required this.prompt,
    required this.ownerType,
    required this.ownerId,
    required this.role,
    required this.isPrimary,
  });

  final CompanionRepository repository;
  final CompanionBridge bridge;
  final String prompt;
  final String ownerType;
  final int? ownerId;
  final String role;
  final bool isPrimary;

  @override
  State<_CompanionCaptureSheet> createState() => _CompanionCaptureSheetState();
}

class _CompanionCaptureSheetState extends State<_CompanionCaptureSheet> {
  StreamSubscription<CompanionEvent>? _subscription;
  CompanionCaptureRequest? _request;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // Subscribe before asking: the phone can answer faster than the request
    // round-trip returns, and a photo that arrived first must not be missed.
    _subscription = widget.bridge.events.listen(_onEvent);
    unawaited(_ask());
  }

  @override
  void dispose() {
    _subscription?.cancel();
    final request = _request;
    if (request != null) {
      // Leaving the sheet withdraws the ask, so the phone stops showing a
      // prompt for a photo nobody is waiting for any more.
      unawaited(widget.repository.cancelCaptureRequest(request.id));
    }
    super.dispose();
  }

  Future<void> _ask() async {
    final result = await widget.repository.requestCapture(
      tillKey: widget.bridge.tillKey,
      prompt: widget.prompt,
      ownerType: widget.ownerType,
      ownerId: widget.ownerId,
      role: widget.role,
      isPrimary: widget.isPrimary,
    );
    if (!mounted) return;
    setState(() {
      switch (result) {
        case Ok(value: final request):
          _request = request;
        case Error():
          _failed = true;
      }
    });
  }

  void _onEvent(CompanionEvent event) {
    if (!mounted || event.kind != CompanionEventKind.capture) return;
    final request = _request;
    // Match on the request when we know it; otherwise take the next photo that
    // arrives, which is the one the operator just took for this prompt.
    if (request != null &&
        event.captureRequestId != null &&
        event.captureRequestId != request.id) {
      return;
    }
    _request = null; // Fulfilled: nothing left to cancel on the way out.
    Navigator.of(context).pop(event.attachmentId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: EdgeInsets.all(spacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_failed)
            PointyInlineMessage.error(
              compact: true,
              message: l10n.companionCaptureFailed,
            )
          else ...[
            const PointySpinner(),
            SizedBox(height: spacing.md),
            Text(
              widget.prompt,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: spacing.xs),
            Text(
              l10n.companionCaptureWaiting,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
          SizedBox(height: spacing.md),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.companionCaptureCancel),
          ),
        ],
      ),
    );
  }
}
