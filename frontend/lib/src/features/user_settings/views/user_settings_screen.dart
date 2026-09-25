import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/employee.dart';
import '../../../data/models/password_policy.dart';
import '../../../data/models/pos_user.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../users/username_rules.dart';
import '../view_models/user_settings_view_model.dart';

class UserSettingsScreen extends StatefulWidget {
  const UserSettingsScreen({
    super.key,
    required this.viewModel,
    required this.currentUser,
    required this.onUserChanged,
    required this.navigation,
  });

  final UserSettingsViewModel viewModel;
  final PosUser currentUser;
  final ValueChanged<PosUser> onUserChanged;
  final AppNavigation navigation;

  @override
  State<UserSettingsScreen> createState() => _UserSettingsScreenState();
}

class _UserSettingsScreenState extends State<UserSettingsScreen> {
  @override
  void initState() {
    super.initState();
    widget.viewModel.setCurrentUser(widget.currentUser);
  }

  @override
  void didUpdateWidget(covariant UserSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUser.id != widget.currentUser.id ||
        oldWidget.currentUser.username != widget.currentUser.username) {
      widget.viewModel.setCurrentUser(widget.currentUser);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.userSettings,
            navigation: widget.navigation,
          ),
          appBar: PointyAppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.userSettingsTitle),
            isLoading:
                widget.viewModel.isLoadingLoans ||
                widget.viewModel.isSavingProfile ||
                widget.viewModel.isChangingPassword ||
                widget.viewModel.isRequestingLoan,
            reserveLoadingSlot: false,
            actions: [
              IconButton(
                tooltip: l10n.userSettingsRefreshLoansTooltip,
                onPressed: widget.viewModel.isLoadingLoans
                    ? null
                    : widget.viewModel.loadMyLoans,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          body: _UserSettingsBody(
            viewModel: widget.viewModel,
            currentUser: widget.currentUser,
            onUserChanged: widget.onUserChanged,
          ),
        );
      },
    );
  }
}

class _UserSettingsBody extends StatelessWidget {
  const _UserSettingsBody({
    required this.viewModel,
    required this.currentUser,
    required this.onUserChanged,
  });

  final UserSettingsViewModel viewModel;
  final PosUser currentUser;
  final ValueChanged<PosUser> onUserChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PointySectionHeader(
                title: l10n.userSettingsOverviewTitle,
                subtitle: l10n.userSettingsOverviewSubtitle,
                leading: const Icon(Icons.manage_accounts_outlined),
              ),
              SizedBox(height: spacing.md),
              PointyDetailSection(
                icon: Icons.person_outline,
                title: l10n.userSettingsProfileSectionTitle,
                child: _ProfileForm(
                  viewModel: viewModel,
                  currentUser: viewModel.currentUser ?? currentUser,
                  onUserChanged: onUserChanged,
                ),
              ),
              SizedBox(height: spacing.lg),
              PointyDetailSection(
                icon: Icons.lock_outline,
                title: l10n.userSettingsPasswordSectionTitle,
                child: _PasswordForm(viewModel: viewModel),
              ),
              SizedBox(height: spacing.lg),
              PointyDetailSection(
                icon: Icons.account_balance_wallet_outlined,
                title: l10n.userSettingsLoansSectionTitle,
                child: _LoanPanel(viewModel: viewModel),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProfileForm extends StatefulWidget {
  const _ProfileForm({
    required this.viewModel,
    required this.currentUser,
    required this.onUserChanged,
  });

  final UserSettingsViewModel viewModel;
  final PosUser currentUser;
  final ValueChanged<PosUser> onUserChanged;

  @override
  State<_ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends State<_ProfileForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _usernameController;
  late final TextEditingController _emailController;

  @override
  void initState() {
    super.initState();
    _firstNameController = TextEditingController(
      text: widget.currentUser.firstName,
    );
    _lastNameController = TextEditingController(
      text: widget.currentUser.lastName,
    );
    _usernameController = TextEditingController(
      text: widget.currentUser.username,
    );
    _emailController = TextEditingController(text: widget.currentUser.email);
    // Save is gated on there being something to save, so every keystroke has to
    // reach the button's enabled state.
    for (final controller in [
      _firstNameController,
      _lastNameController,
      _usernameController,
      _emailController,
    ]) {
      controller.addListener(_onEdited);
    }
  }

  void _onEdited() => setState(() {});

  bool get _isDirty {
    final user = widget.currentUser;
    return _firstNameController.text.trim() != user.firstName.trim() ||
        _lastNameController.text.trim() != user.lastName.trim() ||
        _usernameController.text.trim() != user.username.trim() ||
        _emailController.text.trim() != user.email.trim();
  }

  @override
  void didUpdateWidget(covariant _ProfileForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.viewModel.isSavingProfile &&
        oldWidget.currentUser != widget.currentUser) {
      _setText(_firstNameController, widget.currentUser.firstName);
      _setText(_lastNameController, widget.currentUser.lastName);
      _setText(_usernameController, widget.currentUser.username);
      _setText(_emailController, widget.currentUser.email);
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _firstNameController,
      _lastNameController,
      _usernameController,
      _emailController,
    ]) {
      controller.removeListener(_onEdited);
      controller.dispose();
    }
    super.dispose();
  }

