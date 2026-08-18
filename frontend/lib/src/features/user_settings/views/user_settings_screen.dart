import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/employee.dart';
import '../../../data/models/pos_user.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
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
    _firstNameController.dispose();
    _lastNameController.dispose();
    _usernameController.dispose();
    _emailController.dispose();
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
                decoration: InputDecoration(labelText: l10n.usernameLabel),
                textInputAction: TextInputAction.next,
                validator: (value) => (value ?? '').trim().isEmpty
                    ? l10n.requiredFieldError
                    : null,
              ),
              TextFormField(
                controller: _emailController,
                decoration: InputDecoration(labelText: l10n.emailLabel),
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
              ),
            ],
          ),
          if (widget.viewModel.hasProfileSaveError) ...[
            SizedBox(height: spacing.md),
            PointyInlineMessage.error(
              message: l10n.userSettingsProfileSaveError,
            ),
          ],
          SizedBox(height: spacing.md),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              onPressed: widget.viewModel.isSavingProfile ? null : _save,
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
  void dispose() {
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
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
              PointyPasswordField(
                controller: _currentPasswordController,
                labelText: l10n.currentPasswordLabel,
                prefixIcon: null,
                textInputAction: TextInputAction.next,
                validator: (value) =>
                    (value ?? '').isEmpty ? l10n.requiredFieldError : null,
              ),
              PointyPasswordField(
                controller: _newPasswordController,
                labelText: l10n.newPasswordLabel,
                prefixIcon: null,
                textInputAction: TextInputAction.next,
                validator: (value) =>
                    (value ?? '').isEmpty ? l10n.requiredFieldError : null,
              ),
              PointyPasswordField(
                controller: _confirmPasswordController,
                labelText: l10n.confirmPasswordLabel,
                prefixIcon: null,
                textInputAction: TextInputAction.done,
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
          if (widget.viewModel.hasPasswordChangeError) ...[
            SizedBox(height: spacing.md),
            PointyInlineMessage.error(
              message: l10n.userSettingsPasswordChangeError,
            ),
          ],
          SizedBox(height: spacing.md),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              onPressed: widget.viewModel.isChangingPassword ? null : _save,
              icon: const Icon(Icons.lock_reset_outlined),
              label: Text(l10n.changePasswordButton),
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.userSettingsPasswordChanged)));
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
