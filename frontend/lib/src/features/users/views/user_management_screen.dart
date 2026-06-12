import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/pos_user.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/user_management_view_model.dart';

class UserManagementScreen extends StatelessWidget {
  const UserManagementScreen({
    super.key,
    required this.viewModel,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenInvoices,
    required this.onOpenCatalog,
    required this.onOpenCategories,
    required this.onOpenPurchasing,
    required this.onOpenContacts,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onOpenUserDetails,
    required this.onLogout,
    this.onOpenDashboard,
    this.onOpenDiscounts,
    this.onOpenReports,
    this.onOpenActivityLog,
    this.onOpenShopSettings,
  });

  final UserManagementViewModel viewModel;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenInvoices;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenCategories;
  final VoidCallback onOpenPurchasing;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final ValueChanged<PosUser> onOpenUserDetails;
  final VoidCallback? onOpenDashboard;
  final VoidCallback? onOpenDiscounts;
  final VoidCallback? onOpenReports;
  final VoidCallback? onOpenActivityLog;
  final VoidCallback? onOpenShopSettings;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.users,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenDashboard: onOpenDashboard,
            onOpenPos: onOpenPos,
            onOpenInvoices: onOpenInvoices,
            onOpenPurchasing: onOpenPurchasing,
            onOpenContacts: onOpenContacts,
            onOpenCatalog: onOpenCatalog,
            onOpenCategories: onOpenCategories,
            onOpenRegisterSessions: onOpenRegisterSessions,
            onOpenDeviceSettings: onOpenDeviceSettings,
            onOpenDiscounts: onOpenDiscounts,
            onOpenReports: onOpenReports,
            onOpenActivityLog: onOpenActivityLog,
            onOpenUsers: () {},
            onOpenShopSettings: onOpenShopSettings,
            onLogout: onLogout,
          ),
          appBar: PointyAppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.usersManagementTitle),
            reserveLoadingSlot: false,
            actions: [
              UserManagementGuard(
                capabilities: capabilities,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.refreshUsersTooltip,
                  onPressed: viewModel.loadUsers,
                  icon: const Icon(Icons.sync),
                ),
              ),
            ],
          ),
          body: UserManagementGuard(
            capabilities: capabilities,
            child: _UserManagementBody(
              viewModel: viewModel,
              currentUser: currentUser,
              onOpenUserDetails: onOpenUserDetails,
              onCreateUser: viewModel.isSaving
                  ? null
                  : () => _showCreateUserSheet(context),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showCreateUserSheet(BuildContext context) {
    return showAdaptiveFormSurface<void>(
      context: context,
      size: AdaptiveModalSize.standard,
      maxHeightFactor: 0.94,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: _CreateUserForm(
            viewModel: viewModel,
            onCreated: () => Navigator.of(sheetContext).pop(),
          ),
        );
      },
    );
  }
}

class _UserManagementBody extends StatelessWidget {
  const _UserManagementBody({
    required this.viewModel,
    required this.currentUser,
    required this.onOpenUserDetails,
    required this.onCreateUser,
  });

  final UserManagementViewModel viewModel;
  final PosUser currentUser;
  final ValueChanged<PosUser> onOpenUserDetails;
  final VoidCallback? onCreateUser;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    final spacing = AdaptiveSpacing.of(context);

