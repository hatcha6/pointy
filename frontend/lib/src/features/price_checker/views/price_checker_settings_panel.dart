import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/price_checker_config.dart';
import '../../../data/repositories/price_checker_repository.dart';
import '../../../data/services/auto_start_service.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/price_checker/price_checker_mode_controller.dart';
import '../price_checker_mode_actions.dart';

/// Device-settings panel to configure this device as a customer-facing price
/// checker: set it up, jump into kiosk mode, tune scanning (camera on/off,
/// which camera, how long a product stays on screen), change the exit PIN,
/// edit the fleet name/location, or turn it back into a normal POS device.
class PriceCheckerSettingsPanel extends StatelessWidget {
  const PriceCheckerSettingsPanel({
    super.key,
    required this.controller,
    required this.repository,
  });

  final PriceCheckerModeController controller;
  final PriceCheckerRepository repository;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return controller.isConfigured
            ? _ConfiguredView(controller: controller, repository: repository)
            : _UnconfiguredView(controller: controller, repository: repository);
      },
    );
  }
}

class _UnconfiguredView extends StatelessWidget {
  const _UnconfiguredView({required this.controller, required this.repository});

  final PriceCheckerModeController controller;
  final PriceCheckerRepository repository;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.priceCheckerSettingsDescription,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.4),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            onPressed: () => enterPriceCheckerMode(
              context,
              controller: controller,
              repository: repository,
            ),
            icon: const Icon(Icons.price_check_rounded),
            label: Text(l10n.priceCheckerSettingsSetupButton),
          ),
        ),
      ],
    );
  }
}

class _ConfiguredView extends StatelessWidget {
  const _ConfiguredView({required this.controller, required this.repository});

  final PriceCheckerModeController controller;
  final PriceCheckerRepository repository;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final config = controller.config;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointyDetailCallout(
          icon: Icons.check_circle_outline_rounded,
          tone: PointyCalloutTone.success,
          title: l10n.priceCheckerConfiguredStatus,
          message: config.deviceName.isNotEmpty
              ? config.deviceName
              : l10n.priceCheckerNoNameSet,
        ),
        const SizedBox(height: 16),
        PointySummaryList(
          rows: [
            PointySummaryRow(
              label: l10n.priceCheckerDeviceNameLabel,
              value: config.deviceName.isNotEmpty
                  ? config.deviceName
                  : l10n.priceCheckerNoNameSet,
            ),
            if (config.location.isNotEmpty)
              PointySummaryRow(
                label: l10n.priceCheckerLocationLabel,
                value: config.location,
              ),
          ],
        ),
        const SizedBox(height: 20),
        _ScanSettingsSection(controller: controller),
        const SizedBox(height: 20),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              onPressed: () => controller.enter(),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(l10n.priceCheckerEnterModeButton),
            ),
            OutlinedButton.icon(
              onPressed: () => _changePin(context),
              icon: const Icon(Icons.password_rounded),
              label: Text(l10n.priceCheckerChangePinButton),
            ),
            OutlinedButton.icon(
              onPressed: () => _editDetails(context),
              icon: const Icon(Icons.edit_outlined),
              label: Text(l10n.priceCheckerEditDetailsButton),
            ),
            TextButton.icon(
              onPressed: () => _remove(context),
              style: TextButton.styleFrom(foregroundColor: colors.danger),
              icon: const Icon(Icons.power_settings_new_rounded),
              label: Text(l10n.priceCheckerRemoveButton),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _changePin(BuildContext context) async {
    final pin = await showDialog<String>(
      context: context,
      builder: (context) => const _ChangePinDialog(),
    );
    if (pin != null && pin.isNotEmpty) {
      await controller.updatePin(pin);
    }
  }

  Future<void> _editDetails(BuildContext context) async {
    final result = await showDialog<_DetailsResult>(
      context: context,
      builder: (context) => _EditDetailsDialog(
        name: controller.config.deviceName,
        location: controller.config.location,
      ),
    );
    if (result == null) {
      return;
    }
    await controller.updateDetails(
      deviceName: result.name,
      location: result.location,
    );
    // Keep the fleet entry in step with the new name/location.
    await repository.selfRegister(
      identifier: controller.config.identifier,
      name: result.name,
      location: result.location,
    );
  }

  Future<void> _remove(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.priceCheckerRemoveConfirmTitle),
        content: Text(l10n.priceCheckerRemoveConfirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.priceCheckerRemoveButton),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.clear();
    }
  }
}

/// Scanning preferences for this kiosk: camera on/off, which camera it scans
/// with, and how long a found product stays on screen. The camera rows only
/// appear on platforms with camera scanning; the dwell applies to every input
/// method (camera, wedge scanner, manual entry).
class _ScanSettingsSection extends StatefulWidget {
  const _ScanSettingsSection({required this.controller});

  final PriceCheckerModeController controller;

  @override
  State<_ScanSettingsSection> createState() => _ScanSettingsSectionState();
}

