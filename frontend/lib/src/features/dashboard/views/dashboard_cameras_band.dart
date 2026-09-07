import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/camera.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../cameras/widgets/camera_tile.dart';
import '../view_models/dashboard_cameras_view_model.dart';
import 'dashboard_camera_picker.dart';

/// The live cameras band: the part of the dashboard that moves.
///
/// A full-width strip rather than one card in the masonry grid, because video
/// wants width — a camera squeezed into a third of a column is a thumbnail, and
/// a thumbnail is not the point. It sits directly under the headline numbers,
/// where "how is the shop doing" is naturally followed by "and what does it
/// look like right now".
///
/// It disappears entirely when there is nothing to show: no cameras, no
/// permission, or a deliberate empty selection. A dashboard with a hole labelled
/// "cameras" in it is worse than a dashboard without cameras.
class DashboardCamerasBand extends StatefulWidget {
  const DashboardCamerasBand({
    super.key,
    required this.viewModel,
    this.onOpenCamera,
    this.onOpenWall,
  });

  final DashboardCamerasViewModel viewModel;

  /// Tapping a tile. The dashboard shows stills; watching properly happens in
  /// the full-screen player, which is one tap away rather than always running.
  final ValueChanged<Camera>? onOpenCamera;
  final VoidCallback? onOpenWall;

  @override
  State<DashboardCamerasBand> createState() => _DashboardCamerasBandState();
}

class _DashboardCamerasBandState extends State<DashboardCamerasBand> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.viewModel.hasLoaded) {
        unawaited(widget.viewModel.load());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final viewModel = widget.viewModel;
        // Nothing at all until we know — no skeleton, no reserved space. The
        // band is optional furniture, and reserving room for furniture that may
        // never arrive makes the whole dashboard jump on load.
        if (!viewModel.hasLoaded || !viewModel.isVisible) {
          return const SizedBox.shrink();
        }
        final l10n = AppLocalizations.of(context)!;
        final cameras = viewModel.visibleCameras;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: PointySectionHeader(
                    title: l10n.dashboardCamerasTitle,
                    leading: const Icon(Icons.videocam_outlined),
                  ),
                ),
                if (widget.onOpenWall != null)
                  TextButton(
                    onPressed: widget.onOpenWall,
                    child: Text(l10n.dashboardCamerasOpenWallAction),
                  ),
                IconButton(
                  tooltip: l10n.dashboardCamerasChooseTooltip,
                  onPressed: () => unawaited(_choose(context)),
                  icon: const Icon(Icons.tune),
                ),
              ],
            ),
            const SizedBox(height: PointyDimensions.denseGap),
            _Strip(
              cameras: cameras,
              viewModel: viewModel,
              onOpenCamera: widget.onOpenCamera,
            ),
          ],
        );
      },
    );
  }

  Future<void> _choose(BuildContext context) async {
    await showDashboardCameraPicker(context, viewModel: widget.viewModel);
  }
}

class _Strip extends StatelessWidget {
  const _Strip({
    required this.cameras,
    required this.viewModel,
    required this.onOpenCamera,
  });

  final List<Camera> cameras;
  final DashboardCamerasViewModel viewModel;
  final ValueChanged<Camera>? onOpenCamera;

  /// Below this the tiles stop fitting side by side and become a scrolling
  /// strip instead of three stacked squares eating the whole phone screen.
  static const double _rowBreakpoint = 720;
  static const double _gap = 8;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final ratio = MediaQuery.devicePixelRatioOf(context);
        final wide = constraints.maxWidth >= _rowBreakpoint;

        if (wide) {
          final tileWidth =
              (constraints.maxWidth - _gap * (cameras.length - 1)) /
              cameras.length;
          return SizedBox(
            height: tileWidth / (16 / 9),
            child: Row(
              children: [
                for (var index = 0; index < cameras.length; index++) ...[
                  if (index > 0) const SizedBox(width: _gap),
                  Expanded(
                    child: _tile(cameras[index], (tileWidth * ratio).round()),
                  ),
                ],
              ],
            ),
          );
        }

        // Peeking the next tile is what tells a phone user the strip scrolls.
        final tileWidth = constraints.maxWidth * 0.82;
        return SizedBox(
          height: tileWidth / (16 / 9),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            // Same rule as the camera wall: a tile off screen is a camera the
            // recorder should stop being asked for.
            cacheExtent: 0,
            itemCount: cameras.length,
            separatorBuilder: (_, _) => const SizedBox(width: _gap),
            itemBuilder: (context, index) => SizedBox(
              width: tileWidth,
              child: _tile(cameras[index], (tileWidth * ratio).round()),
            ),
          ),
        );
      },
    );
  }

  Widget _tile(Camera camera, int tileWidth) {
    return CameraTile(
      key: ValueKey('dashboard-camera-${camera.id}'),
      camera: camera,
      // No per-tile buttons here: the dashboard is a glance, and everything a
      // tile could offer lives one tap away in the player.
      compact: true,
      frames: () => viewModel.frames(camera, tileWidth: tileWidth),
      onOpen: onOpenCamera == null ? null : () => onOpenCamera!(camera),
    );
  }
}
