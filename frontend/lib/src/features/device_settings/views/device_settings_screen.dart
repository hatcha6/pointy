import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/pos_user.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../printing/view_models/printing_settings_view_model.dart';
import '../../printing/views/printing_settings_panel.dart';

class DeviceSettingsScreen extends StatelessWidget {
  const DeviceSettingsScreen({
    super.key,
    required this.viewModel,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenCatalog,
    required this.onOpenCategories,
    required this.onOpenPurchasing,
    required this.onOpenContacts,
    required this.onOpenRegisterSessions,
    required this.onLogout,
    this.onOpenDashboard,
    this.onOpenDiscounts,
    this.onOpenReports,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final PrintingSettingsViewModel viewModel;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenCategories;
  final VoidCallback onOpenPurchasing;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback? onOpenDashboard;
  final VoidCallback? onOpenDiscounts;
  final VoidCallback? onOpenReports;
  final VoidCallback? onOpenUsers;
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
            selectedDestination: AppNavigationDestination.deviceSettings,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenDashboard: onOpenDashboard,
            onOpenPos: onOpenPos,
            onOpenPurchasing: onOpenPurchasing,
            onOpenContacts: onOpenContacts,
            onOpenCatalog: onOpenCatalog,
            onOpenCategories: onOpenCategories,
            onOpenRegisterSessions: onOpenRegisterSessions,
            onOpenUsers: onOpenUsers,
            onOpenShopSettings: onOpenShopSettings,
            onOpenDiscounts: onOpenDiscounts,
            onOpenReports: onOpenReports,
            onOpenDeviceSettings: () {},
            onLogout: onLogout,
          ),
          appBar: PointyAppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.deviceSettingsTitle),
            isLoading: viewModel.isLoadingConfig,
            reserveLoadingSlot: false,
            actions: [
              PosAccessGuard(
                capabilities: capabilities,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.refreshDeviceSettingsTooltip,
                  onPressed: viewModel.isLoadingConfig
                      ? null
                      : viewModel.loadDefaultConfig,
                  icon: const Icon(Icons.sync),
                ),
              ),
            ],
          ),
          body: PosAccessGuard(
            capabilities: capabilities,
            child: _DeviceSettingsBody(viewModel: viewModel),
          ),
        );
      },
    );
  }
}

class _DeviceSettingsBody extends StatelessWidget {
  const _DeviceSettingsBody({required this.viewModel});

  final PrintingSettingsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoadingConfig) {
      return const PointyLoadingArea();
    }

    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: PointyDetailSection(
            icon: Icons.print_outlined,
            title: l10n.devicePrinterSectionTitle,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (viewModel.hasConfigLoadError) ...[
                  PointyErrorState(
                    title: l10n.deviceSettingsLoadError,
                    icon: Icons.print_disabled_outlined,
                  ),
                  SizedBox(height: spacing.md),
                ],
                PrintingSettingsPanel(viewModel: viewModel),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
