import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../core/authorization.dart';
import 'authorization_denied_view.dart';
import 'design/design.dart';

typedef AuthorizedWidgetBuilder = Widget Function(BuildContext context);

class AuthorizationGuard extends StatelessWidget {
  const AuthorizationGuard({
    super.key,
    required this.capabilities,
    required this.capability,
    required this.child,
    this.fallback = const SizedBox.shrink(),
  });

  final AuthorizationCapabilities capabilities;
  final AppCapability capability;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return capabilities.allows(capability) ? child : fallback;
  }
}

class AuthorizationBuilder extends StatelessWidget {
  const AuthorizationBuilder({
    super.key,
    required this.capabilities,
    required this.capability,
    required this.builder,
  });

  final AuthorizationCapabilities capabilities;
  final AppCapability capability;
  final Widget Function(BuildContext context, bool isAllowed) builder;

  @override
  Widget build(BuildContext context) {
    return builder(context, capabilities.allows(capability));
  }
}

class PosAccessGuard extends StatelessWidget {
  const PosAccessGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const AuthorizationDeniedView(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.accessPos,
      fallback: fallback,
      child: child,
    );
  }
}

class DashboardGuard extends StatelessWidget {
  const DashboardGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const AuthorizationDeniedView(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.viewDashboard,
      fallback: fallback,
      child: child,
    );
  }
}

class DashboardWidgetGuard extends StatelessWidget {
  const DashboardWidgetGuard({
    super.key,
    required this.capabilities,
    required this.capability,
    required this.child,
  });

  final AuthorizationCapabilities capabilities;
  final AppCapability capability;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: capability,
      child: child,
    );
  }
}

class ReportsGuard extends StatelessWidget {
  const ReportsGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const AuthorizationDeniedView(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.viewReports,
      fallback: fallback,
      child: child,
    );
  }
}

class ActivityLogGuard extends StatelessWidget {
  const ActivityLogGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const AuthorizationDeniedView(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.viewActivityLog,
      fallback: fallback,
      child: child,
    );
  }
}

class CheckoutGuard extends StatelessWidget {
  const CheckoutGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback,
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.checkoutSale,
      fallback: fallback ?? const _PaymentUnauthorizedMessage(),
      child: child,
    );
  }
}

class CheckoutCapabilityBuilder extends StatelessWidget {
  const CheckoutCapabilityBuilder({
    super.key,
    required this.capabilities,
    required this.builder,
  });

  final AuthorizationCapabilities capabilities;
  final Widget Function(BuildContext context, bool isAllowed) builder;

  @override
  Widget build(BuildContext context) {
    return AuthorizationBuilder(
      capabilities: capabilities,
      capability: AppCapability.checkoutSale,
      builder: builder,
    );
  }
}

class RegisterSessionStartGuard extends StatelessWidget {
  const RegisterSessionStartGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const AuthorizationDeniedView(compact: true),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.startRegisterSession,
      fallback: fallback,
      child: child,
    );
  }
}

class RegisterSessionResumeGuard extends StatelessWidget {
  const RegisterSessionResumeGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const AuthorizationDeniedView(compact: true),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.resumeRegisterSession,
      fallback: fallback,
      child: child,
    );
  }
}

class RegisterSessionCloseGuard extends StatelessWidget {
  const RegisterSessionCloseGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const SizedBox.shrink(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.closeRegisterSession,
      fallback: fallback,
      child: child,
    );
  }
}

class RegisterCashMovementCreateGuard extends StatelessWidget {
  const RegisterCashMovementCreateGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const SizedBox.shrink(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.createRegisterCashMovement,
      fallback: fallback,
      child: child,
    );
  }
}

class CatalogManagementGuard extends StatelessWidget {
  const CatalogManagementGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const AuthorizationDeniedView(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.viewCatalogManagement,
      fallback: fallback,
      child: child,
    );
  }
}

class ProductCreateGuard extends StatelessWidget {
  const ProductCreateGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const SizedBox.shrink(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.createProduct,
      fallback: fallback,
      child: child,
    );
  }
}

class ProductChangeGuard extends StatelessWidget {
  const ProductChangeGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const SizedBox.shrink(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.changeProduct,
      fallback: fallback,
      child: child,
    );
  }
}

class ProductVariantCreateGuard extends StatelessWidget {
  const ProductVariantCreateGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const SizedBox.shrink(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.createProductVariant,
      fallback: fallback,
      child: child,
    );
  }
}

class ProductVariantChangeGuard extends StatelessWidget {
  const ProductVariantChangeGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const SizedBox.shrink(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.changeProductVariant,
      fallback: fallback,
      child: child,
    );
  }
}

class StockViewGuard extends StatelessWidget {
  const StockViewGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const SizedBox.shrink(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.viewStock,
      fallback: fallback,
      child: child,
    );
  }
}

class StockMovementCreateGuard extends StatelessWidget {
  const StockMovementCreateGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const SizedBox.shrink(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.createStockMovement,
      fallback: fallback,
      child: child,
    );
  }
}

class RegisterSessionsGuard extends StatelessWidget {
  const RegisterSessionsGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const AuthorizationDeniedView(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.viewRegisterSessions,
      fallback: fallback,
      child: child,
    );
  }
}

class RegisterSessionOrdersGuard extends StatelessWidget {
  const RegisterSessionOrdersGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const AuthorizationDeniedView(compact: true),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.viewRegisterSessionOrders,
      fallback: fallback,
      child: child,
    );
  }
}

class RegisterSessionOrdersCapabilityBuilder extends StatelessWidget {
  const RegisterSessionOrdersCapabilityBuilder({
    super.key,
    required this.capabilities,
    required this.builder,
  });

  final AuthorizationCapabilities capabilities;
  final Widget Function(BuildContext context, bool isAllowed) builder;

  @override
  Widget build(BuildContext context) {
    return AuthorizationBuilder(
      capabilities: capabilities,
      capability: AppCapability.viewRegisterSessionOrders,
      builder: builder,
    );
  }
}

class UserManagementGuard extends StatelessWidget {
  const UserManagementGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const AuthorizationDeniedView(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.manageUsers,
      fallback: fallback,
      child: child,
    );
  }
}

class EmployeePayrollGuard extends StatelessWidget {
  const EmployeePayrollGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const AuthorizationDeniedView(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.viewEmployees,
      fallback: fallback,
      child: child,
    );
  }
}

class ShopSettingsGuard extends StatelessWidget {
  const ShopSettingsGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const AuthorizationDeniedView(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.manageShopSettings,
      fallback: fallback,
      child: child,
    );
  }
}

class DiscountRulesGuard extends StatelessWidget {
  const DiscountRulesGuard({
    super.key,
    required this.capabilities,
    required this.child,
    this.fallback = const AuthorizationDeniedView(),
  });

  final AuthorizationCapabilities capabilities;
  final Widget child;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return AuthorizationGuard(
      capabilities: capabilities,
      capability: AppCapability.viewDiscountRules,
      fallback: fallback,
      child: child,
    );
  }
}

class _PaymentUnauthorizedMessage extends StatelessWidget {
  const _PaymentUnauthorizedMessage();

  @override
  Widget build(BuildContext context) {
    return Text(
      AppLocalizations.of(context)!.paymentUnauthorizedMessage,
      textAlign: TextAlign.center,
      style: TextStyle(color: context.pointyColors.danger),
    );
  }
}