  void _setText(TextEditingController controller, String value) {
    if (controller.text != value) {
      controller.text = value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ResponsiveFormGrid(
            children: [
              TextFormField(
                controller: _firstNameController,
                decoration: InputDecoration(labelText: l10n.firstNameLabel),
                textInputAction: TextInputAction.next,
              ),
              TextFormField(
                controller: _lastNameController,
                decoration: InputDecoration(labelText: l10n.lastNameLabel),
                textInputAction: TextInputAction.next,
              ),
              TextFormField(
                controller: _usernameController,
                decoration: InputDecoration(
                  labelText: l10n.usernameLabel,
                  // The server rejects a duplicate username; showing that on the
                  // field says which of the four inputs to change.
                  errorText:
                      widget.viewModel.profileIssue ==
                          ProfileFieldIssue.usernameTaken
                      ? l10n.profileUsernameTakenError
                      : null,
                ),
                textDirection: TextDirection.ltr,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.next,
                validator: (value) => (value ?? '').trim().isEmpty
                    ? l10n.requiredFieldError
                    : usernameFormatError(l10n, value),
              ),
              TextFormField(
                controller: _emailController,
                decoration: InputDecoration(
                  labelText: l10n.emailLabel,
                  errorText:
                      widget.viewModel.profileIssue ==
                          ProfileFieldIssue.emailInvalid
                      ? l10n.profileEmailInvalidError
                      : null,
                ),
                textDirection: TextDirection.ltr,
                autocorrect: false,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
                validator: (value) {
                  final email = (value ?? '').trim();
                  if (email.isEmpty) return null;
                  return _looksLikeEmail(email)
                      ? null
                      : l10n.profileEmailInvalidError;
                },
              ),
            ],
          ),
          // A field-level error already points at the offending input; repeating
          // it in a banner would say the same thing twice, less usefully.
          if (widget.viewModel.hasProfileSaveError &&
              widget.viewModel.profileIssue == ProfileFieldIssue.other) ...[
            SizedBox(height: spacing.md),
            PointyInlineMessage.error(
              message: l10n.userSettingsProfileSaveError,
            ),
          ],
          SizedBox(height: spacing.md),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              onPressed: widget.viewModel.isSavingProfile || !_isDirty
                  ? null
                  : _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(l10n.saveChangesButton),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final updated = await widget.viewModel.updateProfile(
      CurrentUserProfileDraft(
        username: _usernameController.text,
        firstName: _firstNameController.text,
        lastName: _lastNameController.text,
        email: _emailController.text,
      ),
    );
    if (!mounted || updated == null) {
      return;
    }
    widget.onUserChanged(updated);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.userSettingsProfileSaved)));
  }
}

class _PasswordForm extends StatefulWidget {
  const _PasswordForm({required this.viewModel});

  final UserSettingsViewModel viewModel;

  @override
  State<_PasswordForm> createState() => _PasswordFormState();
}

