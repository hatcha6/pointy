import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/shop_settings.dart';
import '../../../data/services/repair_intake_printables.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';

/// How many conditions a repair receipt carries, and how long each may be —
/// the same limits the server holds them to. Past these a thermal slip stops
/// being something a customer reads.
const repairTicketTermsMax = 20;
const repairTicketTermMaxLength = 300;

/// The repair counter's two shop-wide choices: what a declined diagnosis costs,
/// and the conditions printed on the receipt a customer takes home.
class RepairTicketSettingsSection extends StatelessWidget {
  const RepairTicketSettingsSection({
    super.key,
    required this.settings,
    required this.enabled,
    required this.onSave,
  });

  final ShopSettings settings;
  final bool enabled;

  /// Sends the whole draft, built from the stored settings, so nothing this
  /// section does not show is reset by saving it.
  final Future<bool> Function(ShopSettingsDraft draft) onSave;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final fee = settings.repairDiagnosisFee;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PointySectionHeader(
          title: l10n.repairTicketSectionTitle,
          subtitle: l10n.repairTicketSectionHint,
          leading: const Icon(Icons.receipt_long_outlined),
        ),
        SizedBox(height: spacing.sm),
        PointySettingsSection(
          children: [
            PointySettingsTile(
              icon: Icons.payments_outlined,
              title: l10n.repairDiagnosisFeeTitle,
              subtitle: fee == null || fee <= 0
                  ? l10n.repairDiagnosisFeeNone
                  : formatMoney(fee),
              onTap: enabled ? () => _editFee(context) : null,
            ),
          ],
        ),
        SizedBox(height: spacing.sm),
        RepairTicketTermsField(
          terms: settings.repairTicketTerms,
          enabled: enabled,
          onManage: () => _editTerms(context),
        ),
      ],
    );
  }

  Future<void> _editFee(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final current = settings.repairDiagnosisFee;
    final fee = await showDialog<double>(
      context: context,
      builder: (_) => PointyNumberEntryDialog(
        icon: Icons.payments_outlined,
        title: l10n.repairDiagnosisFeeTitle,
        message: l10n.repairDiagnosisFeeHelper,
        suffixText: currencySymbol,
        initialValue: current == null ? '0' : current.toStringAsFixed(2),
        isValid: (value) => value >= 0,
        confirmLabel: l10n.saveButton,
      ),
    );
    if (fee == null) {
      return;
    }
    await onSave(
      ShopSettingsDraft.fromSettings(
        settings,
      ).copyWith(repairDiagnosisFee: fee > 0 ? fee : null),
    );
  }

  Future<void> _editTerms(BuildContext context) async {
    final edit = await showDialog<RepairTicketTermsEdit>(
      context: context,
      builder: (_) =>
          RepairTicketTermsDialog(initialTerms: settings.repairTicketTerms),
    );
    if (edit == null) {
      return;
    }
    await onSave(
      ShopSettingsDraft.fromSettings(
        settings,
      ).copyWith(repairTicketTerms: edit.terms),
    );
  }
}

/// The receipt's conditions as they will print, numbered, with the button that
/// edits them — the payment-terminal list's shape, for a list of sentences.
class RepairTicketTermsField extends StatelessWidget {
  const RepairTicketTermsField({
    super.key,
    required this.terms,
    required this.enabled,
    required this.onManage,
  });

  /// Null: the shop has not written its own, and the defaults print.
  final List<String>? terms;
  final bool enabled;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final usingDefaults = terms == null;
    final printed = terms ?? const RepairTicketLabels.arabic().defaultTerms;

