import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/unit_photo.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/product_image_thumbnail.dart';
import '../../../shared/product_image_viewer.dart';

/// An article's photos as a strip of small server-made thumbnails, cover first.
///
/// Tapping one opens the shared full-screen viewer on the full photos, so the
/// strip costs a few kilobytes per tile and only the photo somebody actually
/// looks at is fetched in full. Adding, choosing the cover and removing are
/// offered only to whoever may manage photos; everybody who can see the unit
/// can see its pictures.
class UnitPhotosSection extends StatelessWidget {
  const UnitPhotosSection({
    super.key,
    required this.photos,
    required this.title,
    required this.canManage,
    required this.onAddFiles,
    required this.onMakeCover,
    required this.onDelete,
    this.onCapture,
    this.isUploading = false,
    this.uploadDone = 0,
    this.uploadTotal = 0,
    this.uploadProgress = 0,
    this.loadFailed = false,
  });

  final List<UnitPhoto> photos;

  /// What the viewer's header says — the article's name.
  final String title;
  final bool canManage;
  final VoidCallback onAddFiles;

  /// Null where the platform has no camera.
  final VoidCallback? onCapture;
  final ValueChanged<UnitPhoto> onMakeCover;
  final ValueChanged<UnitPhoto> onDelete;
  final bool isUploading;
  final int uploadDone;
  final int uploadTotal;
  final double uploadProgress;
  final bool loadFailed;

  static const double tileSize = 96;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;

    return PointyDetailSection(
      title: l10n.unitPhotosSection,
      icon: Icons.photo_library_outlined,
      trailing: canManage
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onCapture != null)
                  IconButton(
                    tooltip: l10n.unitPhotosCamera,
                    onPressed: isUploading ? null : onCapture,
                    icon: const Icon(Icons.photo_camera_outlined),
                  ),
                IconButton(
                  key: const ValueKey('unit-photos-add'),
                  tooltip: l10n.unitPhotosAdd,
                  onPressed: isUploading ? null : onAddFiles,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                ),
              ],
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (loadFailed && photos.isEmpty)
            PointyInlineMessage.error(
              message: l10n.unitPhotosLoadFailed,
              compact: true,
            )
          else if (photos.isEmpty && !isUploading)
            Text(
              l10n.unitPhotosEmpty,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.mutedInk,
              ),
            )
          else
            SizedBox(
              height: tileSize,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: photos.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) => _PhotoTile(
                  photo: photos[index],
                  fallback: title,
                  canManage: canManage && !isUploading,
                  onOpen: () => showProductImageViewer(
                    context,
                    imageUrls: [for (final photo in photos) photo.contentUrl],
                    initialIndex: index,
                    title: title,
                  ),
                  onMakeCover: () => onMakeCover(photos[index]),
                  onDelete: () => onDelete(photos[index]),
                ),
              ),
            ),
          if (isUploading) ...[
            const SizedBox(height: 10),
            PointyProgressBar(
              value: uploadProgress,
              minHeight: 4,
              borderRadius: BorderRadius.circular(PointyRadii.pill),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.unitPhotoUploading(
                (uploadDone + 1).clamp(1, uploadTotal),
                uploadTotal,
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    required this.photo,
    required this.fallback,
    required this.canManage,
    required this.onOpen,
    required this.onMakeCover,
    required this.onDelete,
  });

  final UnitPhoto photo;
  final String fallback;
  final bool canManage;
  final VoidCallback onOpen;
  final VoidCallback onMakeCover;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context);

    return SizedBox.square(
      dimension: UnitPhotosSection.tileSize,
      child: Stack(
        children: [
          Positioned.fill(
            child: Tooltip(
              message: l10n.unitPhotoOpenTooltip,
              child: InkWell(
                borderRadius: BorderRadius.circular(PointyRadii.card),
                onTap: onOpen,
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(PointyRadii.card),
                    border: Border.all(
                      color: photo.isCover ? colors.primaryStrong : colors.line,
                      width: photo.isCover ? 2 : 1,
                    ),
                  ),
                  child: ProductImageThumbnail(
                    imageUrl: photo.previewUrl,
                    fallbackText: fallback,
                    size: UnitPhotosSection.tileSize,
                    borderRadius: PointyRadii.card,
                  ),
                ),
              ),
            ),
          ),
          if (photo.isCover)
            PositionedDirectional(
              top: 4,
              start: 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.primaryStrong,
                  borderRadius: BorderRadius.circular(PointyRadii.pill),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  child: Text(
                    l10n.unitPhotoCoverBadge,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: PointyColors.surface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          if (canManage)
            PositionedDirectional(
              bottom: 2,
              end: 2,
              child: Material(
                color: colors.surface.withValues(alpha: 0.88),
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: PopupMenuButton<_PhotoAction>(
                  tooltip: l10n.unitPhotoOptionsTooltip,
                  iconSize: 16,
                  padding: EdgeInsets.zero,
                  // Small, so it marks a corner of the photo instead of
                  // covering it; the whole tile is still the tap target
                  // for opening it.
                  style: IconButton.styleFrom(
                    minimumSize: const Size(32, 32),
                    fixedSize: const Size(32, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: EdgeInsets.zero,
                  ),
                  constraints: const BoxConstraints(minWidth: 180),
                  icon: Icon(Icons.more_horiz, color: colors.ink),
                  onSelected: (action) => switch (action) {
                    _PhotoAction.cover => onMakeCover(),
                    _PhotoAction.delete => onDelete(),
                  },
                  itemBuilder: (context) => [
                    if (!photo.isCover)
                      PopupMenuItem(
                        value: _PhotoAction.cover,
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.star_outline),
                          title: Text(l10n.unitPhotoMakeCover),
                        ),
                      ),
                    PopupMenuItem(
                      value: _PhotoAction.delete,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.delete_outline,
                          color: colors.danger,
                        ),
                        title: Text(
                          l10n.unitPhotoDelete,
                          style: TextStyle(color: colors.danger),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

enum _PhotoAction { cover, delete }
