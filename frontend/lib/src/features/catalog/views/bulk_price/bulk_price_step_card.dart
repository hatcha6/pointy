import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/bulk_price_rule.dart';
import '../../../../shared/components/components.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';
import '../../view_models/bulk_price_editor_view_model.dart';
import 'bulk_price_condition_editor.dart';
import 'bulk_price_labels.dart';

enum _StepMenu { up, down, duplicate, remove }

/// One link of the price chain.
class BulkPriceStepCard extends StatelessWidget {
  const BulkPriceStepCard({
    super.key,
    required this.step,
    required this.index,
    required this.count,
    required this.viewModel,
    required this.pickRefs,
    required this.conditionFields,
  });

  final BulkPriceStep step;
  final int index;
  final int count;
  final BulkPriceEditorViewModel viewModel;
  final BulkPriceRefPicker pickRefs;
  final List<BulkPriceField> conditionFields;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final theme = Theme.of(context);
    final hits = viewModel.stepHits(index);
    final isLast = index == count - 1;
    final actions = [
      for (final group in bulkPriceActionGroups)
        for (final action in group)
          if (!action.needsCost ||
              viewModel.costVisible ||
              action == step.action)
            action,
    ];

    final actionMenu = DropdownButtonFormField<BulkPriceAction>(
      key: ValueKey('bulk_price_action_${step.key}'),
      initialValue: step.action,
      isExpanded: true,
      decoration: const InputDecoration(isDense: true),
      selectedItemBuilder: (context) => [
        for (final action in actions)
          Row(
            children: [
              Icon(bulkPriceActionIcon(action), size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  l10n.actionLabel(action),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
      ],
      items: [
        for (final action in actions)
          DropdownMenuItem(
            value: action,
            child: Row(
              children: [
                Icon(bulkPriceActionIcon(action), size: 18),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    l10n.actionLabel(action),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
      onChanged: (action) {
        if (action != null) viewModel.setStepAction(step.key, action);
      },
    );

    final valueField = BulkPriceTextField(
      fieldKey: 'bulk_price_step_value_${step.key}',
      initialValue: step.value,
      issue: step.valueIssue,
      numeric: true,
      suffix: bulkPriceUnitFor(step.action.valueKind),
      onChanged: (text) =>
          viewModel.updateStep(step.key, (s) => s.copyWith(value: text)),
    );

    final example = _example(step);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _StepBadge(number: index + 1),
                const SizedBox(width: 10),
                Expanded(child: actionMenu),
                PopupMenuButton<_StepMenu>(
                  tooltip: l10n.bulkPriceStepMenuTooltip,
                  icon: const Icon(Icons.more_vert),
                  onSelected: (choice) => switch (choice) {
                    _StepMenu.up => viewModel.moveStep(step.key, -1),
                    _StepMenu.down => viewModel.moveStep(step.key, 1),
                    _StepMenu.duplicate => viewModel.duplicateStep(step.key),
                    _StepMenu.remove => viewModel.removeStep(step.key),
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: _StepMenu.up,
                      enabled: index > 0,
                      child: _MenuRow(Icons.arrow_upward, l10n.bulkPriceMoveUp),
                    ),
                    PopupMenuItem(
                      value: _StepMenu.down,
                      enabled: !isLast,
                      child: _MenuRow(
                        Icons.arrow_downward,
                        l10n.bulkPriceMoveDown,
                      ),
                    ),
                    PopupMenuItem(
                      value: _StepMenu.duplicate,
                      enabled: viewModel.canAddStep,
                      child: _MenuRow(Icons.copy, l10n.bulkPriceDuplicateStep),
                    ),
                    PopupMenuItem(
                      value: _StepMenu.remove,
                      child: _MenuRow(
                        Icons.delete_outline,
                        l10n.bulkPriceRemoveStep,
                        color: colors.danger,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              // Indented under the step number where there is room for it.
              padding: EdgeInsetsDirectional.only(
                start: MediaQuery.sizeOf(context).width >= 480 ? 38 : 0,
                end: 8,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final direction = step.action.hasDirection
                          ? SegmentedButton<BulkPriceDirection>(
                              key: ValueKey('bulk_price_direction_${step.key}'),
                              showSelectedIcon: false,
                              style: const ButtonStyle(
                                visualDensity: VisualDensity.compact,
                              ),
                              segments: [
                                for (final value in BulkPriceDirection.values)
                                  ButtonSegment(
                                    value: value,
                                    label: Text(l10n.directionLabel(value)),
                                  ),
                              ],
                              selected: {step.direction},
                              onSelectionChanged: (selection) =>
                                  viewModel.updateStep(
                                    step.key,
                                    (s) =>
                                        s.copyWith(direction: selection.first),
                                  ),
                            )
                          : null;
                      if (direction == null) {
                        return Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: SizedBox(
                            width: math.min(220, constraints.maxWidth),
                            child: valueField,
                          ),
                        );
                      }
                      return Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SizedBox(
                            width: math.min(160, constraints.maxWidth),
                            child: valueField,
                          ),
                          direction,
                        ],
                      );
                    },
                  ),
                  if (example != null || hits != null) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (hits != null)
                          PointyStatusPill(
                            key: ValueKey('bulk_price_step_hits_${step.key}'),
                            label: l10n.bulkPriceStepHits(hits),
                            icon: Icons.done_all,
                            color: hits == 0
                                ? colors.mutedInk
                                : colors.primaryStrong,
                          ),
                        if (example != null)
                          Text(
                            example.cost == null
                                ? l10n.bulkPriceStepExample(
                                    example.before,
                                    example.after,
                                  )
                                : l10n.bulkPriceStepExampleCost(
                                    example.before,
                                    example.cost!,
                                    example.after,
                                  ),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.mutedInk,
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilterChip(
                        key: ValueKey('bulk_price_step_when_${step.key}'),
                        avatar: const Icon(Icons.filter_alt_outlined, size: 18),
                        label: Text(l10n.bulkPriceStepWhenToggle),
                        selected: step.when != null,
                        showCheckmark: false,
                        onSelected: (value) =>
                            viewModel.setStepConditional(step.key, value),
                      ),
                      if (!isLast)
                        FilterChip(
                          key: ValueKey('bulk_price_step_stop_${step.key}'),
                          avatar: const Icon(Icons.block, size: 18),
                          tooltip: l10n.bulkPriceStepStopHint,
                          label: Text(l10n.bulkPriceStepStop),
                          selected: step.stop,
                          showCheckmark: false,
                          onSelected: (value) => viewModel.updateStep(
                            step.key,
                            (s) => s.copyWith(stop: value),
                          ),
                        ),
                    ],
                  ),
                  if (step.when != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        12,
                        8,
                        4,
                        4,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surfaceSunken,
                        borderRadius: BorderRadius.circular(PointyRadii.card),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            l10n.bulkPriceStepWhenTitle,
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            l10n.bulkPriceStepWhenHint,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.mutedInk,
                            ),
                          ),
                          const SizedBox(height: 4),
                          BulkPriceGroupEditor(
                            group: step.when!,
                            viewModel: viewModel,
                            pickRefs: pickRefs,
                            availableFields: conditionFields,
                            allowNesting: false,
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "10.00 ← 11.00" for this step on a sample shelf price (and, for the
  /// cost steps, a sample cost) — so "تقريب للأعلى 0.25" means something
  /// before the preview loads.
  static ({String before, String? cost, String after})? _example(
    BulkPriceStep step,
  ) {
    if (step.valueIssue != null) return null;
    final value = double.parse(normalizeDigits(step.value));
    final rounding =
        step.action == BulkPriceAction.round ||
        step.action == BulkPriceAction.ending;
    // Cost steps start under the target so the example shows them lifting.
    final price = rounding ? 12.37 : (step.action.needsCost ? 8.5 : 10.0);
    const cost = 8.0;
    double after;
    switch (step.action) {
      case BulkPriceAction.increasePercent:
        after = price * (100 + value) / 100;
      case BulkPriceAction.decreasePercent:
        after = price * (100 - value) / 100;
      case BulkPriceAction.increaseAmount:
        after = price + value;
      case BulkPriceAction.decreaseAmount:
        after = math.max(0, price - value);
      case BulkPriceAction.set:
        after = value;
      case BulkPriceAction.costMarkup:
        after = cost * (100 + value) / 100;
      case BulkPriceAction.costPlus:
        after = cost + value;
      case BulkPriceAction.minMarkup:
        after = math.max(price, cost * (100 + value) / 100);
      case BulkPriceAction.minPrice:
        after = math.max(price, value);
      case BulkPriceAction.maxPrice:
        after = math.min(price, value);
      case BulkPriceAction.round:
        final steps = price / value;
        after =
            switch (step.direction) {
              BulkPriceDirection.up => steps.ceilToDouble(),
              BulkPriceDirection.down => steps.floorToDouble(),
              BulkPriceDirection.nearest => steps.roundToDouble(),
            } *
            value;
      case BulkPriceAction.ending:
        final cycle = value >= 1
            ? math.pow(10, value.truncate().toString().length).toDouble()
            : 1.0;
        final base = (price / cycle).floorToDouble() * cycle + value;
        final upper = base >= price ? base : base + cycle;
        final lower = upper - cycle;
        after = switch (step.direction) {
          BulkPriceDirection.up => upper,
          BulkPriceDirection.down => lower < 0 ? upper : lower,
          BulkPriceDirection.nearest =>
            lower < 0 || (upper - price) <= (price - lower) ? upper : lower,
        };
    }
    return (
      before: formatMoney(price),
      cost: step.action.needsCost ? formatMoney(cost) : null,
      after: formatMoney(after),
    );
  }
}

class _StepBadge extends StatelessWidget {
  const _StepBadge({required this.number});

  final int number;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colors.primary, shape: BoxShape.circle),
      child: Text(
        '$number',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: colors.surface,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label, {this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}

/// The arrow between two steps: the price flows down the chain.
class BulkPriceStepConnector extends StatelessWidget {
  const BulkPriceStepConnector({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 24),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Icon(Icons.south, size: 18, color: colors.lineStrong),
      ),
    );
  }
}
