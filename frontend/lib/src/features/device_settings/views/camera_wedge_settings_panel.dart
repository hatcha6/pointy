import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/barcode/camera_wedge/camera_wedge_controller.dart';
import '../../../shared/barcode/camera_wedge/camera_wedge_health.dart';
import '../../../shared/barcode/camera_wedge/camera_wedge_preview.dart';
import '../../../shared/barcode/camera_wedge/camera_wedge_preview_panel.dart';
import '../../../shared/barcode/camera_wedge/camera_wedge_scope.dart';
import '../../../shared/barcode/camera_wedge/camera_wedge_source.dart';
import '../../../shared/barcode/camera_wedge/camera_wedge_status_text.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/device_settings_view_model.dart';

/// The counter camera, offered only where it can actually run.
///
/// A switch, not a wizard: pointing a camera at the counter is a physical act
/// and the software's whole job is to stay out of the way afterwards. The
/// description says plainly that 2-D is fast and 1-D is slower, because that
/// is true and a shop that expects otherwise will think it is broken.
class CameraWedgeSettingsPanel extends StatefulWidget {
  const CameraWedgeSettingsPanel({
    super.key,
    required this.viewModel,
    this.onChanged,
  });

  final DeviceSettingsViewModel viewModel;
  final Future<void> Function()? onChanged;

  @override
  State<CameraWedgeSettingsPanel> createState() =>
      _CameraWedgeSettingsPanelState();
}

class _CameraWedgeSettingsPanelState extends State<CameraWedgeSettingsPanel> {
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
          const CameraWedgeSettingsStatus(),
        ],
      ],
    );
  }
}

/// Says whether the camera is reading, admits when it is not, and shows what
/// it sees.
///
/// Listens to the running wedge rather than to the switch, because those are
/// different facts: a camera can be switched on and still not be reading — no
/// camera plugged in, Windows' privacy setting blocking it, another program
/// holding it, frames that stopped arriving. Each gets its own sentence, and
/// the one only a person can fix gets the button that opens the right page.
class CameraWedgeSettingsStatus extends StatelessWidget {
  const CameraWedgeSettingsStatus({super.key});

  /// Windows' own page for "Let desktop apps access your camera".
  static final privacySettingsUri = Uri.parse('ms-settings:privacy-webcam');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final controller = CameraWedgeScope.controllerOf(context);
    if (controller == null) {
      // Saved, and the app is still bringing the camera up.
      return PointyInlineMessage(
        key: const ValueKey('camera_wedge_status_message'),
        message: l10n.cameraWedgeStarting,
        icon: Icons.hourglass_top,
        compact: true,
      );
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) =>
          _StatusBody(controller: controller, health: controller.health),
    );
  }
}

class _StatusBody extends StatelessWidget {
  const _StatusBody({required this.controller, required this.health});

  final CameraWedgeController controller;
  final CameraWedgeHealth health;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final status = cameraWedgeStatusText(l10n, health);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        switch (status.tone) {
          CameraWedgeStatusTone.ok => PointyInlineMessage.success(
            key: const ValueKey('camera_wedge_status_message'),
            message: status.message,
          ),
          CameraWedgeStatusTone.pending => PointyInlineMessage(
            key: const ValueKey('camera_wedge_status_message'),
            message: status.message,
            icon: Icons.hourglass_top,
          ),
          CameraWedgeStatusTone.problem => PointyInlineMessage.warning(
            key: const ValueKey('camera_wedge_status_message'),
            message: status.message,
          ),
        },
        if (health.substitutedDevice && health.deviceLabel.isNotEmpty) ...[
          SizedBox(height: spacing.xs),
          PointyInlineMessage.warning(
            key: const ValueKey('camera_wedge_substituted_message'),
            message: l10n.cameraWedgeSubstituted(
              ltrIsolated(health.deviceLabel),
            ),
            compact: true,
          ),
        ],
        if (health.fault == CameraWedgeFault.accessDenied) ...[
          SizedBox(height: spacing.xs),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: const ValueKey('camera_wedge_privacy_settings_button'),
              onPressed: () => unawaited(
                launchUrl(CameraWedgeSettingsStatus.privacySettingsUri),
              ),
              icon: const Icon(Icons.privacy_tip_outlined),
              label: Text(l10n.cameraWedgeOpenPrivacySettings),
            ),
          ),
        ],
        if (controller.supportsPreview && health.expectsPicture) ...[
          SizedBox(height: spacing.sm),
          // What the decoder sees, for aiming the camera and checking its
          // focus. Only while this screen is open; the F8 panel shows the
          // same thing from anywhere.
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CameraWedgePreview(controller: controller),
                  SizedBox(height: spacing.xs),
                  CameraWedgeStatusLines(health: health, showStatus: false),
                  Text(
                    '${l10n.cameraWedgeAimHint} '
                    '${l10n.cameraWedgePreviewShortcutHint}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
