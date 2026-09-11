import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/barcode/scale_barcode.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/formatters.dart';
import '../../../shared/shell/shell.dart';
import '../../../shared/units.dart';
import '../view_models/scale_rules_view_model.dart';

/// How this shop's weighing scales lay out the labels they print.
///
/// The screen is built around the one thing a shop can actually verify: the
/// "try a label" field. A shopkeeper does not know what `21IIIIIVVVVVC` means
/// and should not have to — they hold a sticker their scale printed under the
/// scanner and read back what the till will make of it.
class ScaleRulesScreen extends StatefulWidget {
  const ScaleRulesScreen({super.key, required this.viewModel});

  final ScaleRulesViewModel viewModel;

  @override
  State<ScaleRulesScreen> createState() => _ScaleRulesScreenState();
}

class _ScaleRulesScreenState extends State<ScaleRulesScreen> {
  final TextEditingController _tryController = TextEditingController();

  ScaleRulesViewModel get viewModel => widget.viewModel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => viewModel.load());
  }

  @override
  void dispose() {
    _tryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          appBar: PointyAppBar(
            leading: const BackButton(),
            title: Text(l10n.scaleRulesTitle),
            isLoading: viewModel.isMutating,
            actions: [
              IconButton(
                tooltip: l10n.refreshCatalogTooltip,
                onPressed: viewModel.isMutating ? null : viewModel.load,
                icon: const Icon(Icons.sync),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: viewModel.isMutating ? null : () => _openEditor(context),
            icon: const Icon(Icons.add),
            label: Text(l10n.addScaleRuleButton),
          ),
          body: SafeArea(
            child: BarcodeScanListener(
              onBarcodeScanned: (barcode) {
                _tryController.text = barcode;
                setState(() {});
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  PointyDetailCallout(
                    icon: Icons.monitor_weight_outlined,
                    title: l10n.scaleRulesIntroTitle,
                    message: l10n.scaleRulesIntroMessage,
                  ),
                  const SizedBox(height: 16),
                  _TryALabelCard(
                    controller: _tryController,
                    rules: viewModel.orderedRules,
                    onChanged: () => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  if (viewModel.isLoading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Center(child: PointySpinner()),
                    )
                  else if (viewModel.rules.isEmpty)
                    PointyEmptyState(
                      icon: Icons.monitor_weight_outlined,
                      title: l10n.scaleRulesEmpty,
                      message: l10n.scaleRulesIntroMessage,
                    )
                  else
                    for (final rule in viewModel.orderedRules)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _ScaleRuleTile(
                          rule: rule,
                          onEdit: () => _openEditor(context, rule: rule),
                          onDelete: () => _delete(context, rule),
                        ),
                      ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openEditor(
    BuildContext context, {
    ScaleBarcodeRule? rule,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final draft = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => _ScaleRuleEditorDialog(rule: rule),
    );
    if (draft == null) {
      return;
    }
    final saved = await viewModel.save(id: rule?.id, draft: draft);
    if (!saved) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              viewModel.errorMessage.isEmpty
                  ? l10n.scaleRuleSaveError
                  : viewModel.errorMessage,
            ),
          ),
        );
    }
  }

  Future<void> _delete(BuildContext context, ScaleBarcodeRule rule) async {
    final l10n = AppLocalizations.of(context)!;
    final id = rule.id;
    if (id == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => PointyDestructiveConfirmationDialog(
        title: l10n.scaleRuleDeleteTitle,
        message: l10n.scaleRuleDeleteMessage,
        confirmLabel: l10n.deleteButton,
      ),
    );
    if (confirmed == true) {
      await viewModel.remove(id);
    }
  }
}

/// Hold a real sticker under the scanner and read back what the till makes of
/// it. The only check in this screen that proves anything about a real scale.
class _TryALabelCard extends StatelessWidget {
  const _TryALabelCard({
    required this.controller,
    required this.rules,
    required this.onChanged,
  });

  final TextEditingController controller;
  final List<ScaleBarcodeRule> rules;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final code = controller.text.trim();
    final match = code.isEmpty ? null : parseScaleBarcode(code, rules);

    return PointyDetailSection(
      icon: Icons.qr_code_scanner_outlined,
      title: l10n.scaleRuleTryTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.scaleRuleTryDescription,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          SizedBox(height: spacing.sm),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              hintText: l10n.scaleRuleTryHint,
              prefixIcon: const Icon(Icons.barcode_reader),
              suffixIcon: code.isEmpty
                  ? null
                  : IconButton(
                      tooltip: l10n.clearBarcodeStatusTooltip,
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        controller.clear();
                        onChanged();
                      },
                    ),
            ),
            onChanged: (_) => onChanged(),
          ),
          if (code.isNotEmpty) ...[
            SizedBox(height: spacing.sm),
            _TryResult(match: match, l10n: l10n),
          ],
        ],
      ),
    );
  }
}

