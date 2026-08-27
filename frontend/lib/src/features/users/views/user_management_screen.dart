import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/pos_user.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/query_controls/debounced_search_field.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../role_presentation.dart';
import '../view_models/user_management_view_model.dart';

/// Opens the per-user permission editor for [user]; resolves to true if the
/// editor saved changes (so the list can refresh the affected row).
typedef UserPermissionsOpener = Future<bool> Function(PosUser user);

class UserManagementScreen extends StatelessWidget {
  const UserManagementScreen({
    super.key,
    required this.viewModel,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenUserDetails,
    required this.onOpenUserPermissions,
    required this.navigation,
  });

  final UserManagementViewModel viewModel;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final ValueChanged<PosUser> onOpenUserDetails;
  final UserPermissionsOpener onOpenUserPermissions;
  final AppNavigation navigation;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.users,
            navigation: navigation,
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
              onEditUser: (user) => _showEditUserSheet(context, user),
              onManagePermissions: (user) async {
                final changed = await onOpenUserPermissions(user);
                if (changed) {
                  await viewModel.loadUsers();
                }
              },
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

  Future<void> _showEditUserSheet(BuildContext context, PosUser user) {
    return showAdaptiveFormSurface<void>(
      context: context,
      size: AdaptiveModalSize.standard,
      maxHeightFactor: 0.94,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: _EditUserForm(
            viewModel: viewModel,
            user: user,
            isCurrentUser: user.id == currentUser.id,
            onSaved: () => Navigator.of(sheetContext).pop(),
            onManagePermissions: () {
              Navigator.of(sheetContext).pop();
              onOpenUserPermissions(user).then((changed) {
                if (changed) {
                  viewModel.loadUsers();
                }
              });
            },
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
    required this.onEditUser,
    required this.onManagePermissions,
    required this.onCreateUser,
  });

  final UserManagementViewModel viewModel;
  final PosUser currentUser;
  final ValueChanged<PosUser> onOpenUserDetails;
  final ValueChanged<PosUser> onEditUser;
  final ValueChanged<PosUser> onManagePermissions;
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
          _UserStatsHeader(viewModel: viewModel),
          SizedBox(height: spacing.sm),
          DebouncedSearchField(
            value: viewModel.searchQuery,
            hintText: l10n.usersSearchHint,
            clearTooltip: l10n.clearButton,
            fieldKey: const ValueKey('users_search_field'),
            onChanged: viewModel.setSearchQuery,
          ),
          SizedBox(height: spacing.sm),
          _RoleFilterChips(viewModel: viewModel),
          SizedBox(height: spacing.sm),
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
                title: viewModel.isFiltered
                    ? l10n.usersNoMatches
                    : l10n.emptyUsers,
                action: viewModel.isFiltered || onCreateUser == null
                    ? null
                    : FilledButton.icon(
                        onPressed: onCreateUser,
                        icon: const Icon(Icons.person_add_alt_1),
                        label: Text(l10n.addUserButton),
                      ),
              ),
              padding: EdgeInsets.zero,
              framed: false,
              itemBuilder: (context, user) {
                final isCurrentUser = user.id == currentUser.id;
                return PointyDataRow(
                  leading: RoleAvatar(role: user.role),
                  title: user.label,
                  subtitle: _subtitle(user),
                  badges: _badges(context, l10n, user),
                  actions: [
                    _UserRowMenu(
                      user: user,
                      isCurrentUser: isCurrentUser,
                      enabled: !viewModel.isSaving,
                      onOpenDetails: () => onOpenUserDetails(user),
                      onEdit: () => onEditUser(user),
                      onManagePermissions: () => onManagePermissions(user),
                      onToggleActive: () =>
                          viewModel.updateUserActive(user, !user.isActive),
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

  String _subtitle(PosUser user) {
    final parts = <String>['@${user.username}'];
    if (user.email.trim().isNotEmpty) {
      parts.add(user.email.trim());
    }
    return parts.join(' • ');
  }

  List<Widget> _badges(
    BuildContext context,
    AppLocalizations l10n,
    PosUser user,
  ) {
    final presentation = rolePresentationFor(context, user.role);
    return [
      PointyStatusPill(
        label: presentation.label,
        icon: presentation.icon,
        color: presentation.color,
      ),
      PointyStatusPill(
        label: user.isActive ? l10n.userStatusActive : l10n.userStatusInactive,
        icon: user.isActive
            ? Icons.check_circle_outline
            : Icons.pause_circle_outline,
        color: user.isActive
            ? context.pointyColors.primaryStrong
            : context.pointyColors.danger,
      ),
      if (user.hasExtraPermissions)
        PointyStatusPill(
          label: l10n.usersCustomPermissionsBadge(user.extraPermissionCount),
          icon: Icons.tune,
          color: context.pointyColors.accentAmber,
        ),
    ];
  }
}

class _UserStatsHeader extends StatelessWidget {
  const _UserStatsHeader({required this.viewModel});

  final UserManagementViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return PointyMetricGrid(
      gap: PointyMetricGridGap.compact,
      minTileWidth: 150,
      metrics: [
        PointyMetricGridItem(
          icon: Icons.group_outlined,
          label: l10n.usersTotalMetric,
          value: '${viewModel.totalCount}',
          accentColor: colors.primaryStrong,
        ),
        PointyMetricGridItem(
          icon: Icons.check_circle_outline,
          label: l10n.usersActiveMetric,
          value: '${viewModel.activeCount}',
          accentColor: colors.success,
        ),
        PointyMetricGridItem(
          icon: Icons.tune,
          label: l10n.usersCustomPermissionsMetric,
          value: '${viewModel.customPermissionUserCount}',
          accentColor: colors.accentAmber,
        ),
      ],
    );
  }
}

class _RoleFilterChips extends StatelessWidget {
  const _RoleFilterChips({required this.viewModel});

  final UserManagementViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: ChoiceChip(
              label: Text(l10n.roleFilterAllLabel),
              selected: viewModel.roleFilter == null,
              onSelected: (_) => viewModel.setRoleFilter(null),
            ),
          ),
          for (final role in UserRole.assignable)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: ChoiceChip(
                avatar: Icon(
                  rolePresentationFor(context, role).icon,
                  size: 18,
                  color: rolePresentationFor(context, role).color,
                ),
                label: Text(roleLabelFor(context, role)),
                selected: viewModel.roleFilter == role,
                onSelected: (_) => viewModel.setRoleFilter(role),
              ),
            ),
        ],
      ),
    );
  }
}

