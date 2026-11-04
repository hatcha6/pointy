import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/result.dart';
import '../../data/api/relay_api.dart';
import '../../data/models/campaign.dart';
import '../../design/cards_tokens.dart';
import '../../shared/cards_scope.dart';
import '../../shared/haptics.dart';
import '../../shared/money_text.dart';
import '../../shared/pressable.dart';
import '../../shared/relay_error_text.dart';

/// «من أين سمعت عن دفتر كروت؟»: one tap on an answer, and a campaign's code
/// for whoever has one. A code the app already holds (a followed link, a
/// Play install) shows as found, with what it gives.
///
/// [onDone] runs once the answer is handed to [AttributionRepository], or
/// when the customer skips.
///
/// The onboarding shows it as its last step: centred like the steps before
/// it, its parts rising in one after another ([entrance]), and the step's
/// own button and «تخطَّ» doing its [HeardFromFormState.submit] and
/// [HeardFromFormState.skip] ([actions] off).
class HeardFromForm extends StatefulWidget {
  const HeardFromForm({
    super.key,
    required this.onDone,
    this.signedIn = false,
    this.actions = true,
    this.centered = false,
    this.onReady,
    this.entrance,
    this.compact = false,
  });

  final VoidCallback onDone;

  /// Asked right after a sign-in: a reward goes into the balance now
  /// rather than at sign-in.
  final bool signedIn;

  /// Its own «متابعة» and «تخطَّ» under it.
  final bool actions;

  /// Words and answers centred, as the onboarding's steps are.
  final bool centered;

  /// Told whether there is anything to send yet.
  final ValueChanged<bool>? onReady;

  /// 0 to 1: the title, the words, each answer and the code field rise in,
  /// one after another.
  final Animation<double>? entrance;

  /// A very short screen (a phone on its side): the title straight to the
  /// answers, without the line under it.
  final bool compact;

  @override
  State<HeardFromForm> createState() => HeardFromFormState();
}

class HeardFromFormState extends State<HeardFromForm> {
  final _code = TextEditingController();
  String _answer = '';
  CampaignOffer? _checked;
  String? _codeError;
  bool _checking = false;
  bool _saving = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final typed = normalizeCampaignCode(_code.text);
    final l10n = AppLocalizations.of(context);
    if (!isCampaignCode(typed)) {
      setState(() => _codeError = l10n.campaignCodeUnknown);
      return;
    }
    setState(() {
      _checking = true;
      _codeError = null;
    });
    final result = await CardsScope.of(context).attribution.check(typed);
    if (!mounted) {
      return;
    }
    setState(() => _checking = false);
    switch (result) {
      case Ok(:final value):
        Haptics.success();
        setState(() => _checked = value);
      case Error(:final exception):
        Haptics.warning();
        setState(
          () => _codeError =
              exception is RelayApiException &&
                  exception.code == 'unknown_campaign'
              ? l10n.campaignCodeUnknown
              : relayErrorText(l10n, exception),
        );
    }
  }

  bool _ready = false;

  /// Whether «متابعة» has something to send: an answer, or a code.
  bool get ready => _ready;

  void _tellReady() {
    final ready =
        !_saving &&
        (_answer.isNotEmpty ||
            _checked != null ||
            CardsScope.of(context).attribution.pending.code.isNotEmpty);
    if (ready != _ready) {
      _ready = ready;
      widget.onReady?.call(ready);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A code already held makes it ready from the start; told after this
    // frame, never while the step around it builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _tellReady();
      }
    });
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _tellReady();
  }

  /// Hands the answer over, then [HeardFromForm.onDone].
  Future<void> submit() => _submit();

  /// Not answered, and not asked again.
  void skip() => _skip();

  Future<void> _submit() async {
    if (_saving) {
      return;
    }
    setState(() => _saving = true);
    await CardsScope.of(context).attribution
        .answer(heardFrom: _answer, code: _checked);
    if (mounted) {
      Haptics.select();
      widget.onDone();
    }
  }

  void _skip() {
    CardsScope.of(context).attribution.skip();
    widget.onDone();
  }

  String _label(AppLocalizations l10n, String answer) => switch (answer) {
    'facebook' => l10n.heardFromFacebook,
    'instagram' => l10n.heardFromInstagram,
    'tiktok' => l10n.heardFromTiktok,
    'whatsapp' => l10n.heardFromWhatsapp,
    'friend' => l10n.heardFromFriend,
    'shop' => l10n.heardFromShop,
    'billboard' => l10n.heardFromBillboard,
    'store_search' => l10n.heardFromStoreSearch,
    _ => l10n.heardFromOther,
  };

  /// The app it names: its own mark (in one colour, like the words); the
  /// rest a plain icon. The store is the one this phone has.
  static Object _mark(String answer) => switch (answer) {
    'facebook' ||
    'instagram' ||
    'tiktok' ||
    'whatsapp' => 'assets/heard_from/$answer.svg',
    'store_search' when defaultTargetPlatform == TargetPlatform.iOS =>
      'assets/heard_from/appstore.svg',
    'store_search' when defaultTargetPlatform == TargetPlatform.android =>
      'assets/heard_from/googleplay.svg',
    'store_search' => Icons.search_rounded,
    'friend' => Icons.people_alt_rounded,
    'shop' => Icons.storefront_rounded,
    'billboard' => Icons.signpost_rounded,
    _ => Icons.more_horiz_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final attribution = CardsScope.of(context).attribution;
    final held = attribution.pending.code;
    final heldOffer = attribution.offer;
    final align = widget.centered ? TextAlign.center : TextAlign.start;
    var order = 0;
    Widget enter(Widget child) =>
        _Enter(entrance: widget.entrance, order: order++, child: child);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        enter(
          Text(
            l10n.heardFromTitle,
            textAlign: align,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (!widget.compact) ...[
          SizedBox(height: widget.centered ? CardsSpace.md : CardsSpace.xs),
          enter(
            Text(
              l10n.heardFromBody,
              textAlign: align,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: widget.centered ? 1.6 : null,
              ),
            ),
          ),
        ],
        SizedBox(height: widget.compact ? CardsSpace.md : CardsSpace.xl),
        Wrap(
          alignment: widget.centered
              ? WrapAlignment.center
              : WrapAlignment.start,
          spacing: CardsSpace.sm,
          runSpacing: CardsSpace.sm,
          children: [
            for (final answer in heardFromAnswers)
              enter(
                _AnswerChip(
                  label: _label(l10n, answer),
                  mark: _mark(answer),
                  selected: _answer == answer,
                  onTap: () {
                    Haptics.select();
                    setState(() => _answer = _answer == answer ? '' : answer);
                  },
                ),
              ),
          ],
        ),
        const SizedBox(height: CardsSpace.xl),
        if (held.isNotEmpty)
          enter(
            _Found(
              text: heldOffer != null && heldOffer.reward.isPositive
                  ? l10n.campaignLinkReward(
                      held,
                      formatMoney(l10n, heldOffer.reward),
                    )
                  : l10n.campaignCodeValid,
            ),
          )
        else ...[
          enter(
            TextField(
              controller: _code,
              enabled: _checked == null && !_checking,
              textDirection: TextDirection.ltr,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              inputFormatters: [
                TextInputFormatter.withFunction(
                  (_, next) =>
                      next.copyWith(text: normalizeCampaignCode(next.text)),
                ),
                LengthLimitingTextInputFormatter(24),
              ],
              decoration: InputDecoration(
                labelText: l10n.campaignCodeLabel,
                hintText: l10n.campaignCodeHint,
                hintTextDirection: TextDirection.ltr,
                errorText: _codeError,
                prefixIcon: const Icon(Icons.confirmation_number_outlined),
                suffixIcon: _checked != null
                    ? Icon(
                        Icons.check_circle_rounded,
                        color: theme.colorScheme.primary,
                      )
                    : TextButton(
                        onPressed: _checking ? null : _check,
                        child: Text(l10n.campaignCodeCheck),
                      ),
              ),
              onChanged: (_) {
                if (_codeError != null) {
                  setState(() => _codeError = null);
                }
              },
              onSubmitted: (_) => _check(),
            ),
          ),
          if (_checked case final offer?)
            Padding(
              padding: const EdgeInsets.only(top: CardsSpace.sm),
              child: _Found(
                text: !offer.reward.isPositive
                    ? l10n.campaignCodeValid
                    : widget.signedIn
                    ? l10n.campaignCodeRewardNow(
                        formatMoney(l10n, offer.reward),
                      )
                    : l10n.campaignCodeRewardLater(
                        formatMoney(l10n, offer.reward),
                      ),
              ),
            ),
        ],
        if (widget.actions) ...[
          const SizedBox(height: CardsSpace.xl),
          FilledButton(
            onPressed: _ready ? _submit : null,
            child: Text(l10n.continueAction),
          ),
          const SizedBox(height: CardsSpace.xs),
          TextButton(
            onPressed: _saving ? null : _skip,
            child: Text(l10n.onboardingSkip),
          ),
        ],
      ],
    );
  }
}

