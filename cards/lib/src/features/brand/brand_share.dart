import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/analytics/events.dart';
import '../../data/models/catalog.dart';
import '../../design/cards_tokens.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../shared/cards_scope.dart';
import '../../shared/side_back.dart';
import '../links/cards_link.dart';

/// The brand page's share button, beside its back button: the brand's
/// `cards.dftr.ly` link through the phone's own share sheet, which a
/// messaging app then shows with the brand's picture. Apple's share mark
/// (a box, an arrow out of its top) on every platform.
class BrandShareButton extends StatelessWidget {
  const BrandShareButton({super.key, required this.brand, this.item});

  final CardBrand brand;

  /// The card on show, so the link opens on it.
  final CardItem? item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(CardsSpace.sm),
      child: Material(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
        shape: const CircleBorder(),
        child: Builder(
          // Its own context: an iPad's share sheet points at this button.
          builder: (context) => IconButton(
            tooltip: AppLocalizations.of(context).shareAction,
            onPressed: () => shareBrand(context, brand, item),
            icon: const Icon(CupertinoIcons.share),
          ),
        ),
      ),
    );
  }

  /// The same button in the iPhone Duo's side column, under the back one.
  static SideAction side(
    BuildContext context,
    CardBrand brand,
    CardItem? item,
  ) => SideAction(
    symbol: 'square.and.arrow.up',
    icon: CupertinoIcons.share,
    tooltip: AppLocalizations.of(context).shareAction,
    onPressed: (button) => shareBrand(button, brand, item),
  );
}

/// Shares [brand]'s link (on [item]) from the button whose context is
/// [context]; copies it where there is no share sheet.
Future<void> shareBrand(
  BuildContext context,
  CardBrand brand,
  CardItem? item,
) async {
  final link = BrandLink(brand.key, item: item?.key).uri;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final copied = AppLocalizations.of(context).linkCopiedNotice;
  CardsScope.of(context).analytics.brandShared(brand);
  final box = context.findRenderObject() as RenderBox?;
  try {
    final result = await SharePlus.instance.share(
      ShareParams(
        uri: link,
        title: brand.name,
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
    if (result.status != ShareResultStatus.unavailable) {
      return;
    }
  } catch (error) {
    // A browser without a share sheet (most desktops): the link is copied.
    debugPrint('share: $error');
  }
  await Clipboard.setData(ClipboardData(text: link.toString()));
  messenger?.showSnackBar(SnackBar(content: Text(copied)));
}
