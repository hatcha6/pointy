import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/onboarding.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/auth_view_model.dart';

class InitialAdminSetupScreen extends StatefulWidget {
  const InitialAdminSetupScreen({super.key, required this.viewModel});

  final AuthViewModel viewModel;

  @override
  State<InitialAdminSetupScreen> createState() =>
      _InitialAdminSetupScreenState();
}

class _InitialAdminSetupScreenState extends State<InitialAdminSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController(text: 'admin');
  final _emailController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final spacing = AdaptiveSpacing.of(context);

        return PointyScaffold(
          body: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.hasBoundedWidth
                  ? constraints.maxWidth
                  : MediaQuery.sizeOf(context).width;
              final isWide = AppBreakpoints.usesTwoPane(width);

              return Center(
                child: SingleChildScrollView(
                  padding: spacing.pagePadding,
                  child: AdaptiveMaxWidth(
                    width: isWide
                        ? AppContentWidth.detail
                        : AppContentWidth.compact,
                    expand: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SetupHeader(title: l10n.onboardingTitle),
                        SizedBox(height: spacing.md),
                        PointyDetailSection(
                          title: l10n.onboardingAdminSectionTitle,
                          icon: Icons.admin_panel_settings_outlined,
                          child: _SetupForm(
                            formKey: _formKey,
                            usernameController: _usernameController,
                            emailController: _emailController,
                            firstNameController: _firstNameController,
                            lastNameController: _lastNameController,
                            passwordController: _passwordController,
                            confirmPasswordController:
                                _confirmPasswordController,
                            isSubmitting: widget.viewModel.isSubmitting,
                            hasError: widget.viewModel.hasError,
                            onSubmit: _submit,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    await widget.viewModel.createInitialAdmin(
      InitialAdminDraft(
        username: _usernameController.text,
        email: _emailController.text,
        firstName: _firstNameController.text,
        lastName: _lastNameController.text,
        password: _passwordController.text,
      ),
    );
  }
}

class _SetupHeader extends StatelessWidget {
  const _SetupHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox.square(
          dimension: 44,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.primaryStrong,
              borderRadius: BorderRadius.circular(PointyRadii.card),
            ),
            child: Icon(
              Icons.point_of_sale_outlined,
              color: colors.surface,
              size: 24,
            ),
          ),
        ),
        SizedBox(width: spacing.sm),
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: colors.ink,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

class _SetupForm extends StatelessWidget {
  const _SetupForm({
    required this.formKey,
    required this.usernameController,
    required this.emailController,
    required this.firstNameController,
    required this.lastNameController,
    required this.passwordController,
    required this.confirmPasswordController,
    required this.isSubmitting,
    required this.hasError,
    required this.onSubmit,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController usernameController;
  final TextEditingController emailController;
  final TextEditingController firstNameController;
  final TextEditingController lastNameController;
  final TextEditingController passwordController;
  final TextEditingController confirmPasswordController;
  final bool isSubmitting;
  final bool hasError;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Form(
      key: formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PointyInlineMessage(message: l10n.onboardingIntro),
          SizedBox(height: spacing.md),
          TextFormField(
            controller: usernameController,
            enabled: !isSubmitting,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username],
            decoration: InputDecoration(
              labelText: l10n.usernameLabel,
              prefixIcon: const Icon(Icons.person_outline),
            ),
            validator: (value) => value == null || value.trim().isEmpty
                ? l10n.requiredField
                : null,
          ),
          SizedBox(height: spacing.sm),
          ResponsiveFormGrid(
            minChildWidth: 220,
            children: [
              TextFormField(
                controller: firstNameController,
                enabled: !isSubmitting,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: l10n.firstNameLabel,
                  prefixIcon: const Icon(Icons.badge_outlined),
                ),
              ),
              TextFormField(
                controller: lastNameController,
                enabled: !isSubmitting,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: l10n.lastNameLabel,
                  prefixIcon: const Icon(Icons.badge_outlined),
                ),
              ),
            ],
          ),
          SizedBox(height: spacing.sm),
          TextFormField(
            controller: emailController,
            enabled: !isSubmitting,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
            decoration: InputDecoration(
              labelText: l10n.emailLabel,
              prefixIcon: const Icon(Icons.alternate_email),
            ),
          ),
          SizedBox(height: spacing.sm),
          PointyPasswordField(
            controller: passwordController,
            labelText: l10n.newPasswordLabel,
            enabled: !isSubmitting,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.newPassword],
            validator: (value) =>
                value == null || value.isEmpty ? l10n.requiredField : null,
          ),
          SizedBox(height: spacing.sm),
          PointyPasswordField(
            controller: confirmPasswordController,
            labelText: l10n.confirmPasswordLabel,
            enabled: !isSubmitting,
            prefixIcon: Icons.lock_reset_outlined,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.newPassword],
            onFieldSubmitted: (_) => onSubmit(),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return l10n.requiredField;
              }
              if (value != passwordController.text) {
                return l10n.passwordConfirmationMismatch;
              }
              return null;
            },
          ),
          if (hasError) ...[
            SizedBox(height: spacing.sm),
            PointyInlineMessage.error(message: l10n.onboardingCreateAdminError),
          ],
          SizedBox(height: spacing.md),
          ResponsiveActionBar(
            actions: [
              FilledButton.icon(
                onPressed: isSubmitting ? null : onSubmit,
                icon: isSubmitting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: PointySpinner(strokeWidth: 2),
                      )
                    : const Icon(Icons.admin_panel_settings_outlined),
                label: Text(
                  isSubmitting
                      ? l10n.onboardingCreatingAdminButton
                      : l10n.onboardingCreateAdminButton,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
