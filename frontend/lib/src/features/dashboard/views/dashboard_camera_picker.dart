import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/camera.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../view_models/dashboard_cameras_view_model.dart';

/// "Which of these do you want to see?"
///
/// A thumbnail per row, not just a name. A shop names its channels late (or
/// never), so "CAM 3" answers nothing and a still from the camera answers it
/// instantly — the same reason camera apps list rooms with a cover image rather
/// than a list of words.
Future<void> showDashboardCameraPicker(
  BuildContext context, {
  required DashboardCamerasViewModel viewModel,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _DashboardCameraPicker(viewModel: viewModel),
  );
}

class _DashboardCameraPicker extends StatefulWidget {
  const _DashboardCameraPicker({required this.viewModel});

  final DashboardCamerasViewModel viewModel;

  @override
  State<_DashboardCameraPicker> createState() => _DashboardCameraPickerState();
}

class _DashboardCameraPickerState extends State<_DashboardCameraPicker> {
  late Set<int> _selected = {
    for (final camera in widget.viewModel.visibleCameras) camera.id,
  };
  late bool _isAutomatic = !widget.viewModel.hasExplicitSelection;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cameras = widget.viewModel.cameras;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PointySectionHeader(
              title: l10n.dashboardCamerasPickerTitle,
              subtitle: l10n.dashboardCamerasPickerBody,
            ),
            const SizedBox(height: PointyDimensions.denseGap),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  SwitchListTile(
                    value: _isAutomatic,
                    onChanged: (value) {
                      setState(() {
                        _isAutomatic = value;
                        if (value) {
                          _selected = {
                            for (final camera in widget.viewModel.cameras.take(
                              DashboardCamerasViewModel.autoSelectionLimit,
                            ))
                              camera.id,
                          };
                        }
                      });
                    },
                    secondary: const Icon(Icons.auto_awesome_outlined),
                    title: Text(l10n.dashboardCamerasAutoLabel),
                    subtitle: Text(l10n.dashboardCamerasAutoDescription),
                  ),
                  const Divider(height: 1),
                  for (final camera in cameras)
                    CheckboxListTile(
                      value: _isAutomatic
                          ? widget.viewModel.visibleCameras.any(
                              (visible) => visible.id == camera.id,
                            )
                          : _selected.contains(camera.id),
                      // Locked while automatic is on: the switch above already
                      // says who is choosing, and a checkbox that silently
                      // overrides it would make that a lie.
                      onChanged: _isAutomatic
                          ? null
                          : (checked) {
                              setState(() {
                                if (checked == true) {
                                  _selected.add(camera.id);
                                } else {
                                  _selected.remove(camera.id);
                                }
                              });
                            },
                      secondary: _Thumbnail(
                        camera: camera,
                        viewModel: widget.viewModel,
                      ),
                      title: Text(camera.displayName),
                      subtitle: Text(
                        camera.coversCheckout
                            ? l10n.cameraSettingsCoversCheckoutLabel
                            : camera.recorderName,
                      ),
                    ),
                ],
              ),
            ),
            if (!_isAutomatic && _selected.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: PointyDimensions.denseGap),
                child: PointyInlineMessage(
                  message: l10n.dashboardCamerasNoneSelected,
                ),
              ),
            const SizedBox(height: PointyDimensions.sectionGap),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.cancelButton),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _apply,
                  child: Text(l10n.confirmButton),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _apply() async {
    final navigator = Navigator.of(context);
    if (_isAutomatic) {
      await widget.viewModel.resetSelection();
    } else {
      // Stored in the shop's own camera order, not in tick order, so the band
      // reads the same whichever way the boxes were checked.
      await widget.viewModel.select([
        for (final camera in widget.viewModel.cameras)
          if (_selected.contains(camera.id)) camera.id,
      ]);
    }
    navigator.pop();
  }
}

/// A still from the camera, fetched once.
///
/// Not a stream: this is a list of identities, and a dozen tiny live feeds to
/// answer "which one is the back door?" would cost more than the dashboard it
/// is configuring. A shop names its channels late or never, so `CAM 3` answers
/// nothing and a picture answers it instantly.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.camera, required this.viewModel});

  final Camera camera;
  final DashboardCamerasViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 64,
      height: 44,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        child: ColoredBox(
          color: theme.colorScheme.surfaceContainerHighest,
          child: FutureBuilder<Uint8List?>(
            future: viewModel.thumbnail(camera),
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              if (bytes != null && bytes.isNotEmpty) {
                return Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  // A camera that is reachable but sending a broken frame is
                  // still a camera worth listing.
                  errorBuilder: (context, _, _) => _fallback(theme),
                );
              }
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: PointySpinner(strokeWidth: 2),
                  ),
                );
              }
              return _fallback(theme);
            },
          ),
        ),
      ),
    );
  }

  Widget _fallback(ThemeData theme) {
    return Icon(
      camera.coversCheckout
          ? Icons.point_of_sale_outlined
          : Icons.videocam_outlined,
      size: 20,
      color: theme.colorScheme.onSurfaceVariant,
    );
  }
}