class _UserRowMenu extends StatelessWidget {
  const _UserRowMenu({
    required this.user,
    required this.isCurrentUser,
    required this.enabled,
    required this.onOpenDetails,
    required this.onEdit,
    required this.onManagePermissions,
    required this.onToggleActive,
  });

  final PosUser user;
  final bool isCurrentUser;
  final bool enabled;
  final VoidCallback onOpenDetails;
  final VoidCallback onEdit;
  final VoidCallback onManagePermissions;
  final VoidCallback onToggleActive;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<String>(
      enabled: enabled,
      tooltip: l10n.userActionsTooltip,
      icon: const Icon(Icons.more_vert),
      onSelected: (value) {
        switch (value) {
          case 'details':
            onOpenDetails();
          case 'edit':
            onEdit();
          case 'permissions':
            onManagePermissions();
          case 'toggle':
            onToggleActive();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'details',
          child: _MenuRow(
            icon: Icons.manage_accounts_outlined,
            label: l10n.userDetailsTooltip,
          ),
        ),
        PopupMenuItem(
          value: 'edit',
          child: _MenuRow(icon: Icons.edit_outlined, label: l10n.userEditAction),
        ),
        PopupMenuItem(
          value: 'permissions',
          child: _MenuRow(
            icon: Icons.tune,
            label: l10n.userManagePermissionsAction,
          ),
        ),
        // You cannot deactivate your own account (avoids locking yourself out).
        if (!isCurrentUser)
          PopupMenuItem(
            value: 'toggle',
            child: _MenuRow(
              icon: user.isActive
                  ? Icons.pause_circle_outline
                  : Icons.play_circle_outline,
              label: user.isActive
                  ? l10n.userDeactivateAction
                  : l10n.userActivateAction,
            ),
          ),
      ],
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: context.pointyColors.mutedInk),
        const SizedBox(width: 12),
        Text(label),
      ],
    );
  }
}

