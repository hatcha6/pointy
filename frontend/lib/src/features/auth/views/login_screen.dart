import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/auth_view_model.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.viewModel,
    this.onEnterPriceCheckerMode,
  });

  final AuthViewModel viewModel;

  /// When set, shows a "Price Checker mode" entry on the login screen so a
  /// device can be turned into (or sent back into) a customer-facing kiosk
  /// without signing in. Null hides the entry (e.g. in previews).
  final Future<void> Function(BuildContext context)? onEnterPriceCheckerMode;

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
                        _LoginLayout(
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
                        if (widget.onEnterPriceCheckerMode != null)
                          _PriceCheckerModeEntry(
                            onPressed: () =>
                                widget.onEnterPriceCheckerMode!(context),
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

    await widget.viewModel.login(
      username: _usernameController.text.trim(),
      password: _passwordController.text,
    );
  }
}

class _LoginLayout extends StatelessWidget {
  const _LoginLayout({required this.isWide, required this.form});

  final bool isWide;
  final Widget form;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);

    if (isWide) {
      final colors = context.pointyColors;

      return DecoratedBox(
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: AppPaneWidths.standard,
                child: _LoginBrandPanel(
                  key: const ValueKey('login_brand_panel'),
                  minHeight: 420,
                ),
              ),
              SizedBox(width: spacing.paneGap),
              Flexible(child: form),
            ],
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _CompactLoginHeader(key: ValueKey('login_compact_header')),
        SizedBox(height: spacing.md),
        form,
      ],
    );
  }
}

class _CompactLoginHeader extends StatelessWidget {
  const _CompactLoginHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _LoginMark(size: 44),
        SizedBox(width: spacing.sm),
        Flexible(
          child: Text(
            l10n.brandName,
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
  const _LoginBrandPanel({super.key, required this.minHeight});

  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;

    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _LoginMark(size: 168),
          SizedBox(height: spacing.xl),
          Text(
            l10n.brandName,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.displaySmall?.copyWith(
              color: colors.ink,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
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
    final radius = BorderRadius.circular(PointyRadii.card);

    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: colors.primaryStrong.withValues(alpha: 0.16),
              blurRadius: 18,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Image.asset(
            'assets/branding/logo.png',
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    );
  }
}

/// Secondary entry on the login screen to (re-)enter customer-facing kiosk mode
/// without signing in.
class _PriceCheckerModeEntry extends StatelessWidget {
  const _PriceCheckerModeEntry({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: EdgeInsetsDirectional.only(top: spacing.lg),
      child: Center(
        child: TextButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.price_check_rounded),
          label: Text(l10n.priceCheckerModeButton),
          style: TextButton.styleFrom(foregroundColor: colors.primaryStrong),
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
            PointyPasswordField(
              controller: passwordController,
              labelText: l10n.passwordLabel,
              enabled: !isSubmitting,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => onSubmit(),
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
                          child: PointySpinner(strokeWidth: 2),
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
