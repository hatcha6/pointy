import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../shared/side_back.dart';
import '../links/cards_link.dart';

/// Shares an eSIM page's `cards.dftr.ly` link (the shelf as it is filtered, a
/// destination, one plan) through the phone's own share sheet, which a
/// messaging app then shows with the destination's picture. Where nothing can
/// share, the link is copied. [button] is the pressed button's own context: an
/// iPad's share sheet points at it.
Future<void> shareEsimLink(
  BuildContext button,
  EsimShelfLink link, {
  required String title,
}) async {
  final uri = link.uri;
  final messenger = ScaffoldMessenger.maybeOf(button);
  final copied = AppLocalizations.of(button).linkCopiedNotice;
  final box = button.findRenderObject() as RenderBox?;
  try {
    final result = await SharePlus.instance.share(
      ShareParams(
        uri: uri,
        title: title,
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
  await Clipboard.setData(ClipboardData(text: uri.toString()));
  messenger?.showSnackBar(SnackBar(content: Text(copied)));
}

/// The share button of an eSIM page's app bar. [link] is read when pressed, so
/// it carries what the page shows then.
class EsimShareButton extends StatelessWidget {
  const EsimShareButton({super.key, required this.link, required this.title});

  final EsimShelfLink Function() link;
  final String Function() title;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: AppLocalizations.of(context).shareAction,
    icon: const Icon(CupertinoIcons.share),
    onPressed: () => shareEsimLink(context, link(), title: title()),
  );

  /// The same button in the iPhone Duo's side column, under the back one.
  static SideAction side(
    BuildContext context, {
    required EsimShelfLink Function() link,
    required String Function() title,
  }) => SideAction(
    symbol: 'square.and.arrow.up',
    icon: CupertinoIcons.share,
    tooltip: AppLocalizations.of(context).shareAction,
    onPressed: (button) => shareEsimLink(button, link(), title: title()),
  );
}
