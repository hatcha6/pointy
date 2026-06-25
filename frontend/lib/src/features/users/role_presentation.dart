import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/pos_user.dart';
import '../../shared/design/design.dart';

/// Visual identity for a [UserRole] — icon, accent colour, label and a
/// one-line description. The single source of truth so the list, details,
/// pickers and drawer all present roles identically. Adding a role means adding
/// one case here (and the matching l10n keys).
class RolePresentation {
  const RolePresentation({
    required this.role,
    required this.label,
    required this.description,
    required this.icon,
    required this.color,
  });

  final UserRole role;
  final String label;
  final String description;
  final IconData icon;
  final Color color;
}

RolePresentation rolePresentationFor(BuildContext context, UserRole role) {
  final l10n = AppLocalizations.of(context)!;
  final colors = context.pointyColors;
  return switch (role) {
    UserRole.manager => RolePresentation(
      role: role,
      label: l10n.managerRoleLabel,
      description: l10n.managerRoleDescription,
      icon: Icons.admin_panel_settings_outlined,
      color: colors.primaryStrong,
    ),
    UserRole.supervisor => RolePresentation(
      role: role,
      label: l10n.supervisorRoleLabel,
      description: l10n.supervisorRoleDescription,
      icon: Icons.supervisor_account_outlined,
      color: colors.accentAmber,
    ),
    UserRole.accountant => RolePresentation(
      role: role,
      label: l10n.accountantRoleLabel,
      description: l10n.accountantRoleDescription,
      icon: Icons.calculate_outlined,
      color: colors.success,
    ),
    UserRole.auditor => RolePresentation(
      role: role,
      label: l10n.auditorRoleLabel,
      description: l10n.auditorRoleDescription,
      icon: Icons.fact_check_outlined,
      color: colors.mutedInk,
    ),
    UserRole.purchasingAgent => RolePresentation(
      role: role,
      label: l10n.purchasingAgentRoleLabel,
      description: l10n.purchasingAgentRoleDescription,
      icon: Icons.local_shipping_outlined,
      color: colors.warning,
    ),
    UserRole.inventoryClerk => RolePresentation(
      role: role,
      label: l10n.inventoryClerkRoleLabel,
      description: l10n.inventoryClerkRoleDescription,
      icon: Icons.inventory_2_outlined,
      color: colors.primaryDark,
    ),
    UserRole.technician => RolePresentation(
      role: role,
      label: l10n.technicianRoleLabel,
      description: l10n.technicianRoleDescription,
      icon: Icons.handyman_outlined,
      color: colors.primary,
    ),
    UserRole.cashier => RolePresentation(
      role: role,
      label: l10n.cashierRoleLabel,
      description: l10n.cashierRoleDescription,
      icon: Icons.point_of_sale_outlined,
      color: colors.ink,
    ),
  };
}

/// Convenience for the common case where only the label is needed.
String roleLabelFor(BuildContext context, UserRole role) =>
    rolePresentationFor(context, role).label;

/// A circular role badge (tinted icon on a soft fill) reused by the list rows,
/// details hero and role picker.
class RoleAvatar extends StatelessWidget {
  const RoleAvatar({super.key, required this.role, this.radius = 22});

  final UserRole role;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final presentation = rolePresentationFor(context, role);
    return CircleAvatar(
      radius: radius,
      backgroundColor: presentation.color.withValues(alpha: 0.14),
      child: Icon(
        presentation.icon,
        color: presentation.color,
        size: radius * 1.05,
      ),
    );
  }
}
