import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/authorization.dart';
import '../../../data/models/device_settings.dart';
import '../../../data/repositories/prep_station_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/device_settings_view_model.dart';
import '../../printing/view_models/printing_settings_view_model.dart';
import '../../printing/views/printing_settings_panel.dart';

class DeviceSettingsScreen extends StatelessWidget {
  const DeviceSettingsScreen({
    super.key,
    required this.deviceSettingsViewModel,
    required this.printingSettingsViewModel,
    required this.printingRepository,
    required this.prepStationRepository,
    required this.analyticsEngine,
    required this.capabilities,
    required this.navigation,
  });

  final DeviceSettingsViewModel deviceSettingsViewModel;
  final PrintingSettingsViewModel printingSettingsViewModel;
  final PrintingRepository printingRepository;
  final PrepStationRepository prepStationRepository;
  final AnalyticsEngine? analyticsEngine;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: deviceSettingsViewModel,
      builder: (context, _) {
        return ListenableBuilder(
          listenable: printingSettingsViewModel,
          builder: (context, _) {
            final isLoading =
                deviceSettingsViewModel.isLoading ||
                printingSettingsViewModel.isLoadingConfig;

            return PointyScaffold(
              drawer: AppNavigationDrawer(
                selectedDestination: AppNavigationDestination.deviceSettings,
                navigation: navigation,
              ),
              appBar: PointyAppBar(
                leading: const PointyNavigationMenuButton(),
                title: Text(l10n.deviceSettingsTitle),
                isLoading: isLoading,
                reserveLoadingSlot: false,
                actions: [
                  PosAccessGuard(
                    capabilities: capabilities,
                    fallback: const SizedBox.shrink(),
                    child: IconButton(
                      tooltip: l10n.refreshDeviceSettingsTooltip,
                      onPressed: isLoading
                          ? null
                          : () {
                              deviceSettingsViewModel.loadSettings();
                              printingSettingsViewModel.loadDefaultConfig();
                            },
                      icon: const Icon(Icons.sync),
                    ),
                  ),
                ],
              ),
              body: PosAccessGuard(
                capabilities: capabilities,
                child: _DeviceSettingsBody(
                  deviceSettingsViewModel: deviceSettingsViewModel,
                  printingSettingsViewModel: printingSettingsViewModel,
                  printingRepository: printingRepository,
                  prepStationRepository: prepStationRepository,
                  analyticsEngine: analyticsEngine,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _DeviceSettingsBody extends StatelessWidget {
  const _DeviceSettingsBody({
    required this.deviceSettingsViewModel,
    required this.printingSettingsViewModel,
    required this.printingRepository,
    required this.prepStationRepository,
    required this.analyticsEngine,
  });

  final DeviceSettingsViewModel deviceSettingsViewModel;
  final PrintingSettingsViewModel printingSettingsViewModel;
  final PrintingRepository printingRepository;
  final PrepStationRepository prepStationRepository;
  final AnalyticsEngine? analyticsEngine;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (deviceSettingsViewModel.isLoading ||
        printingSettingsViewModel.isLoadingConfig) {
      return const PointyLoadingArea();
    }

    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: PointyDetailSection(
            icon: Icons.manage_accounts_outlined,
            title: l10n.deviceUsageSectionTitle,
            child: _DeviceUsageModePanel(viewModel: deviceSettingsViewModel),
          ),
        ),
        SizedBox(height: spacing.lg),
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: PointyDetailSection(
            icon: Icons.print_outlined,
            title: l10n.devicePrinterSectionTitle,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (printingSettingsViewModel.hasConfigLoadError) ...[
                  PointyErrorState(
                    title: l10n.deviceSettingsLoadError,
                    icon: Icons.print_disabled_outlined,
                  ),
                  SizedBox(height: spacing.md),
                ],
                PrintingSettingsPanel(viewModel: printingSettingsViewModel),
              ],
            ),
          ),
        ),
        SizedBox(height: spacing.lg),
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: PointyDetailSection(
            icon: Icons.dinner_dining_outlined,
            title: l10n.kitchenPrintersSectionTitle,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.only(bottom: spacing.sm),
                  child: Text(
                    l10n.kitchenPrintersSectionHint,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                KitchenPrintersPanel(
                  printingRepository: printingRepository,
                  prepStationRepository: prepStationRepository,
                  analyticsEngine: analyticsEngine,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DeviceUsageModePanel extends StatelessWidget {
  const _DeviceUsageModePanel({required this.viewModel});

  final DeviceSettingsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (viewModel.hasLoadError) ...[
          PointyInlineMessage.error(message: l10n.deviceSettingsLoadError),
          SizedBox(height: spacing.md),
        ],
        _UsageModeOption(
          value: DeviceUsageMode.singleUser,
          selectedValue: viewModel.usageMode,
          title: l10n.deviceUsageSingleUserTitle,
          description: l10n.deviceUsageSingleUserDescription,
          icon: Icons.person_outline,
          enabled: !viewModel.isSaving,
          onChanged: viewModel.updateUsageMode,
        ),
        SizedBox(height: spacing.sm),
        _UsageModeOption(
          value: DeviceUsageMode.multiUser,
          selectedValue: viewModel.usageMode,
          title: l10n.deviceUsageMultiUserTitle,
          description: l10n.deviceUsageMultiUserDescription,
          icon: Icons.groups_outlined,
          enabled: !viewModel.isSaving,
          onChanged: viewModel.updateUsageMode,
        ),
        if (viewModel.hasSaveError) ...[
          SizedBox(height: spacing.md),
          PointyInlineMessage.error(message: l10n.deviceSettingsSaveError),
        ],
      ],
    );
  }
}

class _UsageModeOption extends StatelessWidget {
  const _UsageModeOption({
    required this.value,
    required this.selectedValue,
    required this.title,
    required this.description,
    required this.icon,
    required this.enabled,
    required this.onChanged,
  });

  final DeviceUsageMode value;
  final DeviceUsageMode selectedValue;
  final String title;
  final String description;
  final IconData icon;
  final bool enabled;
  final ValueChanged<DeviceUsageMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = value == selectedValue;
    final colors = context.pointyColors;

    return Material(
      color: selected
          ? PointyColors.primaryContainer.withValues(alpha: 0.35)
          : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: selected ? colors.primaryStrong : colors.line),
      ),
      child: ListTile(
        enabled: enabled,
        onTap: enabled ? () => onChanged(value) : null,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(description),
        trailing: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? colors.primaryStrong : colors.line,
        ),
      ),
    );
  }
}
