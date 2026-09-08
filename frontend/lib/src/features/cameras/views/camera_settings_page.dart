import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/camera.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../../data/services/recorder_discovery.dart';
import '../view_models/camera_settings_view_model.dart';

/// Where a shop wires its DVR up, and the only place that ever touches
/// credentials.
///
/// Everything else in this feature is read-only about the recorder, which is
/// why the whole rest of the app can stay hidden until one connects
/// successfully here.
class CameraSettingsPage extends StatefulWidget {
  const CameraSettingsPage({
    super.key,
    required this.viewModel,
    required this.enableSurveillance,
    required this.onToggleEnabled,
  });

  final CameraSettingsViewModel viewModel;

  /// Mirrors `ShopSettings.enableSurveillance`. The backend turns it on the
  /// first time a recorder connects; this is where a manager turns it off.
  final bool enableSurveillance;
  final Future<void> Function(bool enabled) onToggleEnabled;

  @override
  State<CameraSettingsPage> createState() => _CameraSettingsPageState();
}

class _CameraSettingsPageState extends State<CameraSettingsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.viewModel.load());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final viewModel = widget.viewModel;
        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.cameraSettingsTitle),
            isLoading: viewModel.isLoading || viewModel.isMutating,
            actions: [
              IconButton(
                tooltip: l10n.cameraSettingsAddRecorder,
                onPressed: viewModel.isMutating
                    ? null
                    : () => _openRecorderForm(context, null),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          body: _body(context, l10n),
        );
      },
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final viewModel = widget.viewModel;
    final spacing = AdaptiveSpacing.of(context);

    if (viewModel.isLoading && viewModel.recorders.isEmpty) {
      return const PointyLoadingArea();
    }

    return ListView(
      padding: spacing.pagePadding,
      children: [
        AdaptiveMaxWidth(
          width: AppContentWidth.form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (viewModel.recorders.isNotEmpty) ...[
                PointySettingsSection(
                  children: [
                    SwitchListTile(
                      value: widget.enableSurveillance,
                      onChanged: (value) =>
                          unawaited(widget.onToggleEnabled(value)),
                      title: Text(l10n.cameraSettingsEnableTitle),
                      subtitle: Text(l10n.cameraSettingsEnableSubtitle),
                      secondary: const Icon(Icons.videocam_outlined),
                    ),
                  ],
                ),
                const SizedBox(height: PointyDimensions.sectionGap),
              ],
              PointySectionHeader(title: l10n.cameraSettingsRecordersSection),
              const SizedBox(height: PointyDimensions.denseGap),
              if (viewModel.recorders.isEmpty)
                PointyEmptyState(
                  icon: Icons.dvr_outlined,
                  title: l10n.camerasEmptyTitle,
                  message: l10n.camerasEmptyBody,
                  action: FilledButton.icon(
                    onPressed: () => _openRecorderForm(context, null),
                    icon: const Icon(Icons.add),
                    label: Text(l10n.cameraSettingsAddRecorder),
                  ),
                )
              else
                for (final recorder in viewModel.recorders) ...[
                  _RecorderCard(
                    recorder: recorder,
                    cameras: viewModel.camerasFor(recorder),
                    isBusy: viewModel.isMutating,
                    onEdit: () => _openRecorderForm(context, recorder),
                    onSync: () =>
                        unawaited(viewModel.syncRecorder(recorder.id)),
                    onDelete: () => _confirmDelete(context, recorder),
                    onCameraChanged:
                        ({
                          required Camera camera,
                          String? name,
                          bool? isEnabled,
                          bool? coversCheckout,
                          CameraQuality? liveQuality,
                          CameraQuality? playbackQuality,
                        }) => unawaited(
                          viewModel.updateCamera(
                            camera,
                            name: name,
                            isEnabled: isEnabled,
                            coversCheckout: coversCheckout,
                            liveQuality: liveQuality,
                            playbackQuality: playbackQuality,
                          ),
                        ),
                  ),
                  const SizedBox(height: PointyDimensions.sectionGap),
                ],
              if (viewModel.cameras.isNotEmpty)
                PointyInlineMessage(
                  message: l10n.cameraSettingsCoversCheckoutHint,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openRecorderForm(
    BuildContext context,
    Recorder? recorder,
  ) async {
    widget.viewModel.clearTestResult();
    // A fresh form starts with a fresh sweep rather than whatever the last one
    // found; the form re-runs it for a recorder being added.
    widget.viewModel.clearDiscovered();
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => RecorderFormPage(
          viewModel: widget.viewModel,
          initial: recorder == null
              ? const RecorderDraft()
              : RecorderDraft.fromRecorder(recorder),
        ),
      ),
    );
    if (saved == true && mounted) {
      await widget.viewModel.load();
    }
  }

  Future<void> _confirmDelete(BuildContext context, Recorder recorder) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => PointyDestructiveConfirmationDialog(
        title: l10n.recorderDeleteConfirmTitle,
        message: '${recorder.displayName}\n${l10n.recorderDeleteConfirmBody}',
        confirmLabel: l10n.recorderDeleteAction,
      ),
    );
    if (confirmed == true && mounted) {
      await widget.viewModel.deleteRecorder(recorder.id);
    }
  }
}

