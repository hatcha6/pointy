import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../data/accounts/saved_accounts.dart';
import '../../data/models/account_target.dart';
import '../../design/cards_tokens.dart';
import '../../shared/grouped.dart';
import '../../shared/haptics.dart';
import '../../shared/pressable.dart';
import 'account_form_model.dart';
import 'topup_text.dart';

/// Where a top-up goes, on its brand's page. A phone that topped the brand
/// up before shows its accounts as a list to choose from, the latest already
/// chosen, the way a wallet offers its cards; «حساب آخر» opens the fields.
/// The fields ask for each thing the game needs, typed the way the relay
/// reads it, and a line under them names the player as soon as the game
/// confirms the ID.
class AccountCard extends StatelessWidget {
  const AccountCard({super.key, required this.model});

  final AccountFormModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final saved = model.saved.isNotEmpty;
        final typing = model.chosen == null;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(CardsRadii.card),
            boxShadow: CardsShadows.raised,
          ),
          // A Material, so the rows' ripples show and clip to the corners.
          child: Material(
            color: theme.colorScheme.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(CardsRadii.card),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (saved) _SavedAccounts(model: model),
                AnimatedSize(
                  duration: CardsMotion.standard,
                  curve: CardsMotion.curve,
                  alignment: Alignment.topCenter,
                  child: typing
                      ? Padding(
                          padding: EdgeInsets.fromLTRB(
                            CardsSpace.lg,
                            saved ? CardsSpace.xs : CardsSpace.lg,
                            CardsSpace.lg,
                            CardsSpace.lg,
                          ),
                          child: _Fields(model: model),
                        )
                      : Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: CardsSpace.lg,
                          ),
                          // A saved account the game turned down says so.
                          child: _CheckLine(model: model, last: true),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The fields for an account not chosen from the list, the look-up's line
/// under them, and where to find what they ask for.
class _Fields extends StatelessWidget {
  const _Fields({required this.model});

  final AccountFormModel model;

  @override
  Widget build(BuildContext context) {
    final target = model.target;
    final typed = target.fields.where((f) => !f.isSelect).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, field) in target.fields.indexed) ...[
          if (i > 0) const SizedBox(height: CardsSpace.md),
          field.isSelect
              ? _ChoiceField(model: model, field: field)
              : _TypedField(
                  model: model,
                  field: field,
                  // The look-up's mark sits in the ID's own field.
                  showsCheck: field == typed.first,
                  last: field == typed.last,
                ),
        ],
        _CheckLine(model: model),
        const SizedBox(height: CardsSpace.md),
        _Help(target: target),
      ],
    );
  }
}

/// The accounts this phone topped the brand up to, one row each: a monogram,
/// the player's name over the ID, a tick on the one chosen. A row swiped
/// away is forgotten, with a moment to take it back. Last, «حساب آخر».
class _SavedAccounts extends StatelessWidget {
  const _SavedAccounts({required this.model});

  final AccountFormModel model;

  String _title(SavedAccount account) => account.name.isNotEmpty
      ? account.name
      : model.target.line(account.values);

  void _forget(BuildContext context, SavedAccount account) {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    Haptics.select();
    model.forget(account);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(l10n.accountRemoved(isolated(_title(account)))),
          action: SnackBarAction(
            label: l10n.undoAction,
            onPressed: () => model.restore(account),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final divider = Divider(
      height: 1,
      thickness: 0.6,
      indent: _Row.textStart,
      color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.7),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final account in model.saved) ...[
          Dismissible(
            key: ValueKey(model.target.line(account.values)),
            direction: DismissDirection.endToStart,
            background: const _ForgetBackground(),
            onDismissed: (_) => _forget(context, account),
            child: _Row(
              title: _title(account),
              subtitle: account.name.isNotEmpty
                  ? model.target.line(account.values)
                  : null,
              leading: _Monogram(text: _title(account)),
              ltr: true,
              selected: model.chosen?.same(account.values) ?? false,
              onTap: () {
                Haptics.select();
                model.use(account);
              },
              forgetLabel: l10n.forgetAccount(_title(account)),
              onForget: () => _forget(context, account),
            ),
          ),
          divider,
        ],
        _Row(
          title: l10n.otherAccount,
          leading: const _Monogram(icon: Icons.add_rounded),
          selected: model.chosen == null,
          link: true,
          onTap: () {
            if (model.chosen == null) {
              return;
            }
            Haptics.select();
            model.startNew();
          },
        ),
      ],
    );
  }
}

