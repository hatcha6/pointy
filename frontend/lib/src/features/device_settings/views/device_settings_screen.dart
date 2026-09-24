import 'dart:async';
import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/device_settings.dart';
import '../../../data/repositories/price_checker_repository.dart';
import '../../../data/services/auto_start_service.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/price_checker/price_checker_mode_controller.dart';
import '../../../shared/product_search/product_search_mode_controller.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../../shared/theme/theme_mode_controls.dart';
import '../view_models/device_settings_view_model.dart';
import 'camera_wedge_settings_panel.dart';
import '../../price_checker/views/price_checker_settings_panel.dart';
import '../../printing/view_models/printing_settings_view_model.dart';
import '../../printing/views/printers_panel.dart';

class DeviceSettingsScreen extends StatelessWidget {
  const DeviceSettingsScreen({
    super.key,
    required this.deviceSettingsViewModel,
    required this.printingSettingsViewModel,
    required this.priceCheckerController,
    required this.priceCheckerRepository,
    required this.capabilities,
    required this.navigation,
    this.onCameraWedgeChanged,
  });

  /// Start or stop the counter camera the moment the switch is flipped.
  final Future<void> Function()? onCameraWedgeChanged;

  final DeviceSettingsViewModel deviceSettingsViewModel;
  final PrintingSettingsViewModel printingSettingsViewModel;
  final PriceCheckerModeController priceCheckerController;
  final PriceCheckerRepository priceCheckerRepository;
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
                printingSettingsViewModel.isLoading;

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
                              printingSettingsViewModel.load();
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
                  capabilities: capabilities,
                  priceCheckerController: priceCheckerController,
                  priceCheckerRepository: priceCheckerRepository,
                  onCameraWedgeChanged: onCameraWedgeChanged,
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
    required this.priceCheckerController,
    required this.priceCheckerRepository,
    required this.capabilities,
    this.onCameraWedgeChanged,
  });

  /// Lets the app start or stop the camera the moment the switch is flipped,
  /// so a shop that turns it on does not have to restart the till.
  final Future<void> Function()? onCameraWedgeChanged;

  final DeviceSettingsViewModel deviceSettingsViewModel;
  final PrintingSettingsViewModel printingSettingsViewModel;
  final AuthorizationCapabilities capabilities;
  final PriceCheckerModeController priceCheckerController;
  final PriceCheckerRepository priceCheckerRepository;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (deviceSettingsViewModel.isLoading ||
        printingSettingsViewModel.isLoading) {
      return const PointyLoadingArea();
    }
    final productSearchModes = ProductSearchModeScope.maybeOf(context);

    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: PointyDetailSection(
            icon: Icons.palette_outlined,
            title: l10n.appearanceSectionTitle,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.only(bottom: spacing.sm),
                  child: Text(
                    l10n.appearanceSectionSubtitle,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: ThemeModeSelector(),
                ),
              ],
            ),
          ),
        ),
        if (productSearchModes != null) ...[
          SizedBox(height: spacing.lg),
          AdaptiveMaxWidth(
            width: AppContentWidth.form,
            child: PointyDetailSection(
              icon: Icons.manage_search,
              title: l10n.productSearchSectionTitle,
              child: _ProductSearchModePanel(controller: productSearchModes),
            ),
          ),
        ],
        SizedBox(height: spacing.lg),
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
            icon: Icons.price_check_outlined,
            title: l10n.priceCheckerSettingsTitle,
            child: PriceCheckerSettingsPanel(
              controller: priceCheckerController,
              repository: priceCheckerRepository,
            ),
          ),
        ),
        if (const AutoStartService().isSupportedPlatform) ...[
          SizedBox(height: spacing.lg),
          AdaptiveMaxWidth(
            width: AppContentWidth.form,
            child: PointyDetailSection(
              icon: Icons.restart_alt_outlined,
              title: l10n.startupSectionTitle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.only(bottom: spacing.xs),
                    child: Text(
                      l10n.startupSectionSubtitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const RunOnStartupPanel(),
                ],
              ),
            ),
          ),
        ],
        SizedBox(height: spacing.lg),
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: PointyDetailSection(
            icon: Icons.print_outlined,
            title: l10n.devicePrinterSectionTitle,
            child: PrintersPanel(
              viewModel: printingSettingsViewModel,
              capabilities: capabilities,
            ),
          ),
        ),
        SizedBox(height: spacing.lg),
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: PointyDetailSection(
            icon: Icons.photo_camera_outlined,
            title: l10n.cameraWedgeSectionTitle,
            child: CameraWedgeSettingsPanel(
              viewModel: deviceSettingsViewModel,
              onChanged: onCameraWedgeChanged,
            ),
          ),
        ),
      ],
    );
  }
}

/// Whether this machine's product searches can be narrowed to codes or to
/// names. One switch: the picker it adds explains itself where it appears.
class _ProductSearchModePanel extends StatelessWidget {
  const _ProductSearchModePanel({required this.controller});

  final ProductSearchModeController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return SwitchListTile.adaptive(
      key: const ValueKey('product_search_mode_picker_toggle'),
      contentPadding: EdgeInsets.zero,
      value: controller.pickerEnabled,
      onChanged: (value) async {
        final messenger = ScaffoldMessenger.of(context);
        if (await controller.setPickerEnabled(value)) {
          return;
        }
        messenger
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(l10n.deviceSettingsSaveError)));
      },
      title: Text(l10n.productSearchModePickerToggleTitle),
      subtitle: Padding(
        padding: EdgeInsetsDirectional.only(top: spacing.xs),
        child: Text(l10n.productSearchModePickerToggleDescription),
      ),
      secondary: const Icon(Icons.manage_search),
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
          ? colors.primaryContainer.withValues(alpha: 0.35)
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