typedef _CameraChanged =
    void Function({
      required Camera camera,
      String? name,
      bool? isEnabled,
      bool? coversCheckout,
      CameraQuality? liveQuality,
      CameraQuality? playbackQuality,
    });

class _RecorderCard extends StatelessWidget {
  const _RecorderCard({
    required this.recorder,
    required this.cameras,
    required this.isBusy,
    required this.onEdit,
    required this.onSync,
    required this.onDelete,
    required this.onCameraChanged,
  });

  final Recorder recorder;
  final List<Camera> cameras;
  final bool isBusy;
  final VoidCallback onEdit;
  final VoidCallback onSync;
  final VoidCallback onDelete;
  final _CameraChanged onCameraChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final drift = _clockDriftMinutes();
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              // Three icon buttons and a four-line subtitle do not fit beside
              // each other on a phone; past that width they collapse into one
              // menu rather than squeezing the text into a column of words.
              final roomy = constraints.maxWidth >= 480;
              return ListTile(
                isThreeLine: true,
                leading: Icon(
                  Icons.dvr_outlined,
                  color: switch (recorder.status) {
                    RecorderStatus.ok => colors.success,
                    RecorderStatus.error => colors.danger,
                    RecorderStatus.never => colors.mutedInk,
                  },
                ),
                title: Text(recorder.displayName),
                subtitle: Text(_subtitle(l10n, drift)),
                trailing: roomy
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: l10n.recorderSyncAction,
                            onPressed: isBusy ? null : onSync,
                            icon: const Icon(Icons.sync),
                          ),
                          IconButton(
                            tooltip: l10n.recorderFormTitle,
                            onPressed: isBusy ? null : onEdit,
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: l10n.recorderDeleteAction,
                            onPressed: isBusy ? null : onDelete,
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      )
                    : _RecorderMenu(
                        isBusy: isBusy,
                        onSync: onSync,
                        onEdit: onEdit,
                        onDelete: onDelete,
                      ),
              );
            },
          ),
          if (recorder.status == RecorderStatus.error &&
              recorder.lastError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: PointyInlineMessage.error(message: recorder.lastError),
            ),
          // Only when it is actually a problem. Almost every recorder in this
          // market is set to Libyan local time, which is right in the owner's
          // terms and needs no explaining; the offset is worth a warning only
          // when it disagrees with the till's own clock, because that is when
          // invoice playback would land on the wrong minute if we trusted it.
          if (drift != null && drift != 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: PointyInlineMessage.warning(
                message:
                    '${l10n.recorderClockDiffersTitle}\n'
                    '${l10n.recorderClockDiffersBody(drift.abs().toString())}',
              ),
            ),
          if (cameras.isNotEmpty) const Divider(height: 1),
          for (final camera in cameras)
            _CameraRow(
              camera: camera,
              onChanged: onCameraChanged,
              isBusy: isBusy,
            ),
        ],
      ),
    );
  }

  /// How far the recorder's clock is from *this device's* clock, or null when
  /// it has not been measured.
  ///
  /// Not the raw UTC offset: a recorder on Libyan local time reads +120 and is
  /// perfectly correct, so reporting that number would be reporting a
  /// non-event. What matters is whether it agrees with the shop.
  int? _clockDriftMinutes() {
    if (!recorder.clockOffsetIsMeasured) {
      return null;
    }
    final here = DateTime.now().timeZoneOffset.inMinutes;
    return recorder.clockOffsetMinutes - here;
  }

  String _subtitle(AppLocalizations l10n, int? drift) {
    final parts = <String>[
      switch (recorder.status) {
        RecorderStatus.ok => l10n.recorderStatusOk,
        RecorderStatus.error => l10n.recorderStatusError,
        RecorderStatus.never => l10n.recorderStatusNever,
      },
    ];
    if (recorder.modelName.isNotEmpty) {
      parts.add(recorder.modelName);
    }
    if (recorder.channelCount > 0) {
      parts.add(l10n.cameraChannelCountLabel(recorder.channelCount));
    }
    if (drift == 0) {
      parts.add(l10n.recorderClockMatchesShop);
    }
    return parts.join(' · ');
  }
}

