import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/formatters.dart';
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

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20),
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(l10n.checkingRegisterSession),
      ],
    );
  }
}

class _ResumeSessionGate extends StatelessWidget {
  const _ResumeSessionGate({required this.viewModel});

  final PosViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final session = viewModel.availableRegisterSession!;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.registerSessionGateTitle,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.point_of_sale_outlined),
          title: Text(l10n.resumeRegisterSessionTitle(session.sessionNumber)),
          subtitle: Text(
            l10n.registerSessionOpeningCash(formatMoney(session.openingCash)),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: viewModel.resumeRegisterSession,
          icon: const Icon(Icons.login),
          label: Text(l10n.resumeRegisterSessionButton),
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.registerSessionGateTitle,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(l10n.noOpenRegisterSession),
        if (viewModel.hasRegisterSessionError) ...[
          const SizedBox(height: 12),
          Text(
            l10n.registerSessionLoadError,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: openingCashController,
          enabled: !viewModel.isStartingRegisterSession,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [DecimalTextInputFormatter()],
          onChanged: (_) => onOpeningCashChanged(),
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: l10n.openingCashInputLabel,
            hintText: viewModel.requireOpeningCash ? null : '0.00',
            errorText: showOpeningCashRequiredError
                ? l10n.openingCashRequiredError
                : null,
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.payments_outlined),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: viewModel.isStartingRegisterSession
              ? null
              : () => _startSession(context),
          icon: viewModel.isStartingRegisterSession
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow),
          label: Text(
            viewModel.isStartingRegisterSession
                ? l10n.startingRegisterSessionButton
                : l10n.startRegisterSessionButton,
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: viewModel.isStartingRegisterSession
              ? null
              : viewModel.loadCurrentRegisterSession,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.retryRegisterSessionButton),
        ),
      ],
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