    return DecoratedBox(
      key: const ValueKey('repair_ticket_terms_field'),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(
          color: enabled ? colors.line : colors.line.withValues(alpha: 0.55),
        ),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.gavel_outlined, color: colors.primaryStrong),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.repairTicketTermsTitle,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: enabled ? colors.ink : colors.mutedInk,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.repairTicketTermsHelper,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.tonalIcon(
                  key: const ValueKey('manage_repair_ticket_terms_button'),
                  onPressed: enabled ? onManage : null,
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(l10n.repairTicketTermsManageButton),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (usingDefaults) ...[
              PointyInlineMessage(
                message: l10n.repairTicketTermsDefaultNotice,
                icon: Icons.info_outline,
                compact: true,
              ),
              const SizedBox(height: 8),
            ],
            if (printed.isEmpty)
              PointyInlineMessage(
                message: l10n.repairTicketTermsNoneMessage,
                icon: Icons.info_outline,
                compact: true,
              )
            else
              ConstrainedBox(
                // Room for the six default conditions whole; a longer list
                // scrolls inside the card rather than stretching the page.
                constraints: const BoxConstraints(maxHeight: 340),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: printed.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 6),
                  itemBuilder: (context, index) => _TermPreviewRow(
                    number: index + 1,
                    text: printed[index],
                    muted: usingDefaults,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TermPreviewRow extends StatelessWidget {
  const _TermPreviewRow({
    required this.number,
    required this.text,
    required this.muted,
  });

  final int number;
  final String text;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceSunken.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: 12,
          vertical: 8,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TermNumber(number: number),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: muted ? colors.mutedInk : colors.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TermNumber extends StatelessWidget {
  const _TermNumber({required this.number});

  final int number;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        shape: BoxShape.circle,
      ),
      child: Text(
        '$number',
        style: PointyTypography.numeric(
          Theme.of(context).textTheme.labelMedium ?? const TextStyle(),
        ).copyWith(color: colors.primaryStrong, fontWeight: FontWeight.w800),
      ),
    );
  }
}

/// What the terms editor hands back: the shop's own list — possibly empty, a
/// shop that prints none — or null, "print the app's defaults".
class RepairTicketTermsEdit {
  const RepairTicketTermsEdit(this.terms);

  final List<String>? terms;
}

/// Adds, edits, removes and reorders the receipt's conditions.
///
/// A shop that has never written its own starts from the defaults, so the
/// owner edits what actually prints rather than a blank box; touching them
/// makes them the shop's own, and "restore defaults" hands them back.
class RepairTicketTermsDialog extends StatefulWidget {
  const RepairTicketTermsDialog({super.key, required this.initialTerms});

  /// Null when the shop prints the defaults.
  final List<String>? initialTerms;

  @override
  State<RepairTicketTermsDialog> createState() =>
      _RepairTicketTermsDialogState();
}

class _RepairTicketTermsDialogState extends State<RepairTicketTermsDialog> {
  final _controller = TextEditingController();
  late List<_Term> _terms;
  late bool _usingDefaults;
  String? _error;
  var _nextId = 0;

  List<String> get _defaults => const RepairTicketLabels.arabic().defaultTerms;

  @override
  void initState() {
    super.initState();
    _usingDefaults = widget.initialTerms == null;
    _terms = _wrap(widget.initialTerms ?? _defaults);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<_Term> _wrap(List<String> texts) => [
    for (final text in texts) _Term(_nextId++, text),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final atLimit = _terms.length >= repairTicketTermsMax;
    // On a phone every pixel of width goes to the sentences: the default
    // dialog margins leave a term wrapping a word to a line.
    final phone = MediaQuery.sizeOf(context).width < 480;

    return AdaptiveDialogSurface(
      size: AdaptiveModalSize.standard,
      child: AlertDialog(
        insetPadding: phone
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 24)
            : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        contentPadding: phone
            ? const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 8)
            : null,
        icon: const Icon(Icons.gavel_outlined),
        title: Text(l10n.repairTicketTermsTitle),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.repairTicketTermsDialogDescription),
              const SizedBox(height: 16),
              _entryRow(l10n, atLimit: atLimit),
              const SizedBox(height: 16),
              if (_usingDefaults) ...[
                PointyInlineMessage(
                  message: l10n.repairTicketTermsEditingDefaultsNotice,
                  icon: Icons.info_outline,
                  compact: true,
                ),
                const SizedBox(height: 10),
              ],
              if (_terms.isEmpty)
                PointyInlineMessage(
                  message: l10n.repairTicketTermsNoneMessage,
                  icon: Icons.info_outline,
                  compact: true,
                )
              else
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 340),
                    child: ReorderableListView.builder(
                      shrinkWrap: true,
                      buildDefaultDragHandles: false,
                      itemCount: _terms.length,
                      onReorder: _move,
                      itemBuilder: (context, index) {
                        final term = _terms[index];
                        return Padding(
                          key: ValueKey(term.id),
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _EditableTermRow(
                            index: index,
                            text: term.text,
                            onEdit: () => _edit(index),
                            onRemove: () => _remove(index),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              if (!_usingDefaults) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const ValueKey('restore_repair_ticket_terms_button'),
                    onPressed: _restoreDefaults,
                    icon: const Icon(Icons.restart_alt),
                    label: Text(l10n.repairTicketTermsRestoreDefaults),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(
            key: const ValueKey('repair_ticket_terms_done_button'),
            onPressed: () => Navigator.of(context).pop(
              RepairTicketTermsEdit(
                _usingDefaults ? null : [for (final term in _terms) term.text],
              ),
            ),
            child: Text(l10n.saveButton),
          ),
        ],
      ),
    );
  }

