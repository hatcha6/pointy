import 'dart:async';
import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/authorization.dart';
import '../../../data/models/device_settings.dart';
import '../../../data/repositories/prep_station_repository.dart';
import '../../../data/repositories/price_checker_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/services/auto_start_service.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/barcode/camera_wedge/camera_wedge_scope.dart';
import '../../../shared/barcode/camera_wedge/camera_wedge_source.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/price_checker/price_checker_mode_controller.dart';
import '../../../shared/product_search/product_search_mode_controller.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../../shared/theme/theme_mode_controls.dart';
import '../view_models/device_settings_view_model.dart';
import '../../price_checker/views/price_checker_settings_panel.dart';
import '../../printing/view_models/printing_settings_view_model.dart';
import '../../printing/views/printing_settings_panel.dart';

class DeviceSettingsScreen extends StatelessWidget {
  const DeviceSettingsScreen({
    super.key,
    required this.deviceSettingsViewModel,
    required this.printingSettingsViewModel,
    required this.printingRepository,
    required this.prepStationRepository,
    required this.priceCheckerController,
    required this.priceCheckerRepository,
    required this.analyticsEngine,
    required this.capabilities,
    required this.navigation,
    this.onCameraWedgeChanged,
  });

  /// Start or stop the counter camera the moment the switch is flipped.
  final Future<void> Function()? onCameraWedgeChanged;