class _RecorderMenu extends StatelessWidget {
  const _RecorderMenu({
    required this.isBusy,
    required this.onSync,
    required this.onEdit,
    required this.onDelete,
  });

  final bool isBusy;
  final VoidCallback onSync;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<VoidCallback>(
      tooltip: l10n.recorderActionsMenuTooltip,
      enabled: !isBusy,
      onSelected: (action) => action(),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: onSync,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.sync),
            title: Text(l10n.recorderSyncAction),
          ),
        ),
        PopupMenuItem(
          value: onEdit,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.edit_outlined),
            title: Text(l10n.recorderFormTitle),
          ),
        ),
        PopupMenuItem(
          value: onDelete,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_outline),
            title: Text(l10n.recorderDeleteAction),
          ),
        ),
      ],
    );
  }
}

class _CameraRow extends StatelessWidget {
  const _CameraRow({
    required this.camera,
    required this.onChanged,
    required this.isBusy,
  });

  final Camera camera;
  final _CameraChanged onChanged;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ExpansionTile(
      leading: Icon(
        camera.isEnabled
            ? Icons.videocam_outlined
            : Icons.videocam_off_outlined,
      ),
      title: Text(camera.displayName),
      subtitle: Text(
        camera.deviceName.isNotEmpty
            // The channel the recorder knows it by, then whatever the recorder
            // calls it — both matter during setup, when the name above is the
            // shop's own and matches neither.
            ? '${l10n.cameraChannelLabel('${camera.channel}')} · ${camera.deviceName}'
            : l10n.cameraChannelLabel('${camera.channel}'),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        _NameField(camera: camera, onChanged: onChanged, isBusy: isBusy),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: camera.isEnabled,
          onChanged: isBusy
              ? null
              : (value) => onChanged(camera: camera, isEnabled: value),
          title: Text(l10n.cameraSettingsCameraEnabledLabel),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: camera.coversCheckout,
          onChanged: isBusy
              ? null
              : (value) => onChanged(camera: camera, coversCheckout: value),
          title: Text(l10n.cameraSettingsCoversCheckoutLabel),
        ),
        _QualityPicker(
          label: l10n.cameraSettingsLiveQualityLabel,
          value: camera.liveQuality,
          onChanged: isBusy
              ? null
              : (value) => onChanged(camera: camera, liveQuality: value),
        ),
        _QualityPicker(
          label: l10n.cameraSettingsPlaybackQualityLabel,
          value: camera.playbackQuality,
          onChanged: isBusy
              ? null
              : (value) => onChanged(camera: camera, playbackQuality: value),
        ),
      ],
    );
  }
}