  /// The new-term field with its add button: side by side where there is room,
  /// stacked on a phone — the terminal editor's layout.
  Widget _entryRow(AppLocalizations l10n, {required bool atLimit}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final input = TextField(
          key: const ValueKey('repair_ticket_term_field'),
          controller: _controller,
          autofocus: true,
          enabled: !atLimit,
          minLines: 1,
          maxLines: 3,
          textInputAction: TextInputAction.done,
          inputFormatters: [
            LengthLimitingTextInputFormatter(repairTicketTermMaxLength),
          ],
          onChanged: (_) {
            if (_error != null) {
              setState(() => _error = null);
            }
          },
          onSubmitted: (_) => _add(l10n),
          decoration: InputDecoration(
            labelText: l10n.repairTicketTermFieldLabel,
            hintText: l10n.repairTicketTermFieldHint,
            errorText: atLimit
                ? l10n.repairTicketTermsLimitError(repairTicketTermsMax)
                : _error,
            errorMaxLines: 2,
            prefixIcon: const Icon(Icons.playlist_add_outlined),
          ),
        );
        final addButton = FilledButton.tonalIcon(
          key: const ValueKey('add_repair_ticket_term_button'),
          onPressed: atLimit ? null : () => _add(l10n),
          icon: const Icon(Icons.add),
          label: Text(l10n.repairTicketTermAddButton),
        );
        if (constraints.maxWidth < 420) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              input,
              const SizedBox(height: 10),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: addButton,
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: input),
            const SizedBox(width: 10),
            Padding(padding: const EdgeInsets.only(top: 2), child: addButton),
          ],
        );
      },
    );
  }

  /// Why [text] cannot join the list — blank, or already on it — or null when
  /// it can. [except] is the term being rewritten, which may keep its words.
  String? _problemWith(String text, AppLocalizations l10n, {int? except}) {
    if (text.isEmpty) {
      return l10n.repairTicketTermRequiredError;
    }
    for (var index = 0; index < _terms.length; index++) {
      if (index != except && _terms[index].text == text) {
        return l10n.repairTicketTermDuplicateError;
      }
    }
    return null;
  }

  void _add(AppLocalizations l10n) {
    final text = _tidyTerm(_controller.text);
    final problem = _problemWith(text, l10n);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _terms = [..._terms, _Term(_nextId++, text)];
      _usingDefaults = false;
      _error = null;
      _controller.clear();
    });
  }

  Future<void> _edit(int index) async {
    final l10n = AppLocalizations.of(context)!;
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _EditTermDialog(
        initialText: _terms[index].text,
        // Checked inside the edit dialog, so a clash is fixed where it was
        // typed instead of the rewrite closing and quietly not taking.
        validate: (text) => _problemWith(text, l10n, except: index),
      ),
    );
    if (text == null || !mounted || text == _terms[index].text) {
      return;
    }
    setState(() {
      _terms = [
        for (var position = 0; position < _terms.length; position++)
          position == index
              ? _Term(_terms[position].id, text)
              : _terms[position],
      ];
      _usingDefaults = false;
    });
  }

  void _remove(int index) {
    setState(() {
      _terms = [..._terms]..removeAt(index);
      _usingDefaults = false;
    });
  }

  void _move(int from, int to) {
    setState(() {
      final moved = [..._terms];
      final term = moved.removeAt(from);
      // The list reports the slot as counted before the item left it.
      moved.insert(to > from ? to - 1 : to, term);
      _terms = moved;
      _usingDefaults = false;
    });
  }

  void _restoreDefaults() {
    setState(() {
      _terms = _wrap(_defaults);
      _usingDefaults = true;
      _error = null;
    });
  }
}