class _PasswordFormState extends State<_PasswordForm> {
  final _formKey = GlobalKey<FormState>();
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // The confirmation's match state has to update as either field changes, not
    // only when Save is pressed.
    _confirmPasswordController.addListener(_onEdited);
  }

  void _onEdited() => setState(() {});

  @override
  void dispose() {
    _confirmPasswordController.removeListener(_onEdited);
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final viewModel = widget.viewModel;
    final assessment = viewModel.passwordAssessment;
    final newPassword = _newPasswordController.text;
    final confirmation = _confirmPasswordController.text;
    // Flagged only once something has been typed — complaining about an empty
    // box is nagging, not helping.
    final mismatch = confirmation.isNotEmpty && confirmation != newPassword;

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ResponsiveFormGrid(
            children: [
              PointyPasswordField(
                controller: _currentPasswordController,
                labelText: l10n.currentPasswordLabel,
                prefixIcon: null,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.password],
                onChanged: (_) => setState(() {}),
                validator: (value) =>
                    (value ?? '').isEmpty ? l10n.requiredFieldError : null,
              ),
              PointyPasswordField(
                controller: _newPasswordController,
                labelText: l10n.newPasswordLabel,
                prefixIcon: null,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.newPassword],
                onChanged: (value) {
                  viewModel.setNewPassword(value);
                  setState(() {});
                },
                validator: (value) =>
                    (value ?? '').isEmpty ? l10n.requiredFieldError : null,
              ),
              PointyPasswordField(
                controller: _confirmPasswordController,
                labelText: l10n.confirmPasswordLabel,
                prefixIcon: null,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.newPassword],
                // Live, not on-submit: a mismatch you only learn about after
                // pressing the button means retyping both fields.
                helperText: mismatch ? null : ' ',
                errorText: mismatch ? l10n.passwordConfirmationMismatch : null,
                onFieldSubmitted: (_) {
                  if (_canSubmit(mismatch)) _save();
                },
                validator: (value) {
                  if ((value ?? '').isEmpty) {
                    return l10n.requiredFieldError;
                  }
                  if (value != _newPasswordController.text) {
                    return l10n.passwordConfirmationMismatch;
                  }
                  return null;
                },
              ),
            ],
          ),
          SizedBox(height: spacing.md),
          _PasswordGuidance(
            policy: viewModel.passwordPolicy,
            assessment: assessment,
          ),
          if (viewModel.hasPasswordChangeError) ...[
            SizedBox(height: spacing.md),
            PointyInlineMessage.error(
              message: switch (viewModel.passwordFailure) {
                PasswordChangeFailure.currentPasswordWrong =>
                  l10n.passwordCurrentIncorrectError,
                PasswordChangeFailure.throttled =>
                  l10n.passwordChangeThrottledError,
                PasswordChangeFailure.ruleRejected =>
                  l10n.passwordChangeRuleRejectedError,
                PasswordChangeFailure.none || PasswordChangeFailure.unknown =>
                  l10n.userSettingsPasswordChangeError,
              },
            ),
          ],
          SizedBox(height: spacing.md),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              onPressed: _canSubmit(mismatch) ? _save : null,
              icon: const Icon(Icons.lock_reset_outlined),
              label: Text(l10n.changePasswordButton),
            ),
          ),
        ],
      ),
    );
  }

  /// Only the *requirements* gate the button. Ignoring every suggestion still
  /// saves — that is the point of them being suggestions.
  /// All three boxes have to be filled: an enabled button that only paints
  /// "this field is required" once pressed is a button that lied about what
  /// pressing it would do.
  bool _canSubmit(bool mismatch) {
    return !widget.viewModel.isChangingPassword &&
        !mismatch &&
        _currentPasswordController.text.isNotEmpty &&
        _confirmPasswordController.text.isNotEmpty &&
        widget.viewModel.canChangePassword;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final saved = await widget.viewModel.changePassword(
      PasswordChangeDraft(
        currentPassword: _currentPasswordController.text,
        newPassword: _newPasswordController.text,
      ),
    );
    if (!mounted || !saved) {
      return;
    }
    _currentPasswordController.clear();
    _newPasswordController.clear();
    _confirmPasswordController.clear();
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.userSettingsPasswordChanged)));
  }
}

/// The rules, stated before the attempt rather than after it.
///
/// Two lists, kept visually distinct on purpose: what the password *must* be
/// (one short floor) and what would make it stronger. The second list never
/// blocks anything — staff sign in on a shared terminal all shift and pick a
/// short PIN, and a form that refuses that is a form they route around.
class _PasswordGuidance extends StatelessWidget {
  const _PasswordGuidance({required this.policy, required this.assessment});

