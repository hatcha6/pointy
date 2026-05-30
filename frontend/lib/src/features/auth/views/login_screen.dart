import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
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
                    child: _LoginLayout(
                      appTitle: l10n.appTitle,
                      isWide: isWide,
                      form: _LoginForm(
                        formKey: _formKey,
                        usernameController: _usernameController,
                        passwordController: _passwordController,
                        isSubmitting: widget.viewModel.isSubmitting,
                        hasError: widget.viewModel.hasError,
                        onSubmit: _submit,
                      ),
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

    await widget.viewModel.login(
      username: _usernameController.text.trim(),
      password: _passwordController.text,
    );
  }
}

class _LoginLayout extends StatelessWidget {
  const _LoginLayout({
    required this.appTitle,
    required this.isWide,
    required this.form,
  });

  final String appTitle;
  final bool isWide;
  final Widget form;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);

    if (isWide) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: AppPaneWidths.standard,
            child: _LoginBrandPanel(
              key: const ValueKey('login_brand_panel'),
              appTitle: appTitle,
              minHeight: 344,
            ),
          ),
          SizedBox(width: spacing.paneGap),
          Flexible(child: form),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CompactLoginHeader(
          key: const ValueKey('login_compact_header'),
          appTitle: appTitle,
        ),
        SizedBox(height: spacing.md),
        form,
      ],
    );
  }
}

class _CompactLoginHeader extends StatelessWidget {
  const _CompactLoginHeader({super.key, required this.appTitle});

  final String appTitle;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _LoginMark(size: 44),
        SizedBox(width: spacing.sm),
        Flexible(
          child: Text(
            appTitle,
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

class _LoginBrandPanel extends StatelessWidget {
  const _LoginBrandPanel({
    super.key,
    required this.appTitle,
    required this.minHeight,
  });

  final String appTitle;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color.alphaBlend(
            colors.primaryStrong.withValues(alpha: 0.08),
            colors.surface,
          ),
          border: Border.all(
            color: colors.primaryStrong.withValues(alpha: 0.12),
          ),
          borderRadius: BorderRadius.circular(PointyRadii.card),
        ),
        child: Padding(
          padding: EdgeInsetsDirectional.all(spacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _LoginMark(size: 64),
              SizedBox(height: spacing.xxl),
              Text(
                appTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoginMark extends StatelessWidget {
  const _LoginMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;

    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.primaryStrong,
          borderRadius: BorderRadius.circular(PointyRadii.card),
          boxShadow: [
            BoxShadow(
              color: colors.primaryStrong.withValues(alpha: 0.16),
              blurRadius: 18,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Icon(
          Icons.point_of_sale_outlined,
          color: colors.surface,
          size: size * 0.52,
        ),
      ),
    );
  }
}

class _LoginForm extends StatelessWidget {
  const _LoginForm({
    required this.formKey,
    required this.usernameController,
    required this.passwordController,
    required this.isSubmitting,
    required this.hasError,
    required this.onSubmit,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final bool isSubmitting;
  final bool hasError;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return PointyDetailSection(
      title: l10n.loginTitle,
      icon: Icons.login_outlined,
      child: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: usernameController,
              enabled: !isSubmitting,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: l10n.usernameLabel,
                prefixIcon: const Icon(Icons.person_outline),
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? l10n.requiredField
                  : null,
            ),
            SizedBox(height: spacing.sm),
            TextFormField(
              controller: passwordController,
              enabled: !isSubmitting,
              obscureText: true,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => onSubmit(),
              decoration: InputDecoration(
                labelText: l10n.passwordLabel,
                prefixIcon: const Icon(Icons.lock_outline),
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? l10n.requiredField
                  : null,
            ),
            if (hasError) ...[
              SizedBox(height: spacing.sm),
              PointyInlineMessage.error(message: l10n.loginError),
            ],
            SizedBox(height: spacing.md),
            ResponsiveActionBar(
              actions: [
                FilledButton.icon(
                  onPressed: isSubmitting ? null : onSubmit,
                  icon: isSubmitting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: Text(
                    isSubmitting ? l10n.loggingInButton : l10n.loginButton,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