/// Selectable role picker (chips + live description) reused by create and edit.
class _RolePicker extends StatelessWidget {
  const _RolePicker({
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final UserRole value;
  final ValueChanged<UserRole> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final selected = rolePresentationFor(context, value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.roleLabel, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final role in UserRole.assignable)
              ChoiceChip(
                avatar: Icon(
                  rolePresentationFor(context, role).icon,
                  size: 18,
                  color: rolePresentationFor(context, role).color,
                ),
                label: Text(roleLabelFor(context, role)),
                selected: role == value,
                onSelected: enabled ? (_) => onChanged(role) : null,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          selected.description,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
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
                        decoration: InputDecoration(labelText: l10n.usernameLabel),
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? l10n.requiredField
                            : null,
                      ),
                      TextFormField(
                        controller: _passwordController,
                        enabled: !widget.viewModel.isSaving,
                        obscureText: true,
                        decoration: InputDecoration(labelText: l10n.passwordLabel),
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
                    ],
                  ),
                  SizedBox(height: spacing.md),
                  _RolePicker(
                    value: _role,
                    enabled: !widget.viewModel.isSaving,
                    onChanged: (role) => setState(() => _role = role),
                  ),
                  SizedBox(height: spacing.sm),
                  SwitchListTile(
                    value: _isActive,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.activeUserLabel),
                    onChanged: widget.viewModel.isSaving
                        ? null
                        : (value) => setState(() => _isActive = value),
                  ),
                  if (widget.viewModel.hasSaveError) ...[
                    SizedBox(height: spacing.sm),
                    Text(
                      l10n.createUserError,
                      style: TextStyle(color: context.pointyColors.danger),
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
                                child: PointySpinner(strokeWidth: 2),
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

class _EditUserForm extends StatefulWidget {
  const _EditUserForm({
    required this.viewModel,
    required this.user,
    required this.isCurrentUser,
    required this.onSaved,
    required this.onManagePermissions,
  });

  final UserManagementViewModel viewModel;
  final PosUser user;
  final bool isCurrentUser;
  final VoidCallback onSaved;
  final VoidCallback onManagePermissions;

  @override
  State<_EditUserForm> createState() => _EditUserFormState();
}

class _EditUserFormState extends State<_EditUserForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _displayNameController;
  late final TextEditingController _emailController;
  final _passwordController = TextEditingController();
  late UserRole _role;
  late bool _isActive;

  @override
  void initState() {
    super.initState();
    _displayNameController = TextEditingController(text: widget.user.displayName);
    _emailController = TextEditingController(text: widget.user.email);
    _role = widget.user.role;
    _isActive = widget.user.isActive;
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _emailController.dispose();
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
        final lockSelfControls = widget.isCurrentUser;

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
                    title: l10n.userEditTitle,
                    subtitle: '@${widget.user.username}',
                    leading: const Icon(Icons.manage_accounts_outlined),
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
                        controller: _emailController,
                        enabled: !widget.viewModel.isSaving,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(labelText: l10n.emailLabel),
                      ),
                      TextFormField(
                        controller: _passwordController,
                        enabled: !widget.viewModel.isSaving,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: l10n.passwordResetLabel,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: spacing.md),
                  _RolePicker(
                    value: _role,
                    enabled: !widget.viewModel.isSaving && !lockSelfControls,
                    onChanged: (role) => setState(() => _role = role),
                  ),
                  if (lockSelfControls) ...[
                    SizedBox(height: spacing.xs),
                    Text(
                      l10n.userEditSelfRoleLocked,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.pointyColors.mutedInk,
                      ),
                    ),
                  ],
                  SizedBox(height: spacing.sm),
                  SwitchListTile(
                    value: _isActive,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.activeUserLabel),
                    onChanged: widget.viewModel.isSaving || lockSelfControls
                        ? null
                        : (value) => setState(() => _isActive = value),
                  ),
                  SizedBox(height: spacing.sm),
                  PointySettingsSection(
                    children: [
                      PointySettingsTile(
                        icon: Icons.tune,
                        title: l10n.userManagePermissionsLinkTitle,
                        subtitle: widget.user.hasExtraPermissions
                            ? l10n.usersCustomPermissionsBadge(
                                widget.user.extraPermissionCount,
                              )
                            : l10n.userManagePermissionsLinkSubtitle,
                        onTap: widget.onManagePermissions,
                      ),
                    ],
                  ),
                  if (widget.viewModel.hasSaveError) ...[
                    SizedBox(height: spacing.sm),
                    Text(
                      l10n.updateUserError,
                      style: TextStyle(color: context.pointyColors.danger),
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
                                child: PointySpinner(strokeWidth: 2),
                              )
                            : const Icon(Icons.check),
                        label: Text(l10n.saveButton),
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

    final draft = UserUpdateDraft(
      displayName: _displayNameController.text.trim(),
      email: _emailController.text.trim(),
      password: _passwordController.text,
      role: widget.isCurrentUser ? null : _role,
      isActive: widget.isCurrentUser ? null : _isActive,
    );

    final saved = await widget.viewModel.saveUserEdits(widget.user, draft);
    if (saved) {
      widget.onSaved();
    }
  }
}