  final PasswordPolicy policy;
  final PasswordAssessment assessment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (policy.required.isNotEmpty) ...[
          Text(l10n.passwordRulesTitle, style: theme.textTheme.titleSmall),
          SizedBox(height: spacing.xs),
          for (final rule in policy.required)
            _RuleLine(
              label: switch (rule) {
                PasswordRequirement.minLength => l10n.passwordRuleMinLength(
                  policy.minLength,
                ),
              },
              state: assessment.requirements[rule] ?? PasswordRuleState.pending,
              isAdvice: false,
            ),
        ],
        if (policy.advisory.isNotEmpty) ...[
          SizedBox(height: spacing.md),
          Text(l10n.passwordAdviceTitle, style: theme.textTheme.titleSmall),
          Text(
            l10n.passwordAdviceNote,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: spacing.xs),
          for (final item in policy.advisory)
            _RuleLine(
              label: switch (item) {
                PasswordAdvice.recommendedLength =>
                  l10n.passwordAdviceRecommendedLength(
                    policy.recommendedMinLength,
                  ),
                PasswordAdvice.notNumeric => l10n.passwordAdviceNotNumeric,
                PasswordAdvice.notCommon => l10n.passwordAdviceNotCommon,
                PasswordAdvice.notSimilarToUser =>
                  l10n.passwordAdviceNotSimilarToUser,
              },
              state: assessment.advice[item] ?? PasswordRuleState.pending,
              isAdvice: true,
            ),
        ],
      ],
    );
  }
}

class _RuleLine extends StatelessWidget {
  const _RuleLine({
    required this.label,
    required this.state,
    required this.isAdvice,
  });

  final String label;
  final PasswordRuleState state;
  final bool isAdvice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

    // An unmet suggestion is not an error, so it never turns red — it simply
    // stays un-ticked. Only a broken requirement earns the danger colour.
    final (icon, color) = switch ((state, isAdvice)) {
      (PasswordRuleState.satisfied, _) => (
        Icons.check_circle_outline,
        colors.success,
      ),
      (PasswordRuleState.failed, false) => (
        Icons.cancel_outlined,
        colors.danger,
      ),
      (PasswordRuleState.failed, true) => (
        Icons.radio_button_unchecked,
        colors.mutedInk,
      ),
      (PasswordRuleState.pending, _) => (
        Icons.radio_button_unchecked,
        colors.mutedInk,
      ),
    };

    return Padding(
      padding: EdgeInsets.symmetric(vertical: spacing.xs / 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: state == PasswordRuleState.satisfied
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoanPanel extends StatefulWidget {
  const _LoanPanel({required this.viewModel});

  final UserSettingsViewModel viewModel;

  @override
  State<_LoanPanel> createState() => _LoanPanelState();
}

class _LoanPanelState extends State<_LoanPanel> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _monthlyDeductionController = TextEditingController();
  final _purposeController = TextEditingController();

  @override
  void dispose() {
    _amountController.dispose();
    _monthlyDeductionController.dispose();
    _purposeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (widget.viewModel.isLoadingLoans &&
        widget.viewModel.employee == null &&
        widget.viewModel.loans.isEmpty) {
      return const PointyLoadingArea();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.viewModel.hasLoanLoadError) ...[
          PointyInlineMessage.error(message: l10n.userSettingsLoansLoadError),
          SizedBox(height: spacing.md),
        ],
        if (!widget.viewModel.hasEmployeeRecord) ...[
          PointyInlineMessage.warning(
            message: l10n.userSettingsLoanNoEmployeeRecord,
          ),
        ] else ...[
          _LoanRequestForm(
            formKey: _formKey,
            amountController: _amountController,
            monthlyDeductionController: _monthlyDeductionController,
            purposeController: _purposeController,
            isSaving: widget.viewModel.isRequestingLoan,
            hasError: widget.viewModel.hasLoanRequestError,
            onSubmit: _submitLoan,
          ),
          SizedBox(height: spacing.lg),
          _LoanList(loans: widget.viewModel.loans),
        ],
      ],
    );
  }

  Future<void> _submitLoan() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final saved = await widget.viewModel.requestLoan(
      EmployeeLoanRequestDraft(
        amount: _amountController.text,
        monthlyDeduction: _monthlyDeductionController.text,
        purpose: _purposeController.text,
      ),
    );
    if (!mounted || !saved) {
      return;
    }
    _amountController.clear();
    _monthlyDeductionController.clear();
    _purposeController.clear();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.userSettingsLoanRequested)));
  }
}

