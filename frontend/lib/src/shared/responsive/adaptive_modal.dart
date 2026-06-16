import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../design/pointy_component_styles.dart';
import '../design/pointy_elevations.dart';
import '../design/pointy_motion.dart';
import '../design/pointy_theme_extensions.dart';
import 'adaptive_constraints.dart';
import 'app_breakpoints.dart';

enum AdaptiveModalSize { compact, standard, expanded }

class AdaptiveModalSizing {
  const AdaptiveModalSizing._();

  static double maxWidthFor(
    double availableWidth, {
    AdaptiveModalSize size = AdaptiveModalSize.standard,
  }) {
    if (availableWidth < AppBreakpoints.tabletMin) {
      return availableWidth;
    }

    final width = switch (size) {
      AdaptiveModalSize.compact => AppPaneWidths.standard,
      AdaptiveModalSize.standard => AppMaxContentWidths.form,
      AdaptiveModalSize.expanded => AppMaxContentWidths.detail,
    };

    return math.min(availableWidth, width);
  }

  static double maxHeightFactorForWidth(double width) {
    return switch (AppBreakpoints.forWidth(width)) {
      AppBreakpoint.phone => 0.94,
      AppBreakpoint.largePhone => 0.92,
      AppBreakpoint.tablet => 0.88,
      AppBreakpoint.desktop => 0.86,
      AppBreakpoint.widePos => 0.88,
    };
  }
}

class AdaptiveModalSheet extends StatelessWidget {
  const AdaptiveModalSheet({
    super.key,
    required this.child,
    this.size = AdaptiveModalSize.standard,
    this.maxWidth,
    this.maxHeight,
    this.maxHeightFactor,
  });

  final Widget child;
  final AdaptiveModalSize size;
  final double? maxWidth;
  final double? maxHeight;
  final double? maxHeightFactor;

  @override
  Widget build(BuildContext context) {
    final availableSize = MediaQuery.sizeOf(context);
    final resolvedMaxWidth =
        maxWidth ??
        AdaptiveModalSizing.maxWidthFor(availableSize.width, size: size);
    final resolvedMaxHeight =
        maxHeight ??
        availableSize.height *
            (maxHeightFactor ??
                AdaptiveModalSizing.maxHeightFactorForWidth(
                  availableSize.width,
                ));

    // heightFactor pins the Align to its child's height; without it the Align
    // fills the route's full height and the sheet surface is drawn behind all
    // of it, so even a three-field sheet covers the whole screen.
    return Align(
      alignment: AlignmentDirectional.bottomCenter,
      heightFactor: 1.0,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: resolvedMaxWidth,
          maxHeight: resolvedMaxHeight,
        ),
        child: child,
      ),
    );
  }
}

class AdaptiveDialogSurface extends StatelessWidget {
  const AdaptiveDialogSurface({
    super.key,
    required this.child,
    this.size = AdaptiveModalSize.standard,
    this.maxWidth,
    this.maxHeight,
    this.maxHeightFactor,
  });

  final Widget child;
  final AdaptiveModalSize size;
  final double? maxWidth;
  final double? maxHeight;
  final double? maxHeightFactor;

  @override
  Widget build(BuildContext context) {
    final availableSize = MediaQuery.sizeOf(context);
    final resolvedMaxWidth =
        maxWidth ??
        AdaptiveModalSizing.maxWidthFor(availableSize.width, size: size);
    final resolvedMaxHeight =
        maxHeight ??
        availableSize.height *
            (maxHeightFactor ??
                AdaptiveModalSizing.maxHeightFactorForWidth(
                  availableSize.width,
                ));

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: resolvedMaxWidth,
          maxHeight: resolvedMaxHeight,
        ),
        child: child,
      ),
    );
  }
}

Future<T?> showAdaptiveModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  AdaptiveModalSize size = AdaptiveModalSize.standard,
  double? maxWidth,
  double? maxHeight,
  double? maxHeightFactor,
  bool isScrollControlled = true,
  bool useSafeArea = true,
  bool showDragHandle = true,
  bool enableDrag = true,
  bool isDismissible = true,
  Color? backgroundColor,
  ShapeBorder? shape,
  Clip? clipBehavior,
  RouteSettings? routeSettings,
}) {
  final availableWidth = MediaQuery.sizeOf(context).width;
  final resolvedMaxWidth =
      maxWidth ?? AdaptiveModalSizing.maxWidthFor(availableWidth, size: size);

  return showModalBottomSheet<T>(
    context: context,
    constraints: BoxConstraints(maxWidth: resolvedMaxWidth),
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    showDragHandle: showDragHandle,
    enableDrag: enableDrag,
    isDismissible: isDismissible,
    backgroundColor: backgroundColor,
    shape: shape,
    clipBehavior: clipBehavior,
    routeSettings: routeSettings,
    builder: (sheetContext) {
      return AdaptiveModalSheet(
        size: size,
        maxWidth: resolvedMaxWidth,
        maxHeight: maxHeight,
        maxHeightFactor: maxHeightFactor,
        child: builder(sheetContext),
      );
    },
  );
}