class _NameField extends StatefulWidget {
  const _NameField({
    required this.camera,
    required this.onChanged,
    required this.isBusy,
  });

  final Camera camera;
  final _CameraChanged onChanged;
  final bool isBusy;

  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.camera.name,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return TextField(
      controller: _controller,
      enabled: !widget.isBusy,
      decoration: InputDecoration(
        labelText: l10n.cameraRenameTitle,
        hintText: l10n.cameraRenameHint,
      ),
      textInputAction: TextInputAction.done,
      // Saved when the field loses focus as well as on submit: a manager who
      // types a name and taps the next camera should not lose it.
      onTapOutside: (_) => _commit(),
      onSubmitted: (_) => _commit(),
    );
  }

  void _commit() {
    final value = _controller.text.trim();
    if (value == widget.camera.name) {
      return;
    }
    widget.onChanged(camera: widget.camera, name: value);
  }
}

class _QualityPicker extends StatelessWidget {
  const _QualityPicker({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final CameraQuality value;
  final ValueChanged<CameraQuality>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          SegmentedButton<CameraQuality>(
            segments: [
              ButtonSegment(
                value: CameraQuality.sub,
                label: Text(l10n.cameraQualitySub),
              ),
              ButtonSegment(
                value: CameraQuality.main,
                label: Text(l10n.cameraQualityMain),
              ),
            ],
            selected: {value},
            onSelectionChanged: onChanged == null
                ? null
                : (selection) => onChanged!(selection.first),
          ),
        ],
      ),
    );
  }
}

/// The add/edit form for one recorder. Public so the preview harness can render
/// it directly — it is only reachable in the app behind a tap on a list.
class RecorderFormPage extends StatefulWidget {
  const RecorderFormPage({
    super.key,
    required this.viewModel,
    required this.initial,
  });

  final CameraSettingsViewModel viewModel;
  final RecorderDraft initial;

  @override
  State<RecorderFormPage> createState() => _RecorderFormPageState();
}

