import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/pos_user.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../view_models/user_management_view_model.dart';

class UserManagementScreen extends StatelessWidget {
  const UserManagementScreen({
    super.key,
    required this.viewModel,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenCatalog,
    required this.onOpenRegisterSessions,
    required this.onLogout,
    this.onOpenShopSettings,
  });

  final UserManagementViewModel viewModel;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback? onOpenShopSettings;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return Scaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.users,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenPos: onOpenPos,
            onOpenCatalog: onOpenCatalog,
            onOpenRegisterSessions: onOpenRegisterSessions,
            onOpenUsers: () {},
            onOpenShopSettings: onOpenShopSettings,
            onLogout: onLogout,
          ),
          appBar: AppBar(
            leading: Builder(
              builder: (context) {
                return IconButton(
                  tooltip: l10n.navigationMenuTooltip,
                  icon: const Icon(Icons.menu),
                  onPressed: Scaffold.of(context).openDrawer,
                );
              },
            ),
            title: Text(l10n.usersManagementTitle),
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
          body: SafeArea(
            child: UserManagementGuard(
              capabilities: capabilities,
              child: _UserManagementBody(
                viewModel: viewModel,
                currentUser: currentUser,
              ),
            ),
          ),
          floatingActionButton: UserManagementGuard(
            capabilities: capabilities,
            fallback: const SizedBox.shrink(),
            child: FloatingActionButton.extended(
              onPressed: viewModel.isSaving
                  ? null
                  : () => _showCreateUserSheet(context),
              icon: const Icon(Icons.person_add_alt_1),
              label: Text(l10n.addUserButton),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showCreateUserSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
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
  });

  final UserManagementViewModel viewModel;
  final PosUser currentUser;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (viewModel.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (viewModel.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l10n.usersLoadError, textAlign: TextAlign.center),
        ),
      );
    }

    if (viewModel.users.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l10n.emptyUsers, textAlign: TextAlign.center),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      itemCount: viewModel.users.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final user = viewModel.users[index];
        final isCurrentUser = user.id == currentUser.id;
        final controls = _UserControls(
          user: user,
          enabled: !viewModel.isSaving && !isCurrentUser,
          onRoleChanged: (role) => viewModel.updateUserRole(user, role),
          onActiveChanged: (value) => viewModel.updateUserActive(user, value),
        );

        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final details = Row(
                  children: [
                    CircleAvatar(
                      child: Icon(
                        user.role.isManager
                            ? Icons.admin_panel_settings_outlined
                            : Icons.point_of_sale_outlined,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user.label,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(user.username),
                          Text(_roleLabel(l10n, user.role)),
                          Text(
                            user.isActive
                                ? l10n.userStatusActive
                                : l10n.userStatusInactive,
                          ),
                        ],
                      ),
                    ),
                  ],
                );

                if (constraints.maxWidth >= 620) {
                  return Row(
                    children: [
                      Expanded(child: details),
                      const SizedBox(width: 12),
                      controls,
                    ],
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    details,
                    const SizedBox(height: 8),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: controls,
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  String _roleLabel(AppLocalizations l10n, UserRole role) {
    return switch (role) {
      UserRole.manager => l10n.managerRoleLabel,
      UserRole.cashier => l10n.cashierRoleLabel,
    };
  }
}

class _UserControls extends StatelessWidget {
  const _UserControls({
    required this.user,
    required this.enabled,
    required this.onRoleChanged,
    required this.onActiveChanged,
  });

  final PosUser user;
  final bool enabled;
  final ValueChanged<UserRole> onRoleChanged;
  final ValueChanged<bool> onActiveChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
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
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Form(
                key: _formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l10n.userCreateTitle,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _displayNameController,
                        enabled: !widget.viewModel.isSaving,
                        decoration: InputDecoration(
                          labelText: l10n.displayNameLabel,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _usernameController,
                        enabled: !widget.viewModel.isSaving,
                        decoration: InputDecoration(
                          labelText: l10n.usernameLabel,
                          border: const OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? l10n.requiredField
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _passwordController,
                        enabled: !widget.viewModel.isSaving,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: l10n.passwordLabel,
                          border: const OutlineInputBorder(),
                        ),
                        validator: (value) => value == null || value.isEmpty
                            ? l10n.requiredField
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _emailController,
                        enabled: !widget.viewModel.isSaving,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                          labelText: l10n.emailLabel,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<UserRole>(
                        initialValue: _role,
                        decoration: InputDecoration(
                          labelText: l10n.roleLabel,
                          border: const OutlineInputBorder(),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: UserRole.cashier,
                            child: Text(l10n.cashierRoleLabel),
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
                      if (widget.viewModel.hasSaveError)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            l10n.createUserError,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: widget.viewModel.isSaving
                                ? null
                                : () => Navigator.of(context).pop(),
                            child: Text(l10n.cancelButton),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            onPressed: widget.viewModel.isSaving
                                ? null
                                : _submit,
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
