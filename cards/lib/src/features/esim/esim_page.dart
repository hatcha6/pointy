import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../core/esim/esim_device.dart';
import '../../core/result.dart';
import '../../data/models/esim.dart';
import '../../data/models/order.dart';
import '../../design/cards_layout.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/empty_state.dart';
import '../../shared/esim_card_art.dart';
import '../../shared/grouped.dart';
import '../../shared/haptics.dart';
import '../../shared/relay_error_text.dart';
import '../../shared/side_back.dart';
import '../../shared/skeleton.dart';
import 'esim_destination_page.dart';
import 'esim_format.dart';
import 'esim_install_panel.dart';
import 'esim_installed_store.dart';
import 'esim_page_mode.dart';
import 'esim_split.dart';
import 'esim_topups.dart';
import 'esim_usage_card.dart';

/// One eSIM, from the moment it is bought: a ticket with one thing to do, pinned
/// at the bottom. Install it, send it to whoever it is for, or top it up.
class EsimPage extends StatefulWidget {
  const EsimPage({super.key, this.iccid, this.orderId, this.justBought = false})
    : assert(iccid != null || orderId != null);

  final String? iccid;

  /// A delivered order's eSIM, when its number is not known yet.
  final String? orderId;

  /// Arrived straight from paying: the page greets it.
  final bool justBought;

  static const screen = 'esim';

  static Future<void> open(BuildContext context, String iccid) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: screenSettings(screen),
          builder: (_) => EsimPage(iccid: iccid),
        ),
      );

  /// A paid order delivered its eSIM: this page takes the order's place.
  static Future<void> openDelivered(
    BuildContext context,
    CardOrder order, {
    bool replace = false,
    bool fresh = false,
  }) {
    final topUpOf = EsimItems.topUpIccid(order.itemKey);
    if (topUpOf != null) {
      return afterTopUp(context, topUpOf);
    }
    CardsScope.of(context).esim.changes.value++;
    final route = MaterialPageRoute<void>(
      settings: screenSettings(screen),
      builder: (_) => EsimPage(orderId: order.id, justBought: fresh || replace),
    );
    final navigator = Navigator.of(context);
    return replace ? navigator.pushReplacement(route) : navigator.push(route);
  }

  /// A top-up arrived: back to its eSIM's page, which reads it afresh.
  static Future<void> afterTopUp(BuildContext context, String iccid) async {
    final dependencies = CardsScope.of(context);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final done = AppLocalizations.of(context).esimTopUpDone;
    Haptics.success();
    dependencies.esim.changes.value++;
    var found = false;
    navigator.popUntil((route) {
      final name = route.settings.arguments;
      found = name is ScreenName && name.name == screen;
      return found || route.isFirst;
    });
    if (!found) {
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            settings: screenSettings(screen),
            builder: (_) => EsimPage(iccid: iccid),
          ),
        ),
      );
    }
    messenger?.showSnackBar(SnackBar(content: Text(done)));
  }

  @override
  State<EsimPage> createState() => _EsimPageState();
}

class _EsimPageState extends State<EsimPage> with WidgetsBindingObserver {
  CustomerEsim? _esim;
  Object? _error;
  bool _started = false;
  bool _confirmed = false;
  bool _sent = false;

  /// The customer just said it is installed: the setup steps start open.
  bool _justConfirmed = false;