class _RecorderFormPageState extends State<RecorderFormPage> {
  late RecorderDraft _draft = widget.initial;
  String _pickedHost = '';
  late final TextEditingController _name = TextEditingController(
    text: widget.initial.name,
  );
  late final TextEditingController _host = TextEditingController(
    text: widget.initial.host,
  );
  late final TextEditingController _port = TextEditingController(
    text: '${widget.initial.port}',
  );
  late final TextEditingController _rtspPort = TextEditingController(
    text: '${widget.initial.rtspPort}',
  );
  late final TextEditingController _username = TextEditingController(
    text: widget.initial.username,
  );
  final TextEditingController _password = TextEditingController();
  late final TextEditingController _rtspTemplate = TextEditingController(
    text: widget.initial.rtspPathTemplate,
  );
  late final TextEditingController _channelCount = TextEditingController(
    text: widget.initial.channelCount > 0 ? '${widget.initial.channelCount}' : '',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      // Only for a recorder being added. Re-opening a working one to change a
      // password should not kick off a network sweep it has no use for.
      if (widget.initial.id == null && widget.initial.host.isEmpty) {
        unawaited(widget.viewModel.scanForRecorders());
      }
    });
  }

  @override
  void dispose() {
    for (final controller in [
      _rtspTemplate,
      _channelCount,
      _name,
      _host,
      _port,
      _rtspPort,
      _username,
      _password,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// The stream shapes these boxes actually serve, offered by name because an
  /// installer knows what brand is on the sticker and never the URL. Mirrors
  /// ``TEMPLATE_PRESETS`` in apps.surveillance.drivers.generic_rtsp.
  static const Map<String, String> _rtspPresets = {
    'XMEye': '/user={username}&password={password}&channel={channel}&stream={stream}.sdp?',
    'Uniview': '/unicast/c{channel}/s{stream}/live',
    'ch/stream': '/ch{channel}/{stream}',
    'live': '/live/ch{channel0}_{stream}',
  };

  RecorderDraft get _current => _draft.copyWith(
    name: _name.text.trim(),
    host: _host.text.trim(),
    port: int.tryParse(_port.text.trim()) ?? 80,
    rtspPort: int.tryParse(_rtspPort.text.trim()) ?? 554,
    username: _username.text.trim(),
    password: _password.text,
    rtspPathTemplate: _rtspTemplate.text.trim(),
    channelCount: int.tryParse(_channelCount.text.trim()) ?? 0,
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        final viewModel = widget.viewModel;
        final spacing = AdaptiveSpacing.of(context);
        final test = viewModel.testResult;

        return PointyScaffold(
          appBar: PointyAppBar(
            title: Text(l10n.recorderFormTitle),
            isLoading: viewModel.isTesting || viewModel.isMutating,
          ),
          body: ListView(
            padding: spacing.pagePadding,
            children: [
              AdaptiveMaxWidth(
                width: AppContentWidth.form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // First, and deliberately: most people setting this up have
                    // never typed an IP address and should not have to start by
                    // learning what one is. The manual fields stay below for the
                    // installer who already knows.
                    _DiscoveryPanel(
                      viewModel: viewModel,
                      pickedHost: _pickedHost,
                      onPick: _applyDiscovered,
                    ),
                    const SizedBox(height: PointyDimensions.sectionGap),
                    PointySectionHeader(title: l10n.recorderManualSectionTitle),
                    const SizedBox(height: PointyDimensions.denseGap),
                    TextField(
                      controller: _name,
                      decoration: InputDecoration(
                        labelText: l10n.recorderNameLabel,
                        hintText: l10n.recorderNameHint,
                      ),
                    ),
                    const SizedBox(height: PointyDimensions.denseGap),
                    DropdownButtonFormField<RecorderBrand>(
                      initialValue: _draft.brand,
                      decoration: InputDecoration(
                        labelText: l10n.recorderBrandLabel,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: RecorderBrand.auto,
                          child: Text(l10n.recorderBrandAuto),
                        ),
                        DropdownMenuItem(
                          value: RecorderBrand.hikvision,
                          child: Text(l10n.recorderBrandHikvision),
                        ),
                        DropdownMenuItem(
                          value: RecorderBrand.dahua,
                          child: Text(l10n.recorderBrandDahua),
                        ),
                        DropdownMenuItem(
                          value: RecorderBrand.xiongmai,
                          child: Text(l10n.recorderBrandXiongmai),
                        ),
                        DropdownMenuItem(
                          value: RecorderBrand.onvif,
                          child: Text(l10n.recorderBrandOnvif),
                        ),
                        DropdownMenuItem(
                          value: RecorderBrand.genericRtsp,
                          child: Text(l10n.recorderBrandGenericRtsp),
                        ),
                      ],
                      onChanged: (value) => setState(() {
                        _draft = _draft.copyWith(brand: value);
                      }),
                    ),
                    if (_draft.brand == RecorderBrand.genericRtsp ||
                        _draft.brand == RecorderBrand.xiongmai) ...[
                      const SizedBox(height: PointyDimensions.denseGap),
                      TextField(
                        controller: _rtspTemplate,
                        // A stream path is Latin however the screen reads.
                        textDirection: TextDirection.ltr,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: l10n.recorderRtspTemplateLabel,
                          helperText: l10n.recorderRtspTemplateHelp,
                          helperMaxLines: 2,
                        ),
                      ),
                      // Nobody knows their DVR's URL shape, so the shapes we
                      // know are offered by name and fill the field in.
                      const SizedBox(height: PointyDimensions.denseGap),
                      Wrap(
                        spacing: PointyDimensions.denseGap,
                        children: [
                          for (final preset in _rtspPresets.entries)
                            ActionChip(
                              label: Text(preset.key),
                              onPressed: () => setState(() {
                                _rtspTemplate.text = preset.value;
                              }),
                            ),
                        ],
                      ),
                    ],
                    if (_draft.brand == RecorderBrand.genericRtsp) ...[
                      const SizedBox(height: PointyDimensions.denseGap),
                      TextField(
                        controller: _channelCount,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: l10n.recorderChannelCountLabel,
                          helperText: l10n.recorderChannelCountHelp,
                          helperMaxLines: 2,
                        ),
                      ),
                      const SizedBox(height: PointyDimensions.denseGap),
                      PointyInlineMessage.warning(
                        message: l10n.recorderLiveOnlyNotice,
                      ),
                    ],
                    const SizedBox(height: PointyDimensions.denseGap),
                    TextField(
                      controller: _host,
                      // An IP address is Latin digits however the screen reads.
                      textDirection: TextDirection.ltr,
                      decoration: InputDecoration(
                        labelText: l10n.recorderHostLabel,
                        hintText: l10n.recorderHostHint,
                      ),
                    ),
                    const SizedBox(height: PointyDimensions.denseGap),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _port,
                            keyboardType: TextInputType.number,
                            textDirection: TextDirection.ltr,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: InputDecoration(
                              labelText: l10n.recorderPortLabel,
                            ),
                          ),
                        ),
                        const SizedBox(width: PointyDimensions.denseGap),
                        Expanded(
                          child: TextField(
                            controller: _rtspPort,
                            keyboardType: TextInputType.number,
                            textDirection: TextDirection.ltr,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: InputDecoration(
                              labelText: l10n.recorderRtspPortLabel,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: PointyDimensions.denseGap),
                    TextField(
                      controller: _username,
                      textDirection: TextDirection.ltr,
                      decoration: InputDecoration(
                        labelText: l10n.recorderUsernameLabel,
                      ),
                    ),
                    const SizedBox(height: PointyDimensions.denseGap),
                    PointyPasswordField(
                      controller: _password,
                      labelText: l10n.recorderPasswordLabel,
                      helperText: widget.initial.id == null
                          ? null
                          : l10n.recorderPasswordKeptHint,
                    ),
                    const SizedBox(height: PointyDimensions.denseGap),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _draft.useHttps,
                      onChanged: (value) => setState(() {
                        _draft = _draft.copyWith(useHttps: value);
                      }),
                      title: Text(l10n.recorderUseHttpsLabel),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _draft.isEnabled,
                      onChanged: (value) => setState(() {
                        _draft = _draft.copyWith(isEnabled: value);
                      }),
                      title: Text(l10n.recorderEnabledLabel),
                    ),
                    const SizedBox(height: PointyDimensions.denseGap),
                    if (test != null) _TestSummary(result: test),
                    const SizedBox(height: PointyDimensions.denseGap),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: viewModel.isTesting
                                ? null
                                : () => unawaited(
                                    viewModel.testRecorder(_current),
                                  ),
                            icon: const Icon(Icons.wifi_tethering),
                            label: Text(l10n.recorderTestAction),
                          ),
                        ),
                        const SizedBox(width: PointyDimensions.denseGap),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: viewModel.isMutating ? null : _save,
                            icon: const Icon(Icons.check),
                            label: Text(l10n.saveButton),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Fills the form from a device the sweep found.
  ///
  /// Also seeds the username, because both brands ship as `admin` and a shop
  /// that has never changed it would otherwise be asked a question it cannot
  /// answer. The password stays empty — that one is theirs.
  void _applyDiscovered(DiscoveredRecorder recorder) {
    setState(() {
      _pickedHost = '${recorder.host}:${recorder.port}';
      _host.text = recorder.host;
      _port.text = '${recorder.port}';
      _draft = _draft.copyWith(brand: recorder.brand);
      if (_username.text.trim().isEmpty) {
        _username.text = 'admin';
      }
      if (_name.text.trim().isEmpty && recorder.model.isNotEmpty) {
        _name.text = recorder.model;
      }
    });
    widget.viewModel.clearTestResult();
  }

  Future<void> _save() async {
    final navigator = Navigator.of(context);
    final ok = await widget.viewModel.saveRecorder(_current);
    if (!mounted) {
      return;
    }
    if (ok) {
      navigator.pop(true);
    }
  }
}

/// "Which of these is yours?" — the whole point of the sweep.
class _DiscoveryPanel extends StatelessWidget {
  const _DiscoveryPanel({
    required this.viewModel,
    required this.pickedHost,
    required this.onPick,
  });

  final CameraSettingsViewModel viewModel;
  final String pickedHost;
  final ValueChanged<DiscoveredRecorder> onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final found = viewModel.discovered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: PointySectionHeader(title: l10n.recorderScanTitle)),
            if (!viewModel.isScanning)
              TextButton.icon(
                onPressed: () => unawaited(viewModel.scanForRecorders()),
                icon: const Icon(Icons.wifi_find_outlined, size: 18),
                label: Text(l10n.recorderScanRetryAction),
              ),
          ],
        ),
        const SizedBox(height: PointyDimensions.denseGap),
        if (viewModel.isScanning)
          Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: PointySpinner(strokeWidth: 2),
              ),
              const SizedBox(width: PointyDimensions.denseGap),
              Expanded(child: Text(l10n.recorderScanRunning)),
            ],
          )
        else if (found.isNotEmpty) ...[
          Text(
            l10n.recorderScanFoundHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: PointyDimensions.denseGap),
          PointySettingsSection(
            children: [
              for (final recorder in found)
                _DiscoveredTile(
                  recorder: recorder,
                  isPicked: pickedHost == '${recorder.host}:${recorder.port}',
                  onTap: () => onPick(recorder),
                ),
            ],
          ),
        ] else if (viewModel.hasScanned)
          PointyInlineMessage(
            icon: Icons.wifi_find_outlined,
            message:
                '${l10n.recorderScanEmptyTitle}\n'
                '${l10n.recorderScanEmptyBody}',
          )
        else
          Text(
            l10n.recorderScanIdlePrompt,
            style: TextStyle(color: colors.mutedInk),
          ),
      ],
    );
  }
}