/// How a form surface presents at desktop widths and above.
enum AdaptiveFormPresentation { dialog, sidePanel }

/// Title row used by form surfaces that have no drag handle: dialogs and
/// side panels need an explicit close affordance.
class AdaptiveFormSurfaceHeader extends StatelessWidget {
  const AdaptiveFormSurfaceHeader({
    super.key,
    required this.title,
    this.trailing,
    this.onClose,
  });

  final String title;
  final Widget? trailing;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 12, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          ?trailing,
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: l10n.closeButton,
            onPressed: onClose ?? () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}

class _FormSurfaceContent extends StatelessWidget {
  const _FormSurfaceContent({required this.title, required this.child});

  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (title == null) {
      return child;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdaptiveFormSurfaceHeader(title: title!),
        Flexible(child: child),
      ],
    );
  }
}

/// Shows a create/edit form on the surface that fits the viewport: a bottom
/// sheet below desktop widths, and a centered dialog or an end-anchored side
/// panel at desktop widths so forms stop consuming full-screen height on POS
/// terminals.
///
/// Transient pickers should keep using [showAdaptiveModalBottomSheet]; this
/// entry point is for forms.
Future<T?> showAdaptiveFormSurface<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  AdaptiveModalSize size = AdaptiveModalSize.standard,
  AdaptiveFormPresentation desktopPresentation =
      AdaptiveFormPresentation.dialog,
  String? title,
  bool isDismissible = true,
  double? maxWidth,
  double? maxHeight,
  double? maxHeightFactor,
  double desktopBreakpoint = AppBreakpoints.desktopMin,
  RouteSettings? routeSettings,
}) {
  final width = MediaQuery.sizeOf(context).width;
  if (width < desktopBreakpoint) {
    return showAdaptiveModalBottomSheet<T>(
      context: context,
      size: size,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      maxHeightFactor: maxHeightFactor,
      isDismissible: isDismissible,
      enableDrag: isDismissible,
      routeSettings: routeSettings,
      builder: (sheetContext) =>
          _FormSurfaceContent(title: title, child: builder(sheetContext)),
    );
  }

  final theme = Theme.of(context);
  final barrierColor =
      theme.bottomSheetTheme.modalBarrierColor ?? Colors.black54;

  if (desktopPresentation == AdaptiveFormPresentation.dialog) {
    return showDialog<T>(
      context: context,
      barrierDismissible: isDismissible,
      barrierColor: barrierColor,
      routeSettings: routeSettings,
      builder: (dialogContext) {
        return AdaptiveDialogSurface(
          size: size,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          maxHeightFactor: maxHeightFactor,
          child: Material(
            color: theme.pointyColors.surface,
            shape: PointyComponentStyles.shape(PointyRadii.dialog),
            clipBehavior: Clip.antiAlias,
            child: _FormSurfaceContent(
              title: title,
              child: builder(dialogContext),
            ),
          ),
        );
      },
    );
  }

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: isDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: barrierColor,
    transitionDuration: PointyMotion.standard,
    routeSettings: routeSettings,
    pageBuilder: (panelContext, animation, secondaryAnimation) {
      final availableSize = MediaQuery.sizeOf(panelContext);
      final panelWidth = math.min(
        maxWidth ??
            AdaptiveModalSizing.maxWidthFor(availableSize.width, size: size),
        availableSize.width * 0.5,
      );

      return Padding(
        padding: MediaQuery.viewInsetsOf(panelContext),
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: DecoratedBox(
            decoration: const BoxDecoration(boxShadow: PointyShadows.overlay),
            child: SizedBox(
              width: panelWidth,
              height: double.infinity,
              child: Material(
                color: theme.pointyColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadiusDirectional.horizontal(
                    start: Radius.circular(PointyRadii.dialog),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: SafeArea(
                  child: _FormSurfaceContent(
                    title: title,
                    child: builder(panelContext),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder:
        (transitionContext, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: PointyMotion.curve,
          );
          final isRtl =
              Directionality.of(transitionContext) == TextDirection.rtl;

          return SlideTransition(
            position: Tween<Offset>(
              begin: Offset(isRtl ? -1 : 1, 0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          );
        },
  );
}
