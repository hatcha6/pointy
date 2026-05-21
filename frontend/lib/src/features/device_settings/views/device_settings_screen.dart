import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/pos_user.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
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
        return Scaffold(
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
            title: Text(l10n.deviceSettingsTitle),
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
          body: SafeArea(
            child: PosAccessGuard(
              capabilities: capabilities,
              child: _DeviceSettingsBody(viewModel: viewModel),
            ),
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
    final colorScheme = Theme.of(context).colorScheme;

    if (viewModel.isLoadingConfig) {
      return const Center(child: CircularProgressIndicator());
    }

    return ColoredBox(
      color: colorScheme.surfaceContainerLowest,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Material(
                color: colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.print_outlined,
                            color: colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l10n.devicePrinterSectionTitle,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                        ],
                      ),
                      if (viewModel.hasConfigLoadError)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            l10n.deviceSettingsLoadError,
                            style: TextStyle(color: colorScheme.error),
                          ),
                        ),
                      const SizedBox(height: 16),
                      PrintingSettingsPanel(viewModel: viewModel),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