  final DeviceSettingsViewModel deviceSettingsViewModel;
  final PrintingSettingsViewModel printingSettingsViewModel;
  final PrintingRepository printingRepository;
  final PrepStationRepository prepStationRepository;
  final PriceCheckerModeController priceCheckerController;
  final PriceCheckerRepository priceCheckerRepository;
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
                  capabilities: capabilities,
                  priceCheckerController: priceCheckerController,
                  priceCheckerRepository: priceCheckerRepository,
                  analyticsEngine: analyticsEngine,
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
    required this.printingRepository,
    required this.prepStationRepository,
    required this.priceCheckerController,
    required this.priceCheckerRepository,
    required this.capabilities,
    required this.analyticsEngine,
    this.onCameraWedgeChanged,
  });

  /// Lets the app start or stop the camera the moment the switch is flipped,
  /// so a shop that turns it on does not have to restart the till.
  final Future<void> Function()? onCameraWedgeChanged;

  final DeviceSettingsViewModel deviceSettingsViewModel;
  final PrintingSettingsViewModel printingSettingsViewModel;
  final PrintingRepository printingRepository;
  final PrepStationRepository prepStationRepository;
  final AuthorizationCapabilities capabilities;
  final PriceCheckerModeController priceCheckerController;
  final PriceCheckerRepository priceCheckerRepository;
  final AnalyticsEngine? analyticsEngine;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (deviceSettingsViewModel.isLoading ||
        printingSettingsViewModel.isLoadingConfig) {
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
                  capabilities: capabilities,
                  analyticsEngine: analyticsEngine,
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: spacing.lg),
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: PointyDetailSection(
            icon: Icons.photo_camera_outlined,
            title: l10n.cameraWedgeSectionTitle,
            child: _CameraWedgePanel(
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

/// The counter camera, offered only where it can actually run.
///
/// A switch, not a wizard: pointing a camera at the counter is a physical act
/// and the software's whole job is to stay out of the way afterwards. The
/// description says plainly that 2-D is fast and 1-D is slower, because that
/// is true and a shop that expects otherwise will think it is broken.
class _CameraWedgePanel extends StatefulWidget {
  const _CameraWedgePanel({required this.viewModel, this.onChanged});

  final DeviceSettingsViewModel viewModel;
  final Future<void> Function()? onChanged;

  @override
  State<_CameraWedgePanel> createState() => _CameraWedgePanelState();
}

class _CameraWedgePanelState extends State<_CameraWedgePanel> {
  @override
  void initState() {
    super.initState();
    // Asking the OS which cameras exist is cheap and the answer changes when
    // somebody plugs one in, so it is read when the screen opens rather than
    // cached with the rest of the settings.
    unawaited(widget.viewModel.loadCameraWedgeDevices());
  }

  DeviceSettingsViewModel get viewModel => widget.viewModel;
  Future<void> Function()? get onChanged => widget.onChanged;

  /// The cameras to offer, plus the one that was picked and is no longer here.
  ///
  /// A `DropdownButton` asserts that its value is among its items, so a shop
  /// that unplugged the camera it had chosen used to open this screen and hit
  /// that assertion. Keeping the absent camera in the list is also the honest
  /// answer: the setting still points at it, and saying so is more use than
  /// quietly showing "automatic".
  List<CameraWedgeDevice> get _devices {
    final devices = viewModel.cameraWedgeDevices;
    final picked = viewModel.cameraWedgeDeviceId;
    if (picked == null || devices.any((device) => device.id == picked)) {
      return devices;
    }
    return [...devices, CameraWedgeDevice.fromPlatformName(picked)];
  }

  String? get _selectableDeviceId {
    final picked = viewModel.cameraWedgeDeviceId;
    return _devices.any((device) => device.id == picked) ? picked : null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    if (!viewModel.cameraWedgeSupported) {
      return PointyInlineMessage(
        message: l10n.cameraWedgeUnsupported,
        icon: Icons.info_outline,
        compact: true,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('camera_wedge_toggle'),
          contentPadding: EdgeInsets.zero,
          value: viewModel.cameraWedgeEnabled,
          onChanged: viewModel.isSaving
              ? null
              : (value) => unawaited(
                  viewModel.updateCameraWedgeEnabled(
                    value,
                    onChanged: onChanged,
                  ),
                ),
          title: Text(l10n.cameraWedgeToggleTitle),
          subtitle: Padding(
            padding: EdgeInsetsDirectional.only(top: spacing.xs),
            child: Text(l10n.cameraWedgeToggleDescription),
          ),
          secondary: const Icon(Icons.photo_camera_outlined),
        ),
        if (viewModel.cameraWedgeEnabled) ...[
          SizedBox(height: spacing.md),
          // Only worth asking once the feature is on: a till often has a
          // webcam facing the cashier as well as the one on a stand facing
          // the counter, and reading off the wrong one is the whole feature
          // failing.
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String?>(
                  key: const ValueKey('camera_wedge_device_picker'),
                  initialValue: _selectableDeviceId,
                  // Without this the menu lays a camera's name out at its
                  // natural width and lets it wrap down the screen; the field
                  // is the width the name has to live in.
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.cameraWedgeCameraLabel,
                    prefixIcon: const Icon(Icons.videocam_outlined),
                  ),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(
                        l10n.cameraWedgeCameraAutomatic,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    for (final device in _devices)
                      DropdownMenuItem<String?>(
                        value: device.id,
                        child: Text(
                          // A camera's name is Latin text in an Arabic
                          // screen: without an isolate the bidi algorithm
                          // reorders its trailing punctuation and digits
                          // around the surrounding direction.
                          ltrIsolated(device.label),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: viewModel.isSaving
                      ? null
                      : (value) => unawaited(
                          viewModel.updateCameraWedgeDevice(
                            value,
                            onChanged: onChanged,
                          ),
                        ),
                ),
              ),
              SizedBox(width: spacing.sm),
              IconButton(
                key: const ValueKey('camera_wedge_refresh_button'),
                tooltip: l10n.cameraWedgeRefreshCameras,
                onPressed: () => unawaited(viewModel.loadCameraWedgeDevices()),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (viewModel.cameraWedgeDevices.isEmpty) ...[
            SizedBox(height: spacing.sm),
            PointyInlineMessage(
              message: l10n.cameraWedgeNoCameras,
              icon: Icons.info_outline,
              compact: true,
            ),
          ],
          SizedBox(height: spacing.sm),
          // The state of the actual camera, not of the switch. This used to
          // say "running" whenever the toggle was on, which is what a shop
          // read while the camera it had picked was failing every still.
          const _CameraWedgeStatus(),
        ],
      ],
    );
  }
}

/// Says whether the camera is reading, and admits when it is not.
///
/// Listens to the running wedge rather than to the switch, because those are
/// different facts: a camera can be switched on, opened, and still fail every
/// still it is asked for — a camera already held by another program, one that
/// was unplugged, one whose driver will not hand over a photo. Every one of
/// those used to read as "the camera is working now".
class _CameraWedgeStatus extends StatelessWidget {
  const _CameraWedgeStatus();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final controller = CameraWedgeScope.controllerOf(context);
    if (controller == null) {
      return PointyInlineMessage(
        message: l10n.cameraWedgeRunning,
        icon: Icons.check_circle_outline,
        compact: true,
      );
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => controller.failure != null
          ? PointyInlineMessage(
              key: const ValueKey('camera_wedge_failed_message'),
              message: l10n.productImageCameraUnavailable,
              icon: Icons.error_outline,
              compact: true,
            )
          : PointyInlineMessage(
              key: const ValueKey('camera_wedge_running_message'),
              message: l10n.cameraWedgeRunning,
              icon: Icons.check_circle_outline,
              compact: true,
            ),
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