class _LoanRequestForm extends StatelessWidget {
  const _LoanRequestForm({
    required this.formKey,
    required this.amountController,
    required this.monthlyDeductionController,
    required this.purposeController,
    required this.isSaving,
    required this.hasError,
    required this.onSubmit,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController amountController;
  final TextEditingController monthlyDeductionController;
  final TextEditingController purposeController;
  final bool isSaving;
  final bool hasError;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final inputFormatters = <TextInputFormatter>[
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
      DecimalTextInputFormatter(),
    ];

    return Form(
      key: formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ResponsiveFormGrid(
            children: [
              TextFormField(
                controller: amountController,
                decoration: InputDecoration(labelText: l10n.loanAmountLabel),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: inputFormatters,
                validator: (value) => _positiveMoneyValidator(context, value),
              ),
              TextFormField(
                controller: monthlyDeductionController,
                decoration: InputDecoration(
                  labelText: l10n.loanMonthlyDeductionLabel,
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: inputFormatters,
                validator: (value) {
                  final basic = _positiveMoneyValidator(context, value);
                  if (basic != null) {
                    return basic;
                  }
                  final amount = double.tryParse(amountController.text) ?? 0;
                  final monthly = double.tryParse(value ?? '') ?? 0;
                  if (monthly > amount) {
                    return l10n.loanMonthlyDeductionTooHigh;
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: purposeController,
                decoration: InputDecoration(labelText: l10n.loanPurposeLabel),
                minLines: 1,
                maxLines: 3,
              ),
            ],
          ),
          if (hasError) ...[
            SizedBox(height: spacing.md),
            PointyInlineMessage.error(
              message: l10n.userSettingsLoanRequestError,
            ),
          ],
          SizedBox(height: spacing.md),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              onPressed: isSaving ? null : onSubmit,
              icon: const Icon(Icons.send_outlined),
              label: Text(l10n.submitLoanRequestButton),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoanList extends StatelessWidget {
  const _LoanList({required this.loans});

  final List<EmployeeLoan> loans;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (loans.isEmpty) {
      return PointyEmptyState(
        icon: Icons.account_balance_wallet_outlined,
        title: l10n.userSettingsNoLoans,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.userSettingsLoanHistoryTitle,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        SizedBox(height: spacing.sm),
        PointySettingsSection(
          children: [
            for (final loan in loans)
              ListTile(
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: Text(formatMoney(loan.amount)),
                subtitle: Text(
                  l10n.userSettingsLoanBalanceDetail(
                    formatMoney(loan.outstandingBalance),
                    formatMoney(loan.monthlyDeduction),
                  ),
                ),
                trailing: PointyStatusPill(
                  label: _loanStatusLabel(l10n, loan.status),
                  icon: _loanStatusIcon(loan.status),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A deliberately loose check — enough to catch a fat-fingered address before a
/// round trip, without inventing rules the server does not have. Django decides
/// for real; an empty field is fine, since email is optional here.
bool _looksLikeEmail(String value) {
  return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value);
}

String? _positiveMoneyValidator(BuildContext context, String? value) {
  final l10n = AppLocalizations.of(context)!;
  final parsed = double.tryParse((value ?? '').trim());
  if (parsed == null || parsed <= 0) {
    return l10n.positiveAmountRequiredError;
  }
  return null;
}

String _loanStatusLabel(AppLocalizations l10n, EmployeeLoanStatus status) {
  return switch (status) {
    EmployeeLoanStatus.requested => l10n.employeeLoanStatusRequested,
    EmployeeLoanStatus.approved => l10n.employeeLoanStatusApproved,
    EmployeeLoanStatus.rejected => l10n.employeeLoanStatusRejected,
    EmployeeLoanStatus.cancelled => l10n.employeeLoanStatusCancelled,
    EmployeeLoanStatus.paid => l10n.employeeLoanStatusPaid,
  };
}

IconData _loanStatusIcon(EmployeeLoanStatus status) {
  return switch (status) {
    EmployeeLoanStatus.requested => Icons.hourglass_top_outlined,
    EmployeeLoanStatus.approved => Icons.verified_outlined,
    EmployeeLoanStatus.rejected => Icons.cancel_outlined,
    EmployeeLoanStatus.cancelled => Icons.block_outlined,
    EmployeeLoanStatus.paid => Icons.task_alt_outlined,
  };
}