/// One row of the account list.
class _Row extends StatelessWidget {
  const _Row({
    required this.title,
    required this.leading,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.ltr = false,
    this.link = false,
    this.forgetLabel,
    this.onForget,
  });

  final String title;
  final String? subtitle;
  final Widget leading;
  final bool selected;
  final VoidCallback onTap;

  /// An account, read left to right.
  final bool ltr;

  /// An action rather than an account: in the link colour.
  final bool link;

  /// For screen readers, which cannot swipe a row away.
  final String? forgetLabel;
  final VoidCallback? onForget;

  /// Where the row's words start, which the dividers line up with.
  static const double textStart =
      CardsSpace.lg + _Monogram.size + CardsSpace.md;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final direction = ltr ? TextDirection.ltr : null;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      customSemanticsActions: onForget == null
          ? null
          : {CustomSemanticsAction(label: forgetLabel ?? title): onForget!},
      child: InkWell(
        onTap: onTap,
        child: AnimatedContainer(
          duration: CardsMotion.fast,
          color: selected && !link
              ? scheme.primary.withValues(alpha: 0.06)
              : Colors.transparent,
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(
            horizontal: CardsSpace.lg,
            vertical: CardsSpace.md,
          ),
          child: Row(
            children: [
              leading,
              const SizedBox(width: CardsSpace.md),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textDirection: direction,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: link ? scheme.primary : null,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textDirection: direction,
                        style: PointyTypography.numeric(
                          theme.textTheme.bodyMedium!,
                        ).copyWith(color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: CardsSpace.sm),
              AnimatedSwitcher(
                duration: CardsMotion.fast,
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: selected
                    ? Icon(
                        Icons.check_circle_rounded,
                        key: const ValueKey('on'),
                        color: scheme.primary,
                        size: 24,
                      )
                    // «حساب آخر» is an action until it is chosen.
                    : link
                    ? const SizedBox(key: ValueKey('none'), width: 24)
                    : Icon(
                        Icons.circle_outlined,
                        key: const ValueKey('off'),
                        color: scheme.outline,
                        size: 24,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A player's initial in a soft disc, as a phone's contacts show people;
/// or an icon for a row that is an action.
class _Monogram extends StatelessWidget {
  const _Monogram({this.text, this.icon});

  final String? text;
  final IconData? icon;

  static const double size = 40;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final action = icon != null;
    final letter = text == null || text!.isEmpty
        ? ''
        : String.fromCharCode(text!.runes.first).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: action ? Colors.transparent : scheme.primaryContainer,
        shape: BoxShape.circle,
        border: action
            ? Border.all(color: scheme.primary.withValues(alpha: 0.5))
            : null,
      ),
      child: action
          ? Icon(icon, size: 22, color: scheme.primary)
          : Text(
              letter,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.onPrimaryContainer,
              ),
            ),
    );
  }
}

/// Behind a row being swiped away: what letting go does.
class _ForgetBackground extends StatelessWidget {
  const _ForgetBackground();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ColoredBox(
      color: scheme.error,
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: CardsSpace.xl),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.delete_outline_rounded, color: scheme.onError),
              const SizedBox(width: CardsSpace.sm),
              Text(
                l10n.removeAccount,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onError,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of a choice field's few options, side by side with the others.
class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Pressable(
        onTap: onTap,
        semanticLabel: label,
        child: AnimatedContainer(
          duration: CardsMotion.fast,
          constraints: const BoxConstraints(minHeight: 44),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(
            horizontal: CardsSpace.sm,
            vertical: 10,
          ),
          decoration: BoxDecoration(
            color: selected ? scheme.onSurface : scheme.surface,
            borderRadius: BorderRadius.circular(CardsRadii.field),
            border: Border.all(
              color: selected ? scheme.onSurface : scheme.outline,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              color: selected ? scheme.surface : scheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// One thing the game asks for, typed: its label, the field (left to right,
/// whatever the page's direction, as an ID is), and what is wrong with it.
class _TypedField extends StatelessWidget {
  const _TypedField({
    required this.model,
    required this.field,
    required this.showsCheck,
    required this.last,
  });

  final AccountFormModel model;
  final TargetField field;
  final bool showsCheck;
  final bool last;

  /// A number pad only where the value is surely digits: the games the relay
  /// looks up by a numeric ID, and zone and server numbers. Anything else
  /// gets a Latin keyboard with no suggestions; an Arabic keyboard's digits
  /// are read as 0–9 either way.
  TextInputType get _keyboard {
    final target = model.target;
    if (target.kind == TargetKind.steamInvite) {
      return TextInputType.url;
    }
    final numeric =
        target.kind == TargetKind.gameAccount &&
        (target.check.isNotEmpty && field == target.fields.first ||
            field.label.startsWith('رقم المنطقة') ||
            field.label.startsWith('رقم الخادم'));
    return numeric ? TextInputType.number : TextInputType.visiblePassword;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final target = model.target;
    final problem = model.problemOf(field.key);
    final numeric = _keyboard == TextInputType.number;
    final invite = target.kind == TargetKind.steamInvite;
    final controller = model.controllerOf(field.key);
    final style = theme.textTheme.titleMedium!.copyWith(
      fontWeight: FontWeight.w600,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          field.label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        // An ID reads left to right on any page; so do its '@' and its
        // marks around it.
        Directionality(
          textDirection: TextDirection.ltr,
          child: Semantics(
            label: field.label,
            child: TextField(
              controller: controller,
              focusNode: model.focusOf(field.key),
              keyboardType: _keyboard,
              textInputAction: last
                  ? TextInputAction.done
                  : TextInputAction.next,
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              inputFormatters: [
                const _AsciiDigits(),
                if (!invite) FilteringTextInputFormatter.deny(RegExp(r'\s')),
                if (target.kind == TargetKind.telegram)
                  FilteringTextInputFormatter.deny('@'),
                if (!invite)
                  LengthLimitingTextInputFormatter(
                    AccountTarget.maxValueLength,
                  ),
              ],
              style: numeric ? PointyTypography.numeric(style) : style,
              onTapOutside: (_) => model.focusOf(field.key).unfocus(),
              onSubmitted: (_) {
                if (last) {
                  model.submitted();
                }
              },
              decoration: InputDecoration(
                hintText: switch (target.kind) {
                  TargetKind.telegram => 'username',
                  TargetKind.steamLogin => 'account_name',
                  TargetKind.steamInvite => 'https://s.team/p/…',
                  TargetKind.gameAccount => null,
                },
                // Always there, so the customer sees the @ is taken care of.
                prefixIcon: target.kind == TargetKind.telegram
                    ? Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: CardsSpace.lg,
                          end: 2,
                        ),
                        child: Text(
                          '@',
                          style: style.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : null,
                prefixIconConstraints: const BoxConstraints(),
                errorText: problem == null ? null : '',
                errorStyle: const TextStyle(height: 0, fontSize: 0),
                suffixIcon: invite
                    ? _PasteButton(
                        onPaste: (text) {
                          controller.text = target.clean(field, text);
                          model.focusOf(field.key).unfocus();
                        },
                      )
                    : showsCheck
                    ? _CheckMark(model: model)
                    : null,
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: CardsMotion.fast,
          curve: CardsMotion.curve,
          alignment: Alignment.topCenter,
          child: problem == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    problemText(l10n, field, problem),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// The look-up's mark in the ID's field: a spinner while it asks, a tick
/// when the game knows the account, a cross when it does not.
class _CheckMark extends StatelessWidget {
  const _CheckMark({required this.model});

  final AccountFormModel model;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget mark = switch (model.checkState) {
      CheckState.checking => const SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      CheckState.done => switch (model.shownStatus) {
        AccountStatus.valid => Icon(
          Icons.check_circle_rounded,
          color: scheme.tertiary,
        ),
        AccountStatus.invalid => Icon(
          Icons.cancel_rounded,
          color: scheme.error,
        ),
        _ => const SizedBox.shrink(),
      },
      _ => const SizedBox.shrink(),
    };
    return AnimatedSwitcher(
      duration: CardsMotion.fast,
      transitionBuilder: (child, animation) =>
          ScaleTransition(scale: animation, child: child),
      child: SizedBox(
        key: ValueKey('${model.checkState}-${model.shownStatus}'),
        width: 48,
        child: Center(child: mark),
      ),
    );
  }
}

class _PasteButton extends StatelessWidget {
  const _PasteButton({required this.onPaste});

  final ValueChanged<String> onPaste;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: CardsSpace.xs),
      child: TextButton.icon(
        onPressed: () async {
          final messenger = ScaffoldMessenger.of(context);
          final ClipboardData? data;
          try {
            data = await Clipboard.getData(Clipboard.kTextPlain);
          } on PlatformException {
            // A browser may refuse the read (Safari when the paste prompt is
            // dismissed or not granted). Point at the field instead of
            // leaving the tap to do nothing.
            messenger
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(l10n.pasteFailed)));
            return;
          }
          final text = data?.text?.trim() ?? '';
          if (text.isNotEmpty) {
            Haptics.select();
            onPaste(text);
          }
        },
        icon: const Icon(Icons.content_paste_rounded, size: 18),
        label: Text(l10n.pasteAction),
      ),
    );
  }
}

/// One choice the game asks for: its few options side by side, or a list
/// to pick from when there are many (a game's servers).
class _ChoiceField extends StatelessWidget {
  const _ChoiceField({required this.model, required this.field});

  final AccountFormModel model;
  final TargetField field;

  static const _sideBySide = 4;

  Future<void> _pick(BuildContext context) async {
    final value = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) =>
          _OptionList(field: field, selected: model.selectedOf(field.key)),
    );
    if (value != null) {
      model.select(field.key, value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = model.selectedOf(field.key);
    final problem = model.problemOf(field.key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          field.label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        if (field.options.length <= _sideBySide)
          // An even grid: up to three side by side, four as two rows of two.
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = CardsSpace.sm;
              final columns = field.options.length == 4
                  ? 2
                  : field.options.length;
              final width =
                  (constraints.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final option in field.options)
                    SizedBox(
                      width: width,
                      child: _OptionChip(
                        label: option.label,
                        selected: selected == option.value,
                        onTap: () {
                          Haptics.select();
                          model.select(field.key, option.value);
                        },
                      ),
                    ),
                ],
              );
            },
          )
        else
          Pressable(
            onTap: () => _pick(context),
            semanticLabel: field.label,
            child: InputDecorator(
              isEmpty: selected == null,
              decoration: InputDecoration(
                hintText: l10n.chooseOption,
                errorText: problem == null ? null : '',
                errorStyle: const TextStyle(height: 0, fontSize: 0),
                suffixIcon: Icon(
                  Icons.unfold_more_rounded,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              child: Text(
                selected == null ? '' : field.optionLabel(selected),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        if (problem != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              problemText(l10n, field, problem),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
      ],
    );
  }
}

class _OptionList extends StatelessWidget {
  const _OptionList({required this.field, required this.selected});

  final TargetField field;
  final String? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: field.options.length > 8 ? 0.7 : 0.45,
      maxChildSize: 0.92,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(
          CardsSpace.gutter,
          0,
          CardsSpace.gutter,
          CardsSpace.xl,
        ),
        children: [
          Text(field.label, style: theme.textTheme.headlineSmall),
          const SizedBox(height: CardsSpace.lg),
          Grouped(
            children: [
              for (final option in field.options)
                ListTile(
                  title: Text(option.label),
                  trailing: option.value == selected
                      ? Icon(
                          Icons.check_rounded,
                          color: theme.colorScheme.primary,
                        )
                      : null,
                  onTap: () {
                    Haptics.select();
                    Navigator.of(context).pop(option.value);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Under the fields: whose account the game says it is, or why it is not
/// one, rising in as the look-up answers. A saved account's remembered name
/// shows until then.
class _CheckLine extends StatelessWidget {
  const _CheckLine({required this.model, this.last = false});

  final AccountFormModel model;

  /// The card's last line: it keeps its own space below.
  final bool last;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final kind = kindKey(model.target.kind);
    final status = model.shownStatus;
    final (
      IconData? icon,
      Color color,
      String text,
      bool retry,
    ) = switch (model.checkState) {
      // While the ID is being typed the card keeps still: the field's own
      // spinner says a look-up is on its way, and only good news joins it.
      CheckState.checking || CheckState.failed when model.typing => (
        null,
        scheme.onSurface,
        '',
        false,
      ),
      CheckState.checking => (
        null,
        scheme.onSurfaceVariant,
        l10n.accountChecking,
        false,
      ),
      // A chosen account's row already names its player: only news shows.
      CheckState.done
          when status == AccountStatus.valid && model.chosen == null =>
        (
          Icons.verified_rounded,
          scheme.tertiary,
          model.playerName.isNotEmpty
              ? l10n.accountPlayer(isolatedName(model.playerName))
              : l10n.accountFound(kind),
          false,
        ),
      CheckState.done when status == AccountStatus.invalid => (
        Icons.error_rounded,
        scheme.error,
        l10n.accountNotFound(kind),
        false,
      ),
      CheckState.done when status == AccountStatus.unconfirmed => (
        Icons.info_rounded,
        scheme.onSecondaryContainer,
        l10n.accountUnconfirmed,
        false,
      ),
      CheckState.failed => (
        Icons.info_rounded,
        scheme.onSecondaryContainer,
        l10n.accountUnconfirmed,
        true,
      ),
      _ when model.chosen == null && model.playerName.isNotEmpty => (
        Icons.person_rounded,
        scheme.onSurfaceVariant,
        l10n.accountPlayer(isolatedName(model.playerName)),
        false,
      ),
      _ => (null, scheme.onSurface, '', false),
    };
    return AnimatedSize(
      duration: CardsMotion.standard,
      curve: CardsMotion.curve,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: CardsMotion.fast,
        child: text.isEmpty
            ? const SizedBox(width: double.infinity)
            : Padding(
                key: ValueKey(text),
                padding: EdgeInsets.only(
                  top: CardsSpace.md,
                  bottom: last ? CardsSpace.md : 0,
                ),
                child: Row(
                  children: [
                    if (icon == null)
                      const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(icon, size: 18, color: color),
                    const SizedBox(width: CardsSpace.sm),
                    Expanded(
                      child: Text(
                        text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: color,
                          fontWeight: status == AccountStatus.valid
                              ? FontWeight.w700
                              : null,
                        ),
                      ),
                    ),
                    if (retry)
                      TextButton(
                        onPressed: model.lookUp,
                        child: Text(l10n.retryAction),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// «أين أجد المعرّف؟»: the brand's own words on where the account is found,
/// folded away until asked for. An invite link is new to most people, so its
/// steps start open.
class _Help extends StatefulWidget {
  const _Help({required this.target});

  final AccountTarget target;

  @override
  State<_Help> createState() => _HelpState();
}

class _HelpState extends State<_Help> {
  late bool _open = widget.target.kind == TargetKind.steamInvite;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final hint = widget.target.hint;
    if (hint.isEmpty) {
      return const SizedBox.shrink();
    }
    final link = theme.colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          child: InkWell(
            borderRadius: BorderRadius.circular(CardsRadii.field),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: CardsSpace.xs),
              child: Row(
                children: [
                  Icon(Icons.help_outline_rounded, size: 18, color: link),
                  const SizedBox(width: CardsSpace.sm),
                  Expanded(
                    child: Text(
                      l10n.topUpHintTitle(kindKey(widget.target.kind)),
                      style: theme.textTheme.labelLarge?.copyWith(color: link),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: CardsMotion.fast,
                    child: Icon(
                      Icons.expand_more_rounded,
                      size: 20,
                      color: link,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: CardsMotion.standard,
          curve: CardsMotion.curve,
          alignment: Alignment.topCenter,
          child: _open
              ? Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: 26,
                    top: CardsSpace.xs,
                  ),
                  child: Text(
                    hint,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// The phone's Arabic digits as 0–9, as they are typed.
class _AsciiDigits extends TextInputFormatter {
  const _AsciiDigits();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = asciiDigits(newValue.text);
    return text == newValue.text ? newValue : newValue.copyWith(text: text);
  }
}