/// What the configured rules make of the code in the field — the only check on
/// this screen a shop can perform with a sticker in its hand.
class _TryResult extends StatelessWidget {
  const _TryResult({required this.match, required this.l10n});

  final ScaleBarcodeMatch? match;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final found = match != null;
    final tone = found ? colors.primaryStrong : colors.warning;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color.alphaBlend(tone.withValues(alpha: 0.08), colors.surface),
        border: Border.all(color: tone.withValues(alpha: 0.22)),
        borderRadius: BorderRadius.circular(PointyRadii.chip),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              found ? Icons.check_circle_outline : Icons.help_outline,
              size: 18,
              color: tone,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    found
                        ? l10n.scaleRuleTryResult(
                            match!.itemCode,
                            _describeValue(l10n, match!),
                          )
                        : l10n.scaleRuleTryUnreadable,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: tone),
                  ),
                  if (found)
                    Text(
                      match!.rule.name,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _describeValue(AppLocalizations l10n, ScaleBarcodeMatch match) {
  final value = match.value;
  return switch (match.valueKind) {
    ScaleValueKind.weight => '$value ${unitLabel(l10n, match.rule.valueUnit)}',
    // With the currency on it, so a glance at the example says which of the two
    // kinds of label this rule reads without reading the rule.
    ScaleValueKind.price => formatMoney(value),
    ScaleValueKind.count => '$value',
  };
}

String _kindLabel(AppLocalizations l10n, ScaleValueKind kind) {
  return switch (kind) {
    ScaleValueKind.weight => l10n.scaleRuleValueKindWeight,
    ScaleValueKind.price => l10n.scaleRuleValueKindPrice,
    ScaleValueKind.count => l10n.scaleRuleValueKindCount,
  };
}

/// The rule, said the way a shopkeeper would say it.
///
/// Nobody buying a scale has ever read `21IIIIIVVVVVC`, and a list that leads
/// with it is a list they cannot check. The pattern stays — underneath, dimmed,
/// for whoever set the scale up — but the line that decides whether this rule
/// looks right says "starts with 21, five digits for the item, then the weight".
String _plainSummary(AppLocalizations l10n, ScaleBarcodeRule rule) {
  final prefix = rule.pattern.split('').takeWhile(_isDigitChar).join();
  final itemDigits = kScaleItemChar.allMatches(rule.pattern).length;
  final value = switch (rule.valueKind) {
    ScaleValueKind.weight => l10n.scaleRuleValueWeight,
    ScaleValueKind.price => l10n.scaleRuleValuePrice,
    ScaleValueKind.count => l10n.scaleRuleValueCount,
  };
  return l10n.scaleRulePlainSummary(prefix, itemDigits, value);
}

bool _isDigitChar(String char) {
  final code = char.codeUnitAt(0);
  return code >= 0x30 && code <= 0x39;
}

/// A worked example: the code a scale would print, and what this rule makes of
/// it. The half after the arrow is the part a shop can actually verify against
/// a sticker in its hand.
String? _exampleLine(AppLocalizations l10n, ScaleBarcodeRule rule) {
  if (!rule.isUsable) {
    return null;
  }
  final value = rule.valueKind == ScaleValueKind.price ? 12.5 : 1.5;
  final code = buildScaleCode(rule, '12345', value);
  if (code.isEmpty) {
    return null;
  }
  final match = parseScaleBarcode(code, [rule]);
  if (match == null) {
    return null;
  }
  return l10n.scaleRuleExampleReads(code, _describeValue(l10n, match));
}

enum _ScaleRuleAction { edit, delete }

class _ScaleRuleTile extends StatelessWidget {
  const _ScaleRuleTile({
    required this.rule,
    required this.onEdit,
    required this.onDelete,
  });

  final ScaleBarcodeRule rule;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final example = _exampleLine(l10n, rule);

    return PointySettingsSection(
      children: [
        ListTile(
          onTap: onEdit,
          leading: Icon(
            Icons.monitor_weight_outlined,
            color: rule.isActive ? colors.primaryStrong : colors.mutedInk,
          ),
          title: Text(rule.name),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_plainSummary(l10n, rule)),
              if (example != null)
                Text(
                  example,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
              // The pattern itself stays visible, dimmed, for whoever set the
              // scale up — but it is never the line the shop reads first.
              Text(
                rule.pattern,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              ),
            ],
          ),
          trailing: PopupMenuButton<_ScaleRuleAction>(
            tooltip: l10n.moreActionsTooltip,
            icon: const Icon(Icons.more_vert),
            onSelected: (action) => switch (action) {
              _ScaleRuleAction.edit => onEdit(),
              _ScaleRuleAction.delete => onDelete(),
            },
            itemBuilder: (menuContext) => [
              PopupMenuItem(
                value: _ScaleRuleAction.edit,
                child: Text(l10n.editButton),
              ),
              PopupMenuItem(
                value: _ScaleRuleAction.delete,
                child: Text(l10n.deleteButton),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The editor asks for the shape of a label in the terms printed on a scale's
/// own settings page — where it starts, how many digits the item code is, how
/// many the value — and assembles the pattern from that. The pattern itself
/// stays editable underneath for the shop whose scale does something unusual.
class _ScaleRuleEditorDialog extends StatefulWidget {
  const _ScaleRuleEditorDialog({this.rule});

  final ScaleBarcodeRule? rule;

  @override
  State<_ScaleRuleEditorDialog> createState() => _ScaleRuleEditorDialogState();
}

class _ScaleRuleEditorDialogState extends State<_ScaleRuleEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _pattern;
  late ScaleValueKind _kind;
  late int _decimals;
  late String _unit;
  late bool _requireCheckDigit;
  late bool _isActive;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _name = TextEditingController(text: rule?.name ?? '');
    _pattern = TextEditingController(text: rule?.pattern ?? '21IIIIIVVVVVC');
    _kind = rule?.valueKind ?? ScaleValueKind.weight;
    _decimals = rule?.valueDecimals ?? 3;
    _unit = rule?.valueUnit ?? 'kg';
    _requireCheckDigit = rule?.requireCheckDigit ?? true;
    _isActive = rule?.isActive ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _pattern.dispose();
    super.dispose();
  }

  ScaleBarcodeRule get _preview => ScaleBarcodeRule(
    pattern: _pattern.text.trim().toUpperCase(),
    valueKind: _kind,
    valueDecimals: _decimals,
    valueUnit: _unit,
    requireCheckDigit: _requireCheckDigit,
    name: _name.text,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final preview = _preview;
    final example = _exampleLine(l10n, preview);

    return AlertDialog(
      title: Text(l10n.scaleRuleEditTitle),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: l10n.scaleRuleNameLabel,
                  hintText: l10n.scaleRuleNameHint,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pattern,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp('[0-9IiVvCcXx]')),
                  LengthLimitingTextInputFormatter(32),
                ],
                decoration: InputDecoration(
                  labelText: l10n.scaleRulePatternLabel,
                  helperText: l10n.scaleRulePatternHelp,
                  helperMaxLines: 3,
                  errorText: preview.isUsable
                      ? null
                      : l10n.scaleRulePatternInvalid,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.scaleRuleValueKindLabel,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              SegmentedButton<ScaleValueKind>(
                segments: [
                  for (final kind in ScaleValueKind.values)
                    ButtonSegment(
                      value: kind,
                      label: Text(_kindLabel(l10n, kind)),
                    ),
                ],
                selected: {_kind},
                onSelectionChanged: (selection) => setState(() {
                  _kind = selection.first;
                  // Money is two decimals; grams inside five digits are three.
                  _decimals = _kind == ScaleValueKind.price
                      ? 2
                      : _kind == ScaleValueKind.count
                      ? 0
                      : 3;
                }),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _decimals,
                      decoration: InputDecoration(
                        labelText: l10n.scaleRuleDecimalsLabel,
                      ),
                      items: [
                        for (var index = 0; index <= 3; index++)
                          DropdownMenuItem(value: index, child: Text('$index')),
                      ],
                      onChanged: (value) =>
                          setState(() => _decimals = value ?? _decimals),
                    ),
                  ),
                  if (_kind == ScaleValueKind.weight) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _unit,
                        decoration: InputDecoration(
                          labelText: l10n.scaleRuleUnitLabel,
                        ),
                        items: [
                          for (final code in const ['kg', 'g', 'l', 'ml', 'm'])
                            DropdownMenuItem(
                              value: code,
                              child: Text(unitLabel(l10n, code)),
                            ),
                        ],
                        onChanged: (value) =>
                            setState(() => _unit = value ?? _unit),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _requireCheckDigit,
                title: Text(l10n.scaleRuleRequireCheckDigitLabel),
                subtitle: Text(l10n.scaleRuleRequireCheckDigitHint),
                onChanged: (value) =>
                    setState(() => _requireCheckDigit = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _isActive,
                title: Text(l10n.scaleRuleActiveLabel),
                onChanged: (value) => setState(() => _isActive = value),
              ),
              if (example != null) ...[
                const SizedBox(height: 8),
                Text(
                  example,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          onPressed: preview.isUsable && _name.text.trim().isNotEmpty
              ? () => Navigator.of(context).pop(<String, Object?>{
                  'name': _name.text.trim(),
                  'pattern': preview.pattern,
                  'value_kind': _kind.wireName,
                  'value_decimals': _decimals,
                  'value_unit': _unit,
                  'require_check_digit': _requireCheckDigit,
                  'is_active': _isActive,
                })
              : null,
          child: Text(l10n.saveButton),
        ),
      ],
    );
  }
}
