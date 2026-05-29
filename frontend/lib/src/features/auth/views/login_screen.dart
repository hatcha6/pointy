import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/auth_view_model.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.viewModel});

  final AuthViewModel viewModel;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
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
          body: Center(
            child: SingleChildScrollView(
              padding: spacing.pagePadding,
              child: AdaptiveMaxWidth(
                width: AppContentWidth.compact,
                expand: false,
                child: PointyDetailSection(
                  title: l10n.loginTitle,
                  icon: Icons.point_of_sale,
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          controller: _usernameController,
                          enabled: !widget.viewModel.isSubmitting,
                          textInputAction: TextInputAction.next,
                          decoration: InputDecoration(
                            labelText: l10n.usernameLabel,
                            prefixIcon: const Icon(Icons.person_outline),
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? l10n.requiredField
                              : null,
                        ),
                        SizedBox(height: spacing.sm),
                        TextFormField(
                          controller: _passwordController,
                          enabled: !widget.viewModel.isSubmitting,
                          obscureText: true,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) => _submit(),
                          decoration: InputDecoration(
                            labelText: l10n.passwordLabel,
                            prefixIcon: const Icon(Icons.lock_outline),
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? l10n.requiredField
                              : null,
                        ),
                        if (widget.viewModel.hasError) ...[
                          SizedBox(height: spacing.sm),
                          PointyInlineMessage.error(message: l10n.loginError),
                        ],
                        SizedBox(height: spacing.md),
                        FilledButton.icon(
                          onPressed: widget.viewModel.isSubmitting
                              ? null
                              : _submit,
                          icon: widget.viewModel.isSubmitting
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.login),
                          label: Text(
                            widget.viewModel.isSubmitting
                                ? l10n.loggingInButton
                                : l10n.loginButton,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    await widget.viewModel.login(
      username: _usernameController.text.trim(),
      password: _passwordController.text,
    );
  }
}