/// One part of the form rising into place: each a beat after the one
/// before, so the step builds itself from the top down.
class _Enter extends StatelessWidget {
  const _Enter({
    required this.entrance,
    required this.order,
    required this.child,
  });

  final Animation<double>? entrance;
  final int order;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final entrance = this.entrance;
    if (entrance == null) {
      return child;
    }
    final start = (0.32 + order * 0.035).clamp(0.0, 0.8);
    final curve = CurvedAnimation(
      parent: entrance,
      curve: Interval(
        start,
        (start + 0.38).clamp(0.0, 1.0),
        curve: Curves.easeOutCubic,
      ),
    );
    return AnimatedBuilder(
      animation: curve,
      child: child,
      builder: (context, child) => Opacity(
        opacity: curve.value,
        child: Transform.translate(
          offset: Offset(0, (1 - curve.value) * CardsSpace.lg),
          child: Transform.scale(
            scale: 0.96 + 0.04 * curve.value,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _AnswerChip extends StatelessWidget {
  const _AnswerChip({
    required this.label,
    required this.mark,
    required this.selected,
    required this.onTap,
  });

  final String label;

  /// An [IconData], or the path of a brand's one-colour SVG.
  final Object mark;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? scheme.onPrimary : scheme.onSurface;
    return Semantics(
      selected: selected,
      button: true,
      child: Pressable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: CardsMotion.fast,
          constraints: const BoxConstraints(minHeight: CardsSizes.touch),
          padding: const EdgeInsetsDirectional.fromSTEB(
            CardsSpace.md,
            0,
            CardsSpace.lg,
            0,
          ),
          decoration: BoxDecoration(
            color: selected ? scheme.primary : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(CardsRadii.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              switch (mark) {
                final IconData icon => Icon(icon, size: 20, color: foreground),
                final String asset => SvgPicture.asset(
                  asset,
                  width: 18,
                  height: 18,
                  colorFilter: ColorFilter.mode(foreground, BlendMode.srcIn),
                ),
                _ => const SizedBox.shrink(),
              },
              const SizedBox(width: CardsSpace.sm),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: foreground, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A code the app has: a quiet line with a check, and what it gives.
class _Found extends StatelessWidget {
  const _Found({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(CardsSpace.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(CardsRadii.tile),
      ),
      child: Row(
        children: [
          Icon(
            Icons.redeem_rounded,
            color: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: CardsSpace.md),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
