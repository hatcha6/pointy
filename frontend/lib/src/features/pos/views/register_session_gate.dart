import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/pos_view_model.dart';

class RegisterSessionGate extends StatefulWidget {
  const RegisterSessionGate({
    super.key,
    required this.viewModel,
    required this.capabilities,
  });

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  State<RegisterSessionGate> createState() => _RegisterSessionGateState();
}

class _RegisterSessionGateState extends State<RegisterSessionGate> {
  final TextEditingController _openingCashController = TextEditingController();
  bool _showOpeningCashRequiredError = false;

  @override
  void dispose() {
    _openingCashController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: spacing.pagePadding,
        child: AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: PointyDetailSection(
            title: l10n.registerSessionGateTitle,
            icon: Icons.point_of_sale_outlined,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: switch (widget.viewModel.registerSessionGateStatus) {
                RegisterSessionGateStatus.loading => _LoadingGate(l10n: l10n),
                RegisterSessionGateStatus.openSessionAvailable =>
                  RegisterSessionResumeGuard(
                    capabilities: widget.capabilities,
                    child: _ResumeSessionGate(viewModel: widget.viewModel),
                  ),
                RegisterSessionGateStatus.noOpenSession =>
                  RegisterSessionStartGuard(
                    capabilities: widget.capabilities,
                    child: _StartSessionGate(
                      viewModel: widget.viewModel,
                      openingCashController: _openingCashController,
                      showOpeningCashRequiredError:
                          _showOpeningCashRequiredError,
                      onOpeningCashChanged: () {
                        if (!_showOpeningCashRequiredError) {
                          return;
                        }
                        setState(() => _showOpeningCashRequiredError = false);
                      },
                      onOpeningCashRequiredError: () {
                        setState(() => _showOpeningCashRequiredError = true);
                      },
                    ),
                  ),
                RegisterSessionGateStatus.active => const SizedBox.shrink(),
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingGate extends StatelessWidget {
  const _LoadingGate({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return PointyLoadingArea(label: l10n.checkingRegisterSession);
  }
}

class _ResumeSessionGate extends StatelessWidget {
  const _ResumeSessionGate({required this.viewModel});

  final PosViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final session = viewModel.availableRegisterSession!;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDataRow(
          title: l10n.resumeRegisterSessionTitle(session.sessionNumber),
          subtitle: l10n.registerSessionOpeningCash(
            formatMoney(session.openingCash),
          ),
          leading: const Icon(Icons.point_of_sale_outlined),
          minHeight: 76,
        ),
        SizedBox(height: spacing.md),
        ResponsiveActionBar(
          actions: [
            FilledButton.icon(
              onPressed: viewModel.resumeRegisterSession,
              icon: const Icon(Icons.login),
              label: Text(l10n.resumeRegisterSessionButton),
            ),
          ],
        ),
      ],
    );
  }
}

class _StartSessionGate extends StatelessWidget {
  const _StartSessionGate({
    required this.viewModel,
    required this.openingCashController,
    required this.showOpeningCashRequiredError,
    required this.onOpeningCashChanged,
    required this.onOpeningCashRequiredError,
  });

  final PosViewModel viewModel;
  final TextEditingController openingCashController;
  final bool showOpeningCashRequiredError;
  final VoidCallback onOpeningCashChanged;
  final VoidCallback onOpeningCashRequiredError;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final isStarting = viewModel.isStartingRegisterSession;
    // A failed lookup lands here too, because a session we could not read is
    // indistinguishable from one that does not exist. Saying "no open session"
    // in that case asserts something we do not know, and pointing the cashier
    // at the start button invites a second session on top of the one the
    // server may already hold — so when the call failed, say so and lead with
    // the retry instead.
    final failedToRead = viewModel.hasRegisterSessionError;
    final retryButton = _action(
      key: const ValueKey('register_session_gate_retry_button'),
      primary: failedToRead,
      onPressed: isStarting ? null : viewModel.loadCurrentRegisterSession,
      icon: const Icon(Icons.refresh),
      label: Text(l10n.retryButton),
    );
    // The key rides the wrapper, not the button: the action bar's contract is
    // read off the widget it is handed, and `find.byKey` must still match
    // exactly one widget.
    final startButton = TutorTarget(
      key: const ValueKey('register_session_gate_start_button'),
      anchor: TutorAnchor.registerStartSessionButton,
      child: _action(
        primary: !failedToRead,
        onPressed: isStarting ? null : () => _startSession(context),
        icon: isStarting
            ? const SizedBox.square(
                dimension: 18,
                child: PointySpinner(strokeWidth: 2),
              )
            : const Icon(Icons.play_arrow),
        label: Text(
          isStarting
              ? l10n.startingRegisterSessionButton
              : l10n.startRegisterSessionButton,
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (failedToRead)
          PointyInlineMessage.error(
            message: l10n.registerSessionLoadError,
            icon: Icons.warning_amber_outlined,
          )
        else
          PointyInlineMessage(
            message: l10n.noOpenRegisterSession,
            icon: Icons.info_outline,
          ),
        SizedBox(height: spacing.md),
        TutorTarget(
          anchor: TutorAnchor.registerOpeningCashField,
          child: TextField(
            controller: openingCashController,
            enabled: !isStarting,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
            onChanged: (_) => onOpeningCashChanged(),
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: l10n.openingCashInputLabel,
              hintText: viewModel.requireOpeningCash
                  ? null
                  : l10n.moneyAmountHint,
              errorText: showOpeningCashRequiredError
                  ? l10n.openingCashRequiredError
                  : null,
              prefixIcon: const Icon(Icons.payments_outlined),
            ),
          ),
        ),
        SizedBox(height: spacing.md),
        ResponsiveActionBar(
          // The bar renders in order and the design system reads the last
          // action as the primary one, so the emphasised button also goes last.
          actions: failedToRead
              ? [startButton, retryButton]
              : [retryButton, startButton],
        ),
      ],
    );
  }

  Widget _action({
    Key? key,
    required bool primary,
    required VoidCallback? onPressed,
    required Widget icon,
    required Widget label,
  }) {
    return primary
        ? FilledButton.icon(
            key: key,
            onPressed: onPressed,
            icon: icon,
            label: label,
          )
        : OutlinedButton.icon(
            key: key,
            onPressed: onPressed,
            icon: icon,
            label: label,
          );
  }

  Future<void> _startSession(BuildContext context) async {
    final normalized = openingCashController.text.replaceAll(',', '.');
    if (viewModel.requireOpeningCash && normalized.trim().isEmpty) {
      onOpeningCashRequiredError();
      return;
    }
    final openingCash = double.tryParse(normalized) ?? 0;
    await viewModel.startRegisterSession(openingCash: openingCash);
  }
}