  /// The system's install sheet is open: the customer's return is the moment
  /// to ask how it went.
  bool _awaitingReturn = false;
  bool _installFailed = false;
  bool _showAlternatives = false;
  final _alternatives = GlobalKey();
  ValueNotifier<int>? _changes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      final dependencies = CardsScope.of(context);
      dependencies.esimCompatibility.load();
      _changes = dependencies.esim.changes..addListener(_load);
      _load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _changes?.removeListener(_load);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _awaitingReturn) {
      _awaitingReturn = false;
      unawaited(_askHowItWent());
    }
  }

  EsimInstalledStore get _store =>
      EsimInstalledStore(CardsScope.of(context).preferences);

  EsimDeviceFacts get _facts => CardsScope.of(context).esimCompatibility.facts;

  Future<void> _load() async {
    final dependencies = CardsScope.of(context);
    final store = _store;
    var iccid = widget.iccid ?? _esim?.iccid;
    if (iccid == null) {
      // The row is written before the order is told delivered.
      final found = await dependencies.esim.esimOfOrder(widget.orderId!);
      switch (found) {
        case Ok(:final value):
          iccid = value?.iccid;
        case Error(:final exception):
          if (mounted) {
            setState(() => _error = exception);
          }
          return;
      }
      if (iccid == null) {
        if (mounted) {
          setState(() => _error = StateError('no eSIM on this order'));
        }
        return;
      }
    }
    final result = await dependencies.esim.esim(iccid);
    final confirmed = await store.isInstalled(iccid);
    final sent = await store.wasSent(iccid);
    if (!mounted) {
      return;
    }
    setState(() {
      _confirmed = confirmed;
      _sent = sent;
      switch (result) {
        case Ok(:final value):
          _esim = value;
          _error = null;
        case Error(:final exception):
          _error = exception;
      }
    });
  }

  /// The install link for this phone; null when it has none that can open.
  String? _directUrl(EsimInstall? install) {
    final facts = _facts;
    if (install == null || !facts.directInstall) {
      return null;
    }
    final url = facts.isIos ? install.appleUrl : install.androidUrl;
    return url.isEmpty ? null : url;
  }

  Future<void> _installNow(String url) async {
    Haptics.tap();
    final device = CardsScope.of(context).esimCompatibility.device;
    _awaitingReturn = true;
    final opened = await device.install(url);
    if (!opened && mounted) {
      _awaitingReturn = false;
      Haptics.warning();
      setState(() {
        _installFailed = true;
        _showAlternatives = true;
      });
      _revealAlternatives();
    }
  }

  void _openAlternatives() {
    setState(() => _showAlternatives = true);
    _revealAlternatives();
  }

  void _revealAlternatives() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _alternatives.currentContext;
      if (target != null && target.mounted) {
        Scrollable.ensureVisible(target, duration: CardsMotion.standard);
      }
    });
  }

  Future<void> _askHowItWent() async {
    if (!mounted) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final worked = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.esimInstallAskTitle),
        content: Text(l10n.esimInstallAskBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.esimInstallAskNo),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.esimInstallAskYes),
          ),
        ],
      ),
    );
    if (!mounted || worked == null) {
      return;
    }
    if (worked) {
      await _markInstalled();
    } else {
      _openAlternatives();
    }
  }

  Future<void> _markInstalled() async {
    final esim = _esim;
    if (esim == null) {
      return;
    }
    Haptics.success();
    await _store.setInstalled(esim.iccid, true);
    if (mounted) {
      setState(() {
        _confirmed = true;
        _justConfirmed = true;
      });
    }
  }

  Future<void> _showInstallAgain() async {
    final esim = _esim;
    if (esim == null) {
      return;
    }
    await _store.setInstalled(esim.iccid, false);
    if (mounted) {
      setState(() {
        _confirmed = false;
        _showAlternatives = true;
      });
    }
  }

  /// A name for the eSIM: asked once before sending when it has none, or from
  /// the pencil. Null when backed out of; empty when left blank.
  Future<String?> _askName(CustomerEsim esim, String title, String action) {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController(text: esim.label);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          decoration: InputDecoration(labelText: l10n.esimRecipientName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.esimCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(action),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _saveName(CustomerEsim esim, String label) async {
    final l10n = AppLocalizations.of(context);
    final result = await CardsScope.of(context).esim.rename(esim.iccid, label);
    if (!mounted) {
      return;
    }
    if (result case Error(:final exception)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(relayErrorText(l10n, exception))));
    }
  }

  Future<void> _rename(CustomerEsim esim) async {
    final l10n = AppLocalizations.of(context);
    final label = await _askName(esim, l10n.esimRenameTitle, l10n.esimSave);
    if (label != null && mounted) {
      await _saveName(esim, label);
    }
  }

  Future<void> _send(
    BuildContext button,
    CustomerEsim esim,
    EsimInstall install,
  ) async {
    Haptics.tap();
    final l10n = AppLocalizations.of(context);
    var name = esim.label;
    if (name.isEmpty) {
      final typed = await _askName(
        esim,
        l10n.esimWhoForTitle,
        l10n.esimContinue,
      );
      if (typed == null || !mounted) {
        return;
      }
      name = typed;
      if (name.isNotEmpty) {
        await _saveName(esim, name);
      }
    }
    if (!button.mounted) {
      return;
    }
    final box = button.findRenderObject() as RenderBox?;
    final store = _store;
    final shared = await SharePlus.instance.share(
      ShareParams(
        text: l10n.esimShareText(
          esim.destinationName,
          esimPlanText(
            l10n,
            data: esim.data,
            days: esim.days,
            unlimited: esim.unlimited,
          ),
          install.shareLink,
          install.shareCode,
        ),
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
    if (shared.status == ShareResultStatus.success) {
      await store.setSent(esim.iccid, true);
      if (mounted) {
        setState(() => _sent = true);
      }
    }
  }

  void _buyAnother(CustomerEsim esim) => EsimDestinationPage.open(
    context,
    esim.destination,
    name: esim.destinationName,
  );

  void _topUp(CustomerEsim esim) {
    Haptics.tap();
    if (esim.rechargeable) {
      showEsimTopUpSheet(context, esim);
    } else {
      _buyAnother(esim);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final esim = _esim;
    return ValueListenableBuilder(
      valueListenable: CardsScope.of(context).esimCompatibility.support,
      builder: (context, support, _) {
        final mode = esim == null
            ? null
            : esimPageMode(
                esim: esim,
                confirmedInstalled: _confirmed,
                support: support,
                now: DateTime.now(),
              );
        final wide = EsimSplit.of(context);
        final side = SideBack.active(context);
        return SideBack(
          actions: [
            if (esim != null)
              SideAction(
                symbol: 'pencil',
                icon: Icons.edit_outlined,
                tooltip: l10n.esimRenameTitle,
                onPressed: (_) => _rename(esim),
              ),
          ],
          child: Scaffold(
            appBar: AppBar(
              title: Text(esim?.destinationName ?? ''),
              automaticallyImplyLeading: !side,
              actions: [
                if (esim != null && !side)
                  IconButton(
                    tooltip: l10n.esimRenameTitle,
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _rename(esim),
                  ),
              ],
            ),
            // Its own context: under SideBack, where the side column is
            // already off the width.
            bottomNavigationBar: esim == null || mode == null || wide
                ? null
                : Builder(builder: (context) => _action(context, esim, mode)),
            body: Builder(
              builder: (context) {
                final padding = CardsLayout.page(
                  context,
                  top: CardsSpace.sm,
                  bottom: CardsSpace.xl,
                );
                if (esim == null || mode == null) {
                  return _error != null
                      ? EmptyState(
                          icon: Icons.cloud_off_rounded,
                          title: l10n.esimLoadFailed,
                          body: relayErrorText(l10n, _error!),
                          actionLabel: l10n.esimTryAgain,
                          onAction: _load,
                        )
                      : ListView(
                          padding: padding,
                          children: const [
                            Skeleton(height: 148, radius: CardsRadii.card),
                            SizedBox(height: CardsSpace.lg),
                            Skeleton(height: 120, radius: CardsRadii.card),
                          ],
                        );
                }
                final sections = _sections(context, esim, mode);
                if (wide) {
                  return EsimSplit(
                    start: Builder(
                      builder: (context) => Column(
                        children: [
                          Padding(
                            padding: CardsLayout.page(
                              context,
                              top: CardsSpace.sm,
                            ),
                            child: sections.first,
                          ),
                          const Spacer(),
                          _action(context, esim, mode),
                        ],
                      ),
                    ),
                    end: RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(
                          CardsSpace.gutter,
                          0,
                          CardsSpace.gutter,
                          CardsSpace.xl,
                        ),
                        children: sections.skip(1).toList(),
                      ),
                    ),
                  );
                }
                return RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: padding, children: sections),
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// The one main action, pinned where a thumb rests.
  Widget _action(BuildContext context, CustomerEsim esim, EsimPageMode mode) {
    final l10n = AppLocalizations.of(context);
    final install = esim.install;
    Widget button(IconData icon, String label, VoidCallback onPressed) =>
        FilledButton.icon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
        );
    final Widget child;
    switch (mode) {
      case EsimPageMode.ended:
        child = button(
          Icons.add_rounded,
          l10n.esimBuyAnother,
          () => _buyAnother(esim),
        );
      case EsimPageMode.low:
        child = button(
          Icons.bolt_rounded,
          esim.rechargeable ? l10n.esimTopUpNow : l10n.esimBuyAnother,
          () => _topUp(esim),
        );
      case EsimPageMode.active:
        child = button(
          Icons.add_rounded,
          esim.rechargeable ? l10n.esimTopUpAction : l10n.esimBuyAnother,
          () => _topUp(esim),
        );
      case EsimPageMode.send
          when install != null && install.shareLink.isNotEmpty:
        child = Builder(
          // Its own context: an iPad's share sheet points at this button.
          builder: (context) => button(
            Icons.send_rounded,
            _sent
                ? l10n.esimSendAgain
                : esim.label.isEmpty
                ? l10n.esimSendNow
                : l10n.esimSendToName(esim.label),
            () => _send(context, esim, install),
          ),
        );
      case EsimPageMode.send:
      case EsimPageMode.install:
        final url = _directUrl(install);
        child = install == null
            ? button(Icons.refresh_rounded, l10n.esimTryAgain, _load)
            : url == null
            // Nothing to tap on this phone: the QR is on the page.
            ? button(
                Icons.check_rounded,
                l10n.esimAlreadyInstalled,
                _markInstalled,
              )
            : button(
                Icons.download_rounded,
                l10n.esimInstallAction,
                () => _installNow(url),
              );
    }
    final page = CardsLayout.page(context, top: 0);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          page.left,
          CardsSpace.sm,
          page.right,
          CardsSpace.md,
        ),
        child: child,
      ),
    );
  }

  List<Widget> _sections(
    BuildContext context,
    CustomerEsim esim,
    EsimPageMode mode,
  ) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final install = esim.install;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final plan = esimPlanText(
      l10n,
      data: esim.data,
      days: esim.days,
      unlimited: esim.unlimited,
    );
    final named = esim.gift && esim.label.isNotEmpty;
    Widget heading(String title, String body) => Padding(
      padding: const EdgeInsets.only(top: CardsSpace.lg, bottom: CardsSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.headlineSmall),
          const SizedBox(height: CardsSpace.xs),
          Text(body, style: muted),
        ],
      ),
    );
    final hero = EsimHero(
      kicker: !esim.gift
          ? ''
          : named
          ? l10n.esimGiftTo
          : l10n.esimGiftKicker,
      name: named ? esim.label : esim.destinationName,
      country: esim.country,
      caption: named ? '${esim.destinationName} · $plan' : plan,
      height: EsimSplit.of(context) ? 220 : 164,
    );
    final canInstallHere = _directUrl(install) != null;
    final alternativesOpen = _showAlternatives || !canInstallHere;
    final alternatives = install == null || !alternativesOpen
        ? null
        : KeyedSubtree(
            key: _alternatives,
            child: EsimInstallAlternatives(install: install, facts: _facts),
          );
    final unreadable = install == null
        ? Padding(
            padding: const EdgeInsets.only(bottom: CardsSpace.lg),
            child: EsimNote(
              icon: Icons.cloud_off_rounded,
              text: l10n.esimInstallUnreadable,
            ),
          )
        : null;
    final details = Grouped(
      title: l10n.esimDetailsTitle,
      children: [
        EsimCopyRow(label: l10n.esimNumber, value: esim.iccid),
        EsimActionRow(
          icon: Icons.support_agent_rounded,
          label: l10n.esimHelp,
          onTap: () => launchUrl(
            Uri.parse('mailto:support@dftr.ly?subject=eSIM%20${esim.iccid}'),
            mode: LaunchMode.externalApplication,
          ),
        ),
      ],
    );
    const gap = SizedBox(height: CardsSpace.xl);
    switch (mode) {
      case EsimPageMode.install:
        return [
          hero,
          heading(
            widget.justBought ? l10n.esimReadyTitle : l10n.esimOneStepTitle,
            canInstallHere ? l10n.esimReadyBody : l10n.esimScanBody,
          ),
          ?unreadable,
          EsimNote(icon: Icons.wifi_rounded, text: l10n.esimNeedsInternetNote),
          const SizedBox(height: CardsSpace.sm),
          EsimNote(
            icon: Icons.smartphone_rounded,
            text: l10n.esimOneDeviceNote,
          ),
          if (_installFailed) ...[
            const SizedBox(height: CardsSpace.sm),
            EsimNote(
              icon: Icons.info_rounded,
              color: theme.colorScheme.error,
              text: l10n.esimInstallFailedNote,
            ),
          ],
          gap,
          ?alternatives,
          if (alternatives != null) gap,
          Grouped(
            children: [
              if (canInstallHere && !alternativesOpen)
                EsimActionRow(
                  icon: Icons.qr_code_rounded,
                  label: l10n.esimOtherWays,
                  onTap: _openAlternatives,
                ),
              if (install != null && install.shareLink.isNotEmpty)
                Builder(
                  builder: (context) => EsimActionRow(
                    icon: Icons.send_rounded,
                    label: l10n.esimSendTo,
                    onTap: () => _send(context, esim, install),
                  ),
                ),
              if (canInstallHere)
                EsimActionRow(
                  icon: Icons.check_circle_outline_rounded,
                  label: l10n.esimAlreadyInstalled,
                  onTap: _markInstalled,
                ),
            ],
          ),
          gap,
          details,
        ];
      case EsimPageMode.send:
        return [
          hero,
          heading(
            esim.gift
                ? (named ? l10n.esimSendToName(esim.label) : l10n.esimSendNow)
                : l10n.esimPhoneNotSupported,
            _sent
                ? l10n.esimSentBody
                : esim.gift
                ? l10n.esimSendBody
                : l10n.esimPhoneNotSupportedBody,
          ),
          ?unreadable,
          if (install != null && install.shareLink.isNotEmpty) ...[
            Grouped(
              children: [
                EsimCopyRow(
                  label: l10n.esimShareLink,
                  value: install.shareLink,
                ),
                EsimCopyRow(
                  label: l10n.esimShareCode,
                  value: install.shareCode,
                ),
              ],
            ),
            gap,
          ],
          ?alternatives,
          if (alternatives != null) gap,
          Grouped(
            children: [
              if (!alternativesOpen)
                EsimActionRow(
                  icon: Icons.qr_code_rounded,
                  label: l10n.esimShowQr,
                  onTap: _openAlternatives,
                ),
              if (_directUrl(install) case final url?)
                EsimActionRow(
                  icon: Icons.download_rounded,
                  label: l10n.esimInstallHere,
                  onTap: () => _installNow(url),
                ),
              if (esim.rechargeable)
                EsimActionRow(
                  icon: Icons.add_rounded,
                  label: l10n.esimTopUpAction,
                  onTap: () => _topUp(esim),
                ),
            ],
          ),
          gap,
          details,
        ];
      case EsimPageMode.active:
      case EsimPageMode.low:
        return [
          EsimUsageCard(esim: esim),
          if (mode == EsimPageMode.low)
            heading(
              l10n.esimLowTitle,
              esim.rechargeable ? l10n.esimLowBodyTopUp : l10n.esimLowBodyNew,
            )
          else
            const SizedBox(height: CardsSpace.xl),
          if (install != null && !esim.gift) ...[
            Grouped(
              children: [
                EsimSetupSteps(
                  install: install,
                  facts: _facts,
                  initiallyExpanded: _justConfirmed,
                ),
                if (_confirmed)
                  EsimActionRow(
                    icon: Icons.qr_code_rounded,
                    label: l10n.esimShowInstallAgain,
                    onTap: _showInstallAgain,
                  ),
              ],
            ),
            gap,
          ],
          details,
        ];
      case EsimPageMode.ended:
        return [
          hero,
          heading(l10n.esimStatusExpired, l10n.esimEndedNote),
          details,
        ];
    }
  }
}