class _ScanSettingsSectionState extends State<_ScanSettingsSection> {
  /// Live slider position while dragging; persisted once on release so a drag
  /// doesn't write SharedPreferences on every tick.
  int? _draggingDwell;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final config = widget.controller.config;
    final dwell = _draggingDwell ?? config.foundDwellSeconds;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.priceCheckerScanSettingsTitle,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        if (priceCheckerCameraScanningSupported) ...[
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: config.cameraEnabled,
            onChanged: (value) => unawaited(
              widget.controller.updateScanSettings(cameraEnabled: value),
            ),
            title: Text(l10n.priceCheckerCameraToggleLabel),
            subtitle: Text(l10n.priceCheckerCameraToggleHint),
          ),
          if (config.cameraEnabled) ...[
            const SizedBox(height: 4),
            Text(l10n.priceCheckerCameraFacingLabel),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: SegmentedButton<PriceCheckerCameraFacing>(
                segments: [
                  ButtonSegment(
                    value: PriceCheckerCameraFacing.front,
                    icon: const Icon(Icons.camera_front_rounded),
                    label: Text(l10n.priceCheckerCameraFront),
                  ),
                  ButtonSegment(
                    value: PriceCheckerCameraFacing.back,
                    icon: const Icon(Icons.camera_rear_rounded),
                    label: Text(l10n.priceCheckerCameraBack),
                  ),
                ],
                selected: {config.cameraFacing},
                showSelectedIcon: false,
                onSelectionChanged: (selection) => unawaited(
                  widget.controller.updateScanSettings(
                    cameraFacing: selection.single,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.priceCheckerDwellLabel),
          subtitle: Text(l10n.priceCheckerDwellHint),
          trailing: Text(
            l10n.priceCheckerDwellSecondsValue(dwell),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: colors.primaryStrong,
            ),
          ),
        ),
        Slider(
          value: dwell.toDouble(),
          min: PriceCheckerConfig.minFoundDwellSeconds.toDouble(),
          max: PriceCheckerConfig.maxFoundDwellSeconds.toDouble(),
          divisions:
              PriceCheckerConfig.maxFoundDwellSeconds -
              PriceCheckerConfig.minFoundDwellSeconds,
          label: l10n.priceCheckerDwellSecondsValue(dwell),
          onChanged: (value) => setState(() => _draggingDwell = value.round()),
          onChangeEnd: (value) {
            unawaited(
              widget.controller.updateScanSettings(
                foundDwellSeconds: value.round(),
              ),
            );
            setState(() => _draggingDwell = null);
          },
        ),
      ],
    );
  }
}

/// Windows-only: launch the client automatically at user login. Lives in its
/// own section so it's useful for any till, not just kiosks.
class RunOnStartupPanel extends StatefulWidget {
  const RunOnStartupPanel({super.key, this.service = const AutoStartService()});

  final AutoStartService service;

  @override
  State<RunOnStartupPanel> createState() => _RunOnStartupPanelState();
}

class _RunOnStartupPanelState extends State<RunOnStartupPanel> {
  bool _enabled = false;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await widget.service.isEnabled();
    if (mounted) {
      setState(() {
        _enabled = enabled;
        _busy = false;
      });
    }
  }

  Future<void> _toggle(bool value) async {
    setState(() => _busy = true);
    final result = await widget.service.setEnabled(value);
    if (mounted) {
      setState(() {
        _enabled = result;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      value: _enabled,
      onChanged: _busy ? null : _toggle,
      title: Text(l10n.priceCheckerRunOnStartupLabel),
      subtitle: Text(l10n.priceCheckerRunOnStartupHint),
    );
  }
}

class _ChangePinDialog extends StatefulWidget {
  const _ChangePinDialog();

  @override
  State<_ChangePinDialog> createState() => _ChangePinDialogState();
}

class _ChangePinDialogState extends State<_ChangePinDialog> {
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = AppLocalizations.of(context)!;
    final pin = _pin.text.trim();
    if (pin.length < 4) {
      setState(() => _error = l10n.priceCheckerPinTooShort);
      return;
    }
    if (pin != _confirm.text.trim()) {
      setState(() => _error = l10n.priceCheckerPinMismatch);
      return;
    }
    Navigator.of(context).pop(pin);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return AlertDialog(
      title: Text(l10n.priceCheckerChangePinTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: l10n.priceCheckerPinLabel,
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirm,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: l10n.priceCheckerConfirmPinLabel,
              counterText: '',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: TextStyle(
                color: colors.danger,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.saveButton)),
      ],
    );
  }
}

class _DetailsResult {
  const _DetailsResult({required this.name, required this.location});

  final String name;
  final String location;
}

class _EditDetailsDialog extends StatefulWidget {
  const _EditDetailsDialog({required this.name, required this.location});

  final String name;
  final String location;

  @override
  State<_EditDetailsDialog> createState() => _EditDetailsDialogState();
}

class _EditDetailsDialogState extends State<_EditDetailsDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.name,
  );
  late final TextEditingController _location = TextEditingController(
    text: widget.location,
  );

  @override
  void dispose() {
    _name.dispose();
    _location.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.priceCheckerEditDetailsButton),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: l10n.priceCheckerDeviceNameLabel,
              hintText: l10n.priceCheckerDeviceNameHint,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _location,
            decoration: InputDecoration(
              labelText: l10n.priceCheckerLocationLabel,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _DetailsResult(
              name: _name.text.trim(),
              location: _location.text.trim(),
            ),
          ),
          child: Text(l10n.saveButton),
        ),
      ],
    );
  }
}
