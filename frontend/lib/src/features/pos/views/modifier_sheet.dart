import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/modifier_group.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_variant.dart';
import '../../../shared/formatters.dart';

/// Fast modifier picker. Opens with sensible defaults preselected so the common
/// case is a single "Add" tap. Big chips, minimal reading. Returns the chosen
/// modifiers, or null if dismissed. [initial] preselects an existing selection
/// when editing a line from the cart.
Future<List<CartLineModifier>?> showModifierSheet(
  BuildContext context, {
  required Product product,
  required ProductVariant variant,
  List<CartLineModifier> initial = const [],
}) {
  return showModalBottomSheet<List<CartLineModifier>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) =>
        _ModifierSheet(product: product, variant: variant, initial: initial),
  );
}

class _ModifierSheet extends StatefulWidget {
  const _ModifierSheet({
    required this.product,
    required this.variant,
    required this.initial,
  });

  final Product product;
  final ProductVariant variant;
  final List<CartLineModifier> initial;

  @override
  State<_ModifierSheet> createState() => _ModifierSheetState();
}

class _ModifierSheetState extends State<_ModifierSheet> {
  /// optionId → selected quantity (absent/0 = not selected).
  final Map<int, int> _quantities = {};

  @override
  void initState() {
    super.initState();
    if (widget.initial.isNotEmpty) {
      for (final modifier in widget.initial) {
        _quantities[modifier.optionId] = modifier.quantity;
      }
    } else {
      // Preselect the defaults so required groups are satisfied up front and the
      // common case is one tap on "Add".
      for (final group in widget.product.modifierGroups) {
        for (final option in group.options) {
          if (option.isDefault) {
            _quantities[option.id] = 1;
          }
        }
      }
    }
  }

  ModifierOption? _optionById(int id) {
    for (final group in widget.product.modifierGroups) {
      for (final option in group.options) {
        if (option.id == id) {
          return option;
        }
      }
    }
    return null;
  }

  int _selectedCountIn(ModifierGroup group) {
    return group.options
        .where((option) => (_quantities[option.id] ?? 0) > 0)
        .length;
  }

  bool get _allRequiredSatisfied {
    for (final group in widget.product.modifierGroups) {
      if (group.minSelect >= 1 && _selectedCountIn(group) < group.minSelect) {
        return false;
      }
    }
    return true;
  }

  double get _lineUnitPrice {
    var price = widget.variant.unitPrice;
    _quantities.forEach((optionId, quantity) {
      final option = _optionById(optionId);
      if (option != null) {
        price += option.priceDelta * quantity;
      }
    });
    return price;
  }

  void _selectSingle(ModifierGroup group, ModifierOption option) {
    setState(() {
      for (final other in group.options) {
        _quantities.remove(other.id);
      }
      _quantities[option.id] = 1;
    });
  }

  void _toggleMulti(ModifierOption option) {
    setState(() {
      if ((_quantities[option.id] ?? 0) > 0) {
        _quantities.remove(option.id);
      } else {
        _quantities[option.id] = 1;
      }
    });
  }

  void _setQuantity(ModifierOption option, int quantity) {
    setState(() {
      final clamped = quantity.clamp(0, option.maxQuantity);
      if (clamped <= 0) {
        _quantities.remove(option.id);
      } else {
        _quantities[option.id] = clamped;
      }
    });
  }

  List<CartLineModifier> _selection() {
    final selection = <CartLineModifier>[];
    for (final group in widget.product.modifierGroups) {
      for (final option in group.options) {
        final quantity = _quantities[option.id] ?? 0;
        if (quantity > 0) {
          selection.add(
            CartLineModifier(
              groupId: group.id,
              optionId: option.id,
              groupName: group.name,
              optionName: option.name,
              priceDelta: option.priceDelta,
              quantity: quantity,
            ),
          );
        }
      }
    }
    return selection;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            widget.product.sellableName,
            style: theme.textTheme.titleLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final group in widget.product.modifierGroups)
                  _ModifierGroupSection(
                    group: group,
                    quantities: _quantities,
                    onSelectSingle: (option) => _selectSingle(group, option),
                    onToggleMulti: _toggleMulti,
                    onSetQuantity: _setQuantity,
                  ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton(
            onPressed: _allRequiredSatisfied
                ? () => Navigator.of(context).pop(_selection())
                : null,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            child: Text(
              l10n.modifierSheetAddButton(formatMoney(_lineUnitPrice)),
            ),
          ),
        ),
      ],
    );
  }
}

class _ModifierGroupSection extends StatelessWidget {
  const _ModifierGroupSection({
    required this.group,
    required this.quantities,
    required this.onSelectSingle,
    required this.onToggleMulti,
    required this.onSetQuantity,
  });

  final ModifierGroup group;
  final Map<int, int> quantities;
  final ValueChanged<ModifierOption> onSelectSingle;
  final ValueChanged<ModifierOption> onToggleMulti;
  final void Function(ModifierOption option, int quantity) onSetQuantity;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final maxSelect = group.maxSelect;
    final hint = group.isRequired
        ? l10n.modifierGroupRequiredLabel
        : (maxSelect != null && maxSelect > 1)
        ? l10n.modifierGroupChooseUpToLabel(maxSelect)
        : l10n.modifierGroupOptionalLabel;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Text(group.name, style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text(
                  hint,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ],
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in group.options)
                _ModifierChip(
                  group: group,
                  option: option,
                  quantity: quantities[option.id] ?? 0,
                  onSelectSingle: onSelectSingle,
                  onToggleMulti: onToggleMulti,
                  onSetQuantity: onSetQuantity,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModifierChip extends StatelessWidget {
  const _ModifierChip({
    required this.group,
    required this.option,
    required this.quantity,
    required this.onSelectSingle,
    required this.onToggleMulti,
    required this.onSetQuantity,
  });

  final ModifierGroup group;
  final ModifierOption option;
  final int quantity;
  final ValueChanged<ModifierOption> onSelectSingle;
  final ValueChanged<ModifierOption> onToggleMulti;
  final void Function(ModifierOption option, int quantity) onSetQuantity;

  String get _label {
    if (option.priceDelta > 0) {
      return '${option.name}  +${formatMoney(option.priceDelta)}';
    }
    return option.name;
  }

  @override
  Widget build(BuildContext context) {
    final selected = quantity > 0;

    // Quantifiable options always render with an inline stepper.
    if (option.isQuantifiable) {
      final colorScheme = Theme.of(context).colorScheme;
      return Material(
        color: selected ? colorScheme.secondaryContainer : colorScheme.surface,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? colorScheme.secondary : colorScheme.outlineVariant,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: quantity > 0
                    ? () => onSetQuantity(option, quantity - 1)
                    : null,
                icon: const Icon(Icons.remove, size: 18),
              ),
              Text(selected ? '$_label  ×$quantity' : _label),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: quantity < option.maxQuantity
                    ? () => onSetQuantity(option, quantity + 1)
                    : null,
                icon: const Icon(Icons.add, size: 18),
              ),
            ],
          ),
        ),
      );
    }

    if (group.isSingleSelect) {
      return ChoiceChip(
        label: Text(_label),
        selected: selected,
        onSelected: (_) => onSelectSingle(option),
      );
    }

    return FilterChip(
      label: Text(_label),
      selected: selected,
      onSelected: (_) => onToggleMulti(option),
    );
  }
}
