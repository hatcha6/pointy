part of 'discount_rule_form.dart';

// ---------------------------------------------------------------------------
// Building blocks
// ---------------------------------------------------------------------------

class _DiscountSummaryCard extends StatelessWidget {
  const _DiscountSummaryCard({
    required this.headline,
    required this.subhead,
    required this.chips,
  });

  final String headline;
  final String subhead;
  final List<String> chips;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        border: Border.all(color: colors.primaryStrong.withValues(alpha: 0.25)),
      ),
      padding: EdgeInsets.all(spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.local_offer_outlined,
                size: 18,
                color: colors.primaryStrong,
              ),
              SizedBox(width: spacing.xs),
              Text(
                AppLocalizations.of(context)!.discountFormSummaryTitle,
                style: textTheme.labelMedium?.copyWith(
                  color: colors.primaryStrong,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SizedBox(height: spacing.sm),
          Text(
            headline,
            style: textTheme.headlineSmall?.copyWith(
              color: colors.primaryDark,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            subhead,
            style: textTheme.bodySmall?.copyWith(color: colors.primaryStrong),
          ),
          SizedBox(height: spacing.sm),
          Wrap(
            spacing: spacing.xs,
            runSpacing: spacing.xs,
            children: [for (final chip in chips) PointyStatusPill(label: chip)],
          ),
        ],
      ),
    );
  }
}

class _FormSection extends StatelessWidget {
  const _FormSection({
    required this.icon,
    required this.title,
    required this.children,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Container(
      margin: EdgeInsetsDirectional.only(bottom: spacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
        boxShadow: PointyShadows.raised,
      ),
      padding: EdgeInsets.all(spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.primaryStrong.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 19, color: colors.primaryStrong),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: spacing.md),
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(height: spacing.sm),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _ValueTypeSelector extends StatelessWidget {
  const _ValueTypeSelector({
    required this.selected,
    required this.labelFor,
    required this.helpFor,
    required this.onSelected,
  });

  final DiscountValueType selected;
  final String Function(DiscountValueType type) labelFor;
  final String Function(DiscountValueType type) helpFor;
  final ValueChanged<DiscountValueType> onSelected;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return Column(
      children: [
        for (var i = 0; i < DiscountValueType.values.length; i++) ...[
          if (i > 0) SizedBox(height: spacing.xs),
          _ValueTypeOption(
            label: labelFor(DiscountValueType.values[i]),
            help: helpFor(DiscountValueType.values[i]),
            selected: selected == DiscountValueType.values[i],
            onTap: () => onSelected(DiscountValueType.values[i]),
          ),
        ],
      ],
    );
  }
}

class _ValueTypeOption extends StatelessWidget {
  const _ValueTypeOption({
    required this.label,
    required this.help,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String help;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: selected ? colors.primaryContainer : colors.surface,
      borderRadius: BorderRadius.circular(PointyRadii.chip),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(PointyRadii.chip),
            border: Border.all(
              color: selected ? colors.primaryStrong : colors.line,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 20,
                color: selected ? colors.primaryStrong : colors.mutedInk,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: selected ? colors.primaryDark : colors.ink,
                      ),
                    ),
                    Text(
                      help,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineSwitch extends StatelessWidget {
  const _InlineSwitch({
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      dense: true,
      contentPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      title: Text(label),
      subtitle: subtitle == null ? null : Text(subtitle!),
      onChanged: onChanged,
    );
  }
}

class _NoteLine extends StatelessWidget {
  const _NoteLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Row(
      children: [
        Icon(icon, size: 16, color: colors.mutedInk),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ),
      ],
    );
  }
}

class _RoundingPresetChips extends StatelessWidget {
  const _RoundingPresetChips({
    required this.selectedValue,
    required this.values,
    required this.onSelected,
  });

  final String selectedValue;
  final List<String> values;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final normalized = selectedValue.trim().replaceAll(',', '.');
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final value in values)
          ChoiceChip(
            label: Text(value),
            selected: normalized == value,
            onSelected: (_) => onSelected(value),
          ),
      ],
    );
  }
}

class _SegmentedField<T> extends StatelessWidget {
  const _SegmentedField({
    required this.label,
    required this.selected,
    required this.values,
    required this.labelFor,
    required this.onSelected,
  });

  final String label;
  final T selected;
  final List<T> values;
  final String Function(T value) labelFor;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: colors.mutedInk),
        ),
        const SizedBox(height: 6),
        SegmentedButton<T>(
          showSelectedIcon: false,
          segments: [
            for (final value in values)
              ButtonSegment<T>(value: value, label: Text(labelFor(value))),
          ],
          selected: {selected},
          onSelectionChanged: (values) => onSelected(values.first),
        ),
      ],
    );
  }
}

class _ResponsiveFields extends StatelessWidget {
  const _ResponsiveFields({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ResponsiveFormGrid(children: children);
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onPick,
    required this.onClear,
  });

  final String label;
  final DateTime? value;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = value == null
        ? l10n.discountNoDateSelected
        : '${value!.year}/${value!.month.toString().padLeft(2, '0')}/${value!.day.toString().padLeft(2, '0')}';
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.calendar_month_outlined),
      ),
      child: Row(
        children: [
          Expanded(child: Text(text, overflow: TextOverflow.ellipsis)),
          IconButton(
            tooltip: l10n.discountPickDateTooltip,
            onPressed: onPick,
            icon: const Icon(Icons.edit_calendar_outlined),
            visualDensity: VisualDensity.compact,
          ),
          if (value != null)
            IconButton(
              tooltip: l10n.clearButton,
              onPressed: onClear,
              icon: const Icon(Icons.close),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}