class _DiscoveredTile extends StatelessWidget {
  const _DiscoveredTile({
    required this.recorder,
    required this.isPicked,
    required this.onTap,
  });

  final DiscoveredRecorder recorder;
  final bool isPicked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return ListTile(
      onTap: onTap,
      leading: Icon(
        Icons.dvr_outlined,
        color: isPicked ? colors.primaryStrong : colors.mutedInk,
      ),
      title: Text(_title(l10n)),
      // The address is Latin digits however the screen reads, and it is the
      // detail that tells two identical recorders apart.
      subtitle: Directionality(
        textDirection: TextDirection.ltr,
        child: Text(
          recorder.port == 80
              ? recorder.host
              : '${recorder.host}:${recorder.port}',
        ),
      ),
      trailing: isPicked
          ? Icon(Icons.check_circle, color: colors.primaryStrong)
          : const PointyDisclosureChevron(),
    );
  }

  String _title(AppLocalizations l10n) {
    final brand = switch (recorder.brand) {
      RecorderBrand.hikvision => l10n.recorderBrandHikvision,
      RecorderBrand.dahua => l10n.recorderBrandDahua,
      RecorderBrand.xiongmai => l10n.recorderBrandXiongmai,
      RecorderBrand.onvif => l10n.recorderBrandOnvif,
      RecorderBrand.genericRtsp => l10n.recorderBrandGenericRtsp,
      RecorderBrand.auto => l10n.recorderFormTitle,
    };
    if (recorder.model.isEmpty) {
      return brand;
    }
    return '$brand · ${recorder.model}';
  }
}

class _TestSummary extends StatelessWidget {
  const _TestSummary({required this.result});

  final RecorderTestResult result;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!result.ok) {
      return PointyInlineMessage.error(
        message: result.error.isNotEmpty
            ? result.error
            : l10n.recorderTestFailedTitle,
      );
    }
    final online = result.channels.where((channel) => channel.online).length;
    final parts = <String>[
      if (result.brand.isNotEmpty) result.brand,
      if (result.model.isNotEmpty) result.model,
      '$online / ${result.channels.length}',
    ];
    return PointyInlineMessage.success(message: parts.join(' · '));
  }
}