    return Padding(
      padding: spacing.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ResponsiveActionBar(
            alignment: WrapAlignment.start,
            actions: [
              FilledButton.icon(
                onPressed: onCreateUser,
                icon: const Icon(Icons.person_add_alt_1),
                label: Text(l10n.addUserButton),
              ),
            ],
          ),
          SizedBox(height: spacing.sm),
          Expanded(
            child: PointyDataList<PosUser>(
              items: viewModel.users,
              onLoadMore: viewModel.loadMoreUsers,
              hasMore: viewModel.hasMoreUsers,
              isLoadingInitial: viewModel.isLoading,
              isLoadingMore: viewModel.isLoadingMore,
              hasError: viewModel.hasError,
              errorBuilder: (context) => PointyErrorState(
                title: l10n.usersLoadError,
                icon: Icons.group_outlined,
              ),
              emptyBuilder: (context) => PointyEmptyState(
                icon: Icons.group_outlined,
                title: l10n.emptyUsers,
              ),
              padding: EdgeInsets.zero,
              framed: false,
              itemBuilder: (context, user) {
                final isCurrentUser = user.id == currentUser.id;
                return PointyDataRow(
                  leading: CircleAvatar(
                    child: Icon(
                      user.role.isManager
                          ? Icons.admin_panel_settings_outlined
                          : Icons.point_of_sale_outlined,
                    ),
                  ),
                  title: user.label,
                  subtitle: user.username,
                  badges: [
                    PointyStatusPill(
                      label: _roleLabel(l10n, user.role),
                      icon: user.role.isManager
                          ? Icons.admin_panel_settings_outlined
                          : Icons.point_of_sale_outlined,
                    ),
                    PointyStatusPill(
                      label: user.isActive
                          ? l10n.userStatusActive
                          : l10n.userStatusInactive,
                      icon: user.isActive
                          ? Icons.check_circle_outline
                          : Icons.pause_circle_outline,
                      color: user.isActive
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.error,
                    ),
                  ],
                  actions: [
                    _UserControls(
                      user: user,
                      enabled: !viewModel.isSaving && !isCurrentUser,
                      onRoleChanged: (role) =>
                          viewModel.updateUserRole(user, role),
                      onActiveChanged: (value) =>
                          viewModel.updateUserActive(user, value),
                      onOpenDetails: () => onOpenUserDetails(user),
                    ),
                  ],
                  onTap: () => onOpenUserDetails(user),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _roleLabel(AppLocalizations l10n, UserRole role) {
    return switch (role) {
      UserRole.manager => l10n.managerRoleLabel,
      UserRole.cashier => l10n.cashierRoleLabel,
      UserRole.accountant => l10n.accountantRoleLabel,
    };
  }
}

class _UserControls extends StatelessWidget {
  const _UserControls({
    required this.user,
    required this.enabled,
    required this.onRoleChanged,
    required this.onActiveChanged,
    required this.onOpenDetails,
  });

  final PosUser user;
  final bool enabled;
  final ValueChanged<UserRole> onRoleChanged;
  final ValueChanged<bool> onActiveChanged;
  final VoidCallback onOpenDetails;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        IconButton(
          tooltip: l10n.userDetailsTooltip,
          onPressed: onOpenDetails,
          icon: const Icon(Icons.manage_accounts_outlined),
        ),
        DropdownButton<UserRole>(
          value: user.role,
          onChanged: enabled
              ? (role) {
                  if (role != null) {
                    onRoleChanged(role);
                  }
                }
              : null,
          items: [
            DropdownMenuItem(
              value: UserRole.cashier,
              child: Text(l10n.cashierRoleLabel),
            ),
            DropdownMenuItem(
              value: UserRole.accountant,
              child: Text(l10n.accountantRoleLabel),
            ),
            DropdownMenuItem(
              value: UserRole.manager,
              child: Text(l10n.managerRoleLabel),
            ),
          ],
        ),
        Switch(
          value: user.isActive,
          onChanged: enabled ? onActiveChanged : null,
        ),
      ],
    );
  }
}

class _CreateUserForm extends StatefulWidget {
  const _CreateUserForm({required this.viewModel, required this.onCreated});

  final UserManagementViewModel viewModel;
  final VoidCallback onCreated;

  @override
  State<_CreateUserForm> createState() => _CreateUserFormState();
}

class _CreateUserFormState extends State<_CreateUserForm> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _emailController = TextEditingController();
  UserRole _role = UserRole.cashier;
  bool _isActive = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _displayNameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final spacing = AdaptiveSpacing.of(context);

        return AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              spacing.lg,
              0,
              spacing.lg,
              spacing.lg,
            ),
            child: Form(
              key: _formKey,
              child: ListView(
                shrinkWrap: true,
                children: [
                  PointySectionHeader(
                    title: l10n.userCreateTitle,
                    leading: const Icon(Icons.person_add_alt_1),
                  ),
                  ResponsiveFormGrid(
                    minChildWidth: 240,
                    maxColumns: 2,
                    children: [
                      TextFormField(
                        controller: _displayNameController,
                        enabled: !widget.viewModel.isSaving,
                        decoration: InputDecoration(
                          labelText: l10n.displayNameLabel,
                        ),
                      ),
                      TextFormField(
                        controller: _usernameController,
                        enabled: !widget.viewModel.isSaving,
                        decoration: InputDecoration(
                          labelText: l10n.usernameLabel,
                        ),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? l10n.requiredField
                            : null,
                      ),
                      TextFormField(
                        controller: _passwordController,
                        enabled: !widget.viewModel.isSaving,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: l10n.passwordLabel,
                        ),
                        validator: (value) => value == null || value.isEmpty
                            ? l10n.requiredField
                            : null,
                      ),
                      TextFormField(
                        controller: _emailController,
                        enabled: !widget.viewModel.isSaving,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(labelText: l10n.emailLabel),
                      ),
                      DropdownButtonFormField<UserRole>(
                        initialValue: _role,
                        decoration: InputDecoration(labelText: l10n.roleLabel),
                        items: [
                          DropdownMenuItem(
                            value: UserRole.cashier,
                            child: Text(l10n.cashierRoleLabel),
                          ),
                          DropdownMenuItem(
                            value: UserRole.accountant,
                            child: Text(l10n.accountantRoleLabel),
                          ),
                          DropdownMenuItem(
                            value: UserRole.manager,
                            child: Text(l10n.managerRoleLabel),
                          ),
                        ],
                        onChanged: widget.viewModel.isSaving
                            ? null
                            : (role) {
                                if (role != null) {
                                  setState(() => _role = role);
                                }
                              },
                      ),
                      SwitchListTile(
                        value: _isActive,
                        title: Text(l10n.activeUserLabel),
                        onChanged: widget.viewModel.isSaving
                            ? null
                            : (value) => setState(() => _isActive = value),
                      ),
                    ],
                  ),
                  if (widget.viewModel.hasSaveError) ...[
                    SizedBox(height: spacing.sm),
                    Text(
                      l10n.createUserError,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  SizedBox(height: spacing.md),
                  ResponsiveActionBar(
                    actions: [
                      TextButton(
                        onPressed: widget.viewModel.isSaving
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: Text(l10n.cancelButton),
                      ),
                      FilledButton.icon(
                        onPressed: widget.viewModel.isSaving ? null : _submit,
                        icon: widget.viewModel.isSaving
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.person_add_alt_1),
                        label: Text(l10n.createUserButton),
                      ),
                    ],
                  ),
                ],
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

    final created = await widget.viewModel.createUser(
      UserCreateDraft(
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        role: _role,
        displayName: _displayNameController.text.trim(),
        email: _emailController.text.trim(),
        isActive: _isActive,
      ),
    );

    if (created) {
      widget.onCreated();
    }
  }
}