/// One printed line per term: a line break typed inside one would read as two
/// conditions sharing a number.
String _tidyTerm(String value) =>
    value.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).join(' ');

/// A term with an identity of its own, so the reorderable list keeps each row
/// attached to its text while rows move and change.
class _Term {
  const _Term(this.id, this.text);

  final int id;
  final String text;
}

class _EditableTermRow extends StatelessWidget {
  const _EditableTermRow({
    required this.index,
    required this.text,
    required this.onEdit,
    required this.onRemove,
  });

  final int index;
  final String text;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final actions = [
      IconButton(
        key: ValueKey('edit_repair_ticket_term_$index'),
        tooltip: l10n.repairTicketTermEditTooltip,
        visualDensity: VisualDensity.compact,
        onPressed: onEdit,
        icon: const Icon(Icons.edit_outlined, size: 20),
      ),
      IconButton(
        key: ValueKey('remove_repair_ticket_term_$index'),
        tooltip: l10n.repairTicketTermRemoveTooltip,
        visualDensity: VisualDensity.compact,
        onPressed: onRemove,
        icon: const Icon(Icons.delete_outline, size: 20),
      ),
    ];
    final handle = ReorderableDragStartListener(
      index: index,
      child: Tooltip(
        message: l10n.repairTicketTermReorderTooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Icon(Icons.drag_indicator, color: colors.mutedInk),
          ),
        ),
      ),
    );
    final text = Text(this.text, style: Theme.of(context).textTheme.bodyMedium);

    return Material(
      color: colors.surfaceSunken.withValues(alpha: 0.38),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(4, 6, 4, 6),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Narrow rows give the sentence the full width and tuck the two
            // actions underneath it, rather than wrapping it a word to a line.
            final stacked = constraints.maxWidth < 380;
            return Row(
              crossAxisAlignment: stacked
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              children: [
                handle,
                Padding(
                  padding: EdgeInsets.only(top: stacked ? 6 : 0),
                  child: _TermNumber(number: index + 1),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: stacked
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: text,
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: actions,
                            ),
                          ],
                        )
                      : text,
                ),
                if (!stacked) ...actions,
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Rewrites one term in a field wide and tall enough for a sentence.
///
/// Owns its controller so it outlives the dialog's exit animation.
class _EditTermDialog extends StatefulWidget {
  const _EditTermDialog({required this.initialText, required this.validate});

  final String initialText;

  /// Why the tidied rewrite cannot be kept, or null when it can.
  final String? Function(String text) validate;

  @override
  State<_EditTermDialog> createState() => _EditTermDialogState();
}

class _EditTermDialogState extends State<_EditTermDialog> {
  late final _controller = TextEditingController(text: widget.initialText);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final text = _tidyTerm(_controller.text);
    final problem = widget.validate(text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AdaptiveDialogSurface(
      size: AdaptiveModalSize.compact,
      child: AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.edit_outlined),
        title: Text(l10n.repairTicketTermEditTitle),
        content: TextField(
          key: const ValueKey('edit_repair_ticket_term_field'),
          controller: _controller,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          inputFormatters: [
            LengthLimitingTextInputFormatter(repairTicketTermMaxLength),
          ],
          onChanged: (_) {
            if (_error != null) {
              setState(() => _error = null);
            }
          },
          decoration: InputDecoration(
            labelText: l10n.repairTicketTermLabel,
            errorText: _error,
            errorMaxLines: 2,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancelButton),
          ),
          FilledButton(onPressed: _save, child: Text(l10n.saveButton)),
        ],
      ),
    );
  }
}
