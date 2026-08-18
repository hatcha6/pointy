import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/parsing.dart';
import '../../../core/result.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/discount_rule.dart';
import '../../../data/models/product_query.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/async_selection/async_selection.dart';
import '../../../shared/components/components.dart';
import '../../../shared/customer_rank_presentation.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/product_category_picker.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/discount_management_view_model.dart';

part 'discount_rule_form_widgets.dart';

/// Single-scroll discount editor: a live plain-language summary anchors the
/// form, and each concern lives in its own card with optional details revealed
/// only when needed. Replaces the old 5-step wizard.
class DiscountRuleForm extends StatefulWidget {
  const DiscountRuleForm({
    super.key,
    required this.viewModel,
    required this.catalogRepository,
    required this.contactRepository,
    required this.onSaved,
    this.rule,
  });

  final DiscountManagementViewModel viewModel;
  final CatalogRepository catalogRepository;
  final ContactRepository contactRepository;
  final DiscountRule? rule;
  final VoidCallback onSaved;

  @override
  State<DiscountRuleForm> createState() => _DiscountRuleFormState();
}

class _DiscountRuleFormState extends State<DiscountRuleForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _couponCodeController;
  late final TextEditingController _valueController;
  late final TextEditingController _maxDiscountController;
  late final TextEditingController _roundingIncrementController;
  late final TextEditingController _minSubtotalController;
  late final TextEditingController _minLineQuantityController;
  late final TextEditingController _groupSizeController;
  late final TextEditingController _buyQuantityController;
  late final TextEditingController _getQuantityController;
  late final TextEditingController _priorityController;
  late final TextEditingController _usageLimitController;
  late final TextEditingController _perCustomerLimitController;
  late final TextEditingController _perSupplierLimitController;
  late final List<TextEditingController> _liveControllers;
  Timer? _summaryDebounce;

  late DiscountChannel _channel;
  late DiscountApplicationType _applicationType;
  late DiscountScope _scope;
  late DiscountValueType _valueType;
  late DiscountBuyGetReward _rewardType;
  late List<_TierFieldRow> _tiers;
  late DiscountRoundingMode _roundingMode;
  late bool _exclusive;
  late bool _isActive;
  late bool _showDescription;
  late bool _showMaximumDiscount;
  late bool _enableRounding;
  late bool _limitByMinimumSubtotal;
  late bool _limitByMinimumLineQuantity;
  late bool _limitByProducts;
  late bool _limitByContacts;
  late bool _limitByRank;
  late bool _showSchedule;
  late bool _showUsageLimits;
  late bool _showAdvancedSettings;
  late List<AsyncSelectionOption<int>> _selectedProducts;
  late List<AsyncSelectionOption<int>> _selectedVariants;
  late List<AsyncSelectionOption<int>> _selectedProductCategories;
  late List<AsyncSelectionOption<int>> _selectedCustomers;
  late List<AsyncSelectionOption<int>> _selectedSuppliers;
  late List<CustomerRank> _selectedRanks;
  DateTime? _startsAt;
  DateTime? _endsAt;

  /// Snapshot of all editable state captured after initState seeding, so the
  /// unsaved-changes guard can diff both create and edit forms accurately.
  late final String _initialSignature;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _nameController = TextEditingController(text: rule?.name ?? '');
    _descriptionController = TextEditingController(
      text: rule?.description ?? '',
    );
    _couponCodeController = TextEditingController(text: rule?.couponCode ?? '');
    _valueController = TextEditingController(
      text: rule == null ? '' : _formatDecimal(rule.value),
    );
    _maxDiscountController = TextEditingController(
      text: rule?.maxDiscountAmount == null
          ? ''
          : _formatMoney(rule!.maxDiscountAmount!),
    );
    _roundingIncrementController = TextEditingController(
      text: rule?.roundingIncrement == null
          ? '0.25'
          : _formatMoney(rule!.roundingIncrement!),
    );
    _minSubtotalController = TextEditingController(
      text: rule == null ? '0.00' : _formatMoney(rule.minOrderSubtotal),
    );
    _minLineQuantityController = TextEditingController(
      text: rule?.minLineQuantity?.toString() ?? '',
    );
    _groupSizeController = TextEditingController(
      text: rule?.groupSize?.toString() ?? '',
    );
    _buyQuantityController = TextEditingController(
      text: rule?.buyQuantity?.toString() ?? '',
    );
    _getQuantityController = TextEditingController(
      text: rule?.getQuantity?.toString() ?? '',
    );
    _priorityController = TextEditingController(
      text: '${rule?.priority ?? 100}',
    );
    _usageLimitController = TextEditingController(
      text: rule?.usageLimit?.toString() ?? '',
    );
    _perCustomerLimitController = TextEditingController(
      text: rule?.perCustomerUsageLimit?.toString() ?? '',
    );
    _perSupplierLimitController = TextEditingController(
      text: rule?.perSupplierUsageLimit?.toString() ?? '',
    );
    _channel = rule?.channel ?? DiscountChannel.sales;
    _applicationType =
        rule?.applicationType ?? DiscountApplicationType.automatic;
    _scope = rule?.scope ?? DiscountScope.document;
    _valueType = rule?.valueType ?? DiscountValueType.percentage;
    _rewardType = rule?.rewardType ?? DiscountBuyGetReward.free;
    _tiers = [
      for (final tier in rule?.tiers ?? const <DiscountTier>[])
        _TierFieldRow(
          minQuantity: tier.minQuantity.toString(),
          unitPrice: _formatMoney(tier.unitPrice),
        ),
    ];
    if (_valueType == DiscountValueType.tiered && _tiers.isEmpty) {
      _tiers.add(_TierFieldRow());
    }
    final savedRoundingMode = rule?.roundingMode ?? DiscountRoundingMode.none;
    _roundingMode = savedRoundingMode == DiscountRoundingMode.none
        ? DiscountRoundingMode.down
        : savedRoundingMode;
    _exclusive = rule?.exclusive ?? true;
    _isActive = rule?.isActive ?? true;
    _selectedProducts = _selectionsFromIds(rule?.products ?? const []);
    _selectedVariants = _selectionsFromIds(rule?.variants ?? const []);
    _selectedProductCategories = _selectionsFromIds(
      rule?.productCategories ?? const [],
    );
    _selectedCustomers = _selectionsFromIds(rule?.customers ?? const []);
    _selectedSuppliers = _selectionsFromIds(rule?.suppliers ?? const []);
    _selectedRanks = List.of(rule?.customerRanks ?? const <CustomerRank>[]);
    _startsAt = rule?.startsAt;
    _endsAt = rule?.endsAt;
    _showDescription = _descriptionController.text.trim().isNotEmpty;
    _showMaximumDiscount = rule?.maxDiscountAmount != null;
    _enableRounding = savedRoundingMode != DiscountRoundingMode.none;
    _limitByMinimumSubtotal = (rule?.minOrderSubtotal ?? 0) > 0;
    _limitByMinimumLineQuantity = rule?.minLineQuantity != null;
    _limitByProducts =
        _selectedProducts.isNotEmpty ||
        _selectedVariants.isNotEmpty ||
        _selectedProductCategories.isNotEmpty;
    _limitByContacts =
        _selectedCustomers.isNotEmpty || _selectedSuppliers.isNotEmpty;
    _limitByRank = _selectedRanks.isNotEmpty;
    _showSchedule = _startsAt != null || _endsAt != null;
    _showUsageLimits =
        rule?.usageLimit != null ||
        rule?.perCustomerUsageLimit != null ||
        rule?.perSupplierUsageLimit != null;
    _showAdvancedSettings =
        rule != null && (!rule.exclusive || rule.priority != 100);

    // Keep the live summary in sync with free-text fields.
    _liveControllers = [
      _nameController,
      _couponCodeController,
      _valueController,
      _groupSizeController,
      _buyQuantityController,
      _getQuantityController,
      _maxDiscountController,
      _roundingIncrementController,
      _minSubtotalController,
      _minLineQuantityController,
      _priorityController,
      _usageLimitController,
    ];
    for (final controller in _liveControllers) {
      controller.addListener(_onLiveChanged);
    }
    _initialSignature = _formSignature();
  }

  @override
  void dispose() {
    _summaryDebounce?.cancel();
    for (final controller in _liveControllers) {
      controller.removeListener(_onLiveChanged);
    }
    _nameController.dispose();
    _descriptionController.dispose();
    _couponCodeController.dispose();
    _valueController.dispose();
    _maxDiscountController.dispose();
    _roundingIncrementController.dispose();
    _minSubtotalController.dispose();
    _minLineQuantityController.dispose();
    _priorityController.dispose();
    _usageLimitController.dispose();
    _perCustomerLimitController.dispose();
    _perSupplierLimitController.dispose();
    _groupSizeController.dispose();
    _buyQuantityController.dispose();
    _getQuantityController.dispose();
    for (final tier in _tiers) {
      tier.dispose();
    }
    super.dispose();
  }

  void _onLiveChanged() {
    // The live summary rebuilds the whole form, including the constraint chips
    // computed over the selected products/categories/customers. Debounce so a
    // burst of keystrokes only rebuilds once the user pauses typing.
    _summaryDebounce?.cancel();
    _summaryDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        setState(() {});
      }
    });
  }

  /// A stable string of every editable field (excluding pure UI-expansion
  /// toggles), compared against [_initialSignature] to detect unsaved edits.
  String _formSignature() {
    String ids(List<AsyncSelectionOption<int>> options) =>
        (options.map((option) => option.id).toList()..sort()).join(',');
    return <Object?>[
      _nameController.text,
      _descriptionController.text,
      _couponCodeController.text,
      _valueController.text,
      _groupSizeController.text,
      _buyQuantityController.text,
      _getQuantityController.text,
      _maxDiscountController.text,
      _roundingIncrementController.text,
      _minSubtotalController.text,
      _minLineQuantityController.text,
      _priorityController.text,
      _usageLimitController.text,
      _perCustomerLimitController.text,
      _perSupplierLimitController.text,
      _channel,
      _applicationType,
      _scope,
      _valueType,
      _rewardType,
      _tiers
          .map(
            (tier) =>
                '${tier.minQuantityController.text}:${tier.unitPriceController.text}',
          )
          .join(','),
      _roundingMode,
      _exclusive,
      _isActive,
      _enableRounding,
      _limitByMinimumSubtotal,
      _limitByMinimumLineQuantity,
      _limitByProducts,
      _limitByContacts,
      ids(_selectedProducts),
      ids(_selectedVariants),
      ids(_selectedProductCategories),
      ids(_selectedCustomers),
      ids(_selectedSuppliers),
      _startsAt?.toIso8601String(),
      _endsAt?.toIso8601String(),
    ].join('|');
  }

  bool get _isDirty => _formSignature() != _initialSignature;

  @override
  Widget build(BuildContext context) {
    return PointyUnsavedChangesGuard(
      isDirty: () => _isDirty,
      child: _buildForm(context),
    );
  }

  Widget _buildForm(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return Column(
      children: [
        Expanded(
          child: Form(
            key: _formKey,
            // The form is one long scroll, so a field can sit far off-screen.
            // Validating each field as it loses focus surfaces the problem
            // where the cashier is looking, and clears the error the moment
            // they fix it — instead of holding every complaint until Save.
            autovalidateMode: AutovalidateMode.onUnfocus,
            child: ListView(
              key: const ValueKey('discount_rule_form_scroll'),
              padding: EdgeInsets.fromLTRB(
                spacing.lg,
                spacing.sm,
                spacing.lg,
                spacing.lg,
              ),
              children: [
                Text(
                  widget.rule == null
                      ? l10n.discountCreateTitle
                      : l10n.discountEditTitle,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                SizedBox(height: spacing.md),
                _DiscountSummaryCard(
                  headline: _summaryHeadline(l10n),
                  subhead: _summarySubhead(l10n),
                  chips: _summaryChips(l10n),
                ),
                SizedBox(height: spacing.md),
                _essentialsSection(l10n),
                _valueSection(l10n),
                _targetingSection(l10n),
                _conditionsSection(l10n),
                _scheduleLimitsSection(l10n),
                _advancedSection(l10n),
              ],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(top: BorderSide(color: colors.line)),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              spacing.lg,
              spacing.sm,
              spacing.lg,
              spacing.md,
            ),
            child: SizedBox(
              height: PointyDimensions.buttonHeight,
              child: FilledButton.icon(
                key: const ValueKey('discount_rule_save_button'),
                onPressed: widget.viewModel.isSaving ? null : _submit,
                icon: widget.viewModel.isSaving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: Text(l10n.discountSaveButton),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // -- sections ----------------------------------------------------------

  Widget _essentialsSection(AppLocalizations l10n) {
    return _FormSection(
      icon: Icons.sell_outlined,
      title: l10n.discountWizardStepBasics,
      subtitle: l10n.discountSectionBasicsHint,
      children: [
        TextFormField(
          controller: _nameController,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: l10n.discountNameLabel,
            prefixIcon: const Icon(Icons.label_outline),
          ),
          validator: (value) => value == null || value.trim().isEmpty
              ? l10n.requiredFieldError
              : null,
        ),
        _SegmentedField<DiscountChannel>(
          label: l10n.discountChannelLabel,
          selected: _channel,
          values: DiscountChannel.values,
          labelFor: (value) => _channelLabel(l10n, value),
          onSelected: (value) => setState(() => _channel = value),
        ),
        _SegmentedField<DiscountApplicationType>(
          label: l10n.discountApplicationTypeLabel,
          selected: _applicationType,
          values: DiscountApplicationType.values,
          labelFor: (value) => _applicationLabel(l10n, value),
          onSelected: (value) => setState(() => _applicationType = value),
        ),
        if (_applicationType == DiscountApplicationType.couponCode)
          TextFormField(
            controller: _couponCodeController,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: l10n.discountCouponCodeLabel,
              hintText: l10n.discountCouponCodeHint,
              prefixIcon: const Icon(Icons.confirmation_number_outlined),
            ),
            validator: (value) {
              if (_applicationType == DiscountApplicationType.couponCode &&
                  (value == null || value.trim().isEmpty)) {
                return l10n.requiredFieldError;
              }
              return null;
            },
          ),
        _InlineSwitch(
          label: l10n.discountActiveLabel,
          value: _isActive,
          onChanged: (value) => setState(() => _isActive = value),
        ),
        _InlineSwitch(
          label: l10n.discountWizardDescriptionToggle,
          value: _showDescription,
          onChanged: (value) => setState(() => _showDescription = value),
        ),
        if (_showDescription)
          TextFormField(
            controller: _descriptionController,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: l10n.discountDescriptionLabel,
              prefixIcon: const Icon(Icons.notes_outlined),
            ),
          ),
      ],
    );
  }

  Widget _valueSection(AppLocalizations l10n) {
    final scopeLocked =
        _valueType == DiscountValueType.fixedPrice ||
        _valueType == DiscountValueType.fixedUnitAmount ||
        _valueType.isQuantityPromotion;
    return _FormSection(
      icon: Icons.price_change_outlined,
      title: l10n.discountWizardStepValue,
      subtitle: l10n.discountSectionValueHint,
      children: [
        _ValueTypeSelector(
          selected: _valueType,
          labelFor: (type) => _valueTypeLabel(l10n, type),
          helpFor: (type) => _valueTypeHelp(l10n, type),
          onSelected: (value) {
            setState(() {
              _valueType = value;
              if (value == DiscountValueType.fixedPrice ||
                  value == DiscountValueType.fixedUnitAmount ||
                  value.isQuantityPromotion) {
                _scope = DiscountScope.line;
              }
              if (value == DiscountValueType.tiered && _tiers.isEmpty) {
                _tiers.add(_TierFieldRow());
              }
            });
          },
        ),
        ..._valueInputs(l10n),
        if (scopeLocked)
          _NoteLine(icon: Icons.info_outline, text: l10n.discountScopeAutoNote)
        else
          _SegmentedField<DiscountScope>(
            label: l10n.discountScopeLabel,
            selected: _scope,
            values: DiscountScope.values,
            labelFor: (value) => _scopeLabel(l10n, value),
            onSelected: (value) => setState(() => _scope = value),
          ),
        _InlineSwitch(
          label: l10n.discountWizardMaximumDiscountToggle,
          value: _showMaximumDiscount,
          onChanged: (value) => setState(() => _showMaximumDiscount = value),
        ),
        if (_showMaximumDiscount)
          TextFormField(
            controller: _maxDiscountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
            decoration: InputDecoration(
              labelText: l10n.discountMaxAmountLabel,
              prefixIcon: const Icon(Icons.production_quantity_limits_outlined),
            ),
            validator: _validateOptionalPositiveAmount,
          ),
        _InlineSwitch(
          label: l10n.discountWizardRoundingToggle,
          value: _enableRounding,
          onChanged: (value) => setState(() => _enableRounding = value),
        ),
        if (_enableRounding) ...[
          _SegmentedField<DiscountRoundingMode>(
            label: l10n.discountRoundingModeLabel,
            selected: _roundingMode,
            values: const [
              DiscountRoundingMode.down,
              DiscountRoundingMode.nearest,
              DiscountRoundingMode.up,
            ],
            labelFor: (value) => _roundingModeLabel(l10n, value),
            onSelected: (value) => setState(() => _roundingMode = value),
          ),
          _RoundingPresetChips(
            selectedValue: _roundingIncrementController.text,
            values: const ['0.25', '0.50', '1.00', '5.00'],
            onSelected: (value) =>
                setState(() => _roundingIncrementController.text = value),
          ),
          TextFormField(
            controller: _roundingIncrementController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
            decoration: InputDecoration(
              labelText: l10n.discountRoundingIncrementLabel,
              prefixIcon: const Icon(Icons.straighten_outlined),
            ),
            validator: _validateRoundingIncrement,
          ),
        ],
      ],
    );
  }

  /// The value inputs that vary by value type: a single value field for the
  /// classic types, or the quantity-promotion parameters (group size + price,
  /// the tier editor, or buy/get + reward).
  List<Widget> _valueInputs(AppLocalizations l10n) {
    switch (_valueType) {
      case DiscountValueType.multiBuy:
        return [
          _quantityField(
            controller: _groupSizeController,
            label: l10n.discountGroupSizeLabel,
            icon: Icons.tag_outlined,
          ),
          _decimalField(
            controller: _valueController,
            label: l10n.discountGroupPriceLabel,
            icon: Icons.payments_outlined,
            validator: _validateRequiredPositiveAmount,
          ),
        ];
      case DiscountValueType.tiered:
        return [_buildTierEditor(l10n)];
      case DiscountValueType.buyXGetY:
        return [
          _ResponsiveFields(
            children: [
              _quantityField(
                controller: _buyQuantityController,
                label: l10n.discountBuyQuantityLabel,
                icon: Icons.shopping_basket_outlined,
              ),
              _quantityField(
                controller: _getQuantityController,
                label: l10n.discountGetQuantityLabel,
                icon: Icons.card_giftcard_outlined,
              ),
            ],
          ),
          _SegmentedField<DiscountBuyGetReward>(
            label: l10n.discountRewardTypeLabel,
            selected: _rewardType,
            values: DiscountBuyGetReward.values,
            labelFor: (value) => _rewardLabel(l10n, value),
            onSelected: (value) => setState(() => _rewardType = value),
          ),
          if (_rewardType != DiscountBuyGetReward.free)
            _decimalField(
              controller: _valueController,
              label: _rewardType == DiscountBuyGetReward.percentage
                  ? l10n.discountValueLabel
                  : l10n.discountRewardFixedPrice,
              icon: Icons.tag_outlined,
              suffixText: _rewardType == DiscountBuyGetReward.percentage
                  ? '%'
                  : null,
              validator: _validateRewardValue,
            ),
        ];
      case DiscountValueType.percentage:
      case DiscountValueType.fixedAmount:
      case DiscountValueType.fixedUnitAmount:
      case DiscountValueType.fixedPrice:
        return [
          _decimalField(
            controller: _valueController,
            label: l10n.discountValueLabel,
            icon: Icons.tag_outlined,
            suffixText: _valueType == DiscountValueType.percentage ? '%' : null,
            validator: _validatePositiveDecimal,
          ),
        ];
    }
  }

  Widget _quantityField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
      validator: _validatePositiveInteger,
    );
  }

  Widget _decimalField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required String? Function(String?) validator,
    String? suffixText,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [DecimalTextInputFormatter()],
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        suffixText: suffixText,
      ),
      validator: validator,
    );
  }

  Widget _buildTierEditor(AppLocalizations l10n) {
    final spacing = AdaptiveSpacing.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _NoteLine(icon: Icons.info_outline, text: l10n.discountTiersHint),
        for (var i = 0; i < _tiers.length; i++) ...[
          SizedBox(height: spacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextFormField(
                  controller: _tiers[i].minQuantityController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: l10n.discountTierMinQuantityLabel,
                    prefixIcon: const Icon(Icons.numbers_outlined),
                  ),
                  validator: _validatePositiveInteger,
                ),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: TextFormField(
                  controller: _tiers[i].unitPriceController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [DecimalTextInputFormatter()],
                  decoration: InputDecoration(
                    labelText: l10n.discountTierUnitPriceLabel,
                    prefixIcon: const Icon(Icons.payments_outlined),
                  ),
                  validator: _validateTierUnitPrice,
                ),
              ),
              IconButton(
                tooltip: l10n.discountRemoveTierTooltip,
                onPressed: _tiers.length <= 1 ? null : () => _removeTier(i),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ],
        SizedBox(height: spacing.sm),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: () => setState(() => _tiers.add(_TierFieldRow())),
            icon: const Icon(Icons.add),
            label: Text(l10n.discountAddTierButton),
          ),
        ),
      ],
    );
  }

  void _removeTier(int index) {
    final removed = _tiers.removeAt(index);
    setState(() {});
    // Dispose after the rebuild drops the row so the field never reads a
    // disposed controller.
    WidgetsBinding.instance.addPostFrameCallback((_) => removed.dispose());
  }

  Widget _targetingSection(AppLocalizations l10n) {
    final showCustomerFields = _channel != DiscountChannel.purchasing;
    final showSupplierFields = _channel != DiscountChannel.sales;
    return _FormSection(
      icon: Icons.adjust_outlined,
      title: l10n.discountSectionTargeting,
      subtitle: l10n.discountSectionTargetingHint,
      children: [
        _InlineSwitch(
          label: l10n.discountWizardProductScopeToggle,
          value: _limitByProducts,
          onChanged: (value) => setState(() => _limitByProducts = value),
        ),
        if (_limitByProducts) _buildProductConstraints(l10n),
        _InlineSwitch(
          label: l10n.discountWizardContactScopeToggle,
          value: _limitByContacts,
          onChanged: (value) => setState(() => _limitByContacts = value),
        ),
        if (_limitByContacts)
          _buildContactConstraints(
            l10n,
            showCustomerFields: showCustomerFields,
            showSupplierFields: showSupplierFields,
          ),
        if (showCustomerFields) ...[
          _InlineSwitch(
            label: l10n.discountRankScopeToggle,
            subtitle: l10n.discountRankScopeHint,
            value: _limitByRank,
            onChanged: (value) => setState(() => _limitByRank = value),
          ),
          if (_limitByRank) _buildRankConstraints(l10n),
        ],
      ],
    );
  }

  /// Multi-select of RFM ranks the discount targets. Ranks are assigned
  /// automatically by the backend, so a rule keyed on a rank keeps targeting the
  /// right segment as customers move between ranks over time.
  Widget _buildRankConstraints(AppLocalizations l10n) {
    final spacing = AdaptiveSpacing.of(context);
    return Padding(
      padding: EdgeInsets.only(top: spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.discountRankConstraintLabel,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: context.pointyColors.mutedInk,
            ),
          ),
          SizedBox(height: spacing.xs),
          Wrap(
            spacing: spacing.sm,
            runSpacing: spacing.xs,
            children: [
              for (final rank in _targetableRanks) _rankFilterChip(rank),
            ],
          ),
        ],
      ),
    );
  }

  Widget _rankFilterChip(CustomerRank rank) {
    final style = customerRankStyle(context, rank);
    final selected = _selectedRanks.contains(rank);
    return FilterChip(
      avatar: Icon(style.icon, size: 18, color: style.color),
      label: Text(style.label),
      selected: selected,
      onSelected: (value) {
        setState(() {
          if (value) {
            _selectedRanks = [..._selectedRanks, rank];
          } else {
            _selectedRanks = _selectedRanks
                .where((item) => item != rank)
                .toList();
          }
        });
      },
    );
  }

  /// Ranks offered as discount targets — every scored segment. "No purchases"
  /// (inactive) is excluded: it has no recognized history to reward or win back.
  static const List<CustomerRank> _targetableRanks = [
    CustomerRank.champion,
    CustomerRank.loyal,
    CustomerRank.potentialLoyalist,
    CustomerRank.newCustomer,
    CustomerRank.promising,
    CustomerRank.needsAttention,
    CustomerRank.atRisk,
    CustomerRank.cantLose,
    CustomerRank.hibernating,
    CustomerRank.lost,
  ];

  Widget _conditionsSection(AppLocalizations l10n) {
    return _FormSection(
      icon: Icons.rule_outlined,
      title: l10n.discountSectionConditions,
      subtitle: l10n.discountSectionConditionsHint,
      children: [
        _InlineSwitch(
          label: l10n.discountWizardMinimumSubtotalToggle,
          value: _limitByMinimumSubtotal,
          onChanged: (value) => setState(() => _limitByMinimumSubtotal = value),
        ),
        if (_limitByMinimumSubtotal)
          TextFormField(
            controller: _minSubtotalController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
            decoration: InputDecoration(
              labelText: l10n.discountMinSubtotalLabel,
              prefixIcon: const Icon(Icons.shopping_cart_outlined),
            ),
            validator: _validateOptionalNonNegativeDecimal,
          ),
        if (_scope == DiscountScope.line && !_valueType.isQuantityPromotion)
          _InlineSwitch(
            label: l10n.discountWizardMinimumLineQuantityToggle,
            value: _limitByMinimumLineQuantity,
            onChanged: (value) =>
                setState(() => _limitByMinimumLineQuantity = value),
          ),
        if (_scope == DiscountScope.line &&
            !_valueType.isQuantityPromotion &&
            _limitByMinimumLineQuantity)
          TextFormField(
            controller: _minLineQuantityController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: l10n.discountMinLineQuantityLabel,
              prefixIcon: const Icon(Icons.numbers_outlined),
            ),
            validator: _validateOptionalPositiveInteger,
          ),
      ],
    );
  }

  Widget _scheduleLimitsSection(AppLocalizations l10n) {
    return _FormSection(
      icon: Icons.event_available_outlined,
      title: l10n.discountWizardStepLimits,
      subtitle: l10n.discountSectionScheduleHint,
      children: [
        _InlineSwitch(
          label: l10n.discountWizardScheduleToggle,
          value: _showSchedule,
          onChanged: (value) => setState(() => _showSchedule = value),
        ),
        if (_showSchedule)
          _ResponsiveFields(
            children: [
              _DateField(
                label: l10n.discountStartsAtLabel,
                value: _startsAt,
                onPick: () => _pickDate(isStart: true),
                onClear: () => setState(() => _startsAt = null),
              ),
              _DateField(
                label: l10n.discountEndsAtLabel,
                value: _endsAt,
                onPick: () => _pickDate(isStart: false),
                onClear: () => setState(() => _endsAt = null),
              ),
            ],
          ),
        _InlineSwitch(
          label: l10n.discountWizardUsageLimitsToggle,
          value: _showUsageLimits,
          onChanged: (value) => setState(() => _showUsageLimits = value),
        ),
        if (_showUsageLimits)
          _ResponsiveFields(
            children: [
              TextFormField(
                controller: _usageLimitController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: l10n.discountUsageLimitLabel,
                  prefixIcon: const Icon(Icons.confirmation_number_outlined),
                ),
                validator: _validateOptionalPositiveInteger,
              ),
              if (_channel != DiscountChannel.purchasing)
                TextFormField(
                  controller: _perCustomerLimitController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: l10n.discountPerCustomerLimitLabel,
                    prefixIcon: const Icon(Icons.person_outline),
                  ),
                  validator: _validatePerCustomerLimit,
                ),
              if (_channel != DiscountChannel.sales)
                TextFormField(
                  controller: _perSupplierLimitController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: l10n.discountPerSupplierLimitLabel,
                    prefixIcon: const Icon(Icons.local_shipping_outlined),
                  ),
                  validator: _validatePerSupplierLimit,
                ),
            ],
          ),
      ],
    );
  }

  Widget _advancedSection(AppLocalizations l10n) {
    return _FormSection(
      icon: Icons.tune_outlined,
      title: l10n.discountSectionAdvanced,
      subtitle: l10n.discountSectionAdvancedHint,
      children: [
        _InlineSwitch(
          label: l10n.discountWizardAdvancedToggle,
          value: _showAdvancedSettings,
          onChanged: (value) => setState(() => _showAdvancedSettings = value),
        ),
        if (_showAdvancedSettings) ...[
          TextFormField(
            controller: _priorityController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: l10n.discountPriorityLabel,
              prefixIcon: const Icon(Icons.low_priority_outlined),
            ),
            validator: _validatePositiveInteger,
          ),
          _InlineSwitch(
            label: l10n.discountExclusiveLabel,
            subtitle: l10n.discountExclusiveHelper,
            value: _exclusive,
            onChanged: (value) => setState(() => _exclusive = value),
          ),
        ],
      ],
    );
  }

  Widget _buildProductConstraints(AppLocalizations l10n) {
    return _ResponsiveFields(
      children: [
        AsyncSelectionField<int>(
          key: ValueKey(
            'product_categories_${_selectedProductCategories.map((item) => item.id).join('_')}',
          ),
          fieldKey: const ValueKey('discount_product_category_picker_field'),
          strings: _constraintFieldStrings(
            l10n,
            label: l10n.discountProductCategoryIdsLabel,
          ),
          selected: _selectedProductCategories,
          onPick: () => _pickProductCategories(context),
          onClear: _selectedProductCategories.isEmpty
              ? null
              : () => setState(() => _selectedProductCategories = []),
          validator: (_) => null,
        ),
        AsyncSelectionField<int>(
          key: ValueKey(
            'products_${_selectedProducts.map((item) => item.id).join('_')}',
          ),
          fieldKey: const ValueKey('discount_product_picker_field'),
          strings: _constraintFieldStrings(
            l10n,
            label: l10n.discountProductIdsLabel,
          ),
          selected: _selectedProducts,
          onPick: () => _pickProducts(context),
          onClear: _selectedProducts.isEmpty
              ? null
              : () => setState(() => _selectedProducts = []),
          validator: (_) => null,
        ),
        AsyncSelectionField<int>(
          key: ValueKey(
            'variants_${_selectedVariants.map((item) => item.id).join('_')}',
          ),
          fieldKey: const ValueKey('discount_variant_picker_field'),
          strings: _constraintFieldStrings(
            l10n,
            label: l10n.discountVariantIdsLabel,
          ),
          selected: _selectedVariants,
          onPick: () => _pickVariants(context),
          onClear: _selectedVariants.isEmpty
              ? null
              : () => setState(() => _selectedVariants = []),
          validator: (_) => null,
        ),
      ],
    );
  }

  Widget _buildContactConstraints(
    AppLocalizations l10n, {
    required bool showCustomerFields,
    required bool showSupplierFields,
  }) {
    return _ResponsiveFields(
      children: [
        if (showCustomerFields)
          AsyncSelectionField<int>(
            key: ValueKey(
              'customers_${_selectedCustomers.map((item) => item.id).join('_')}',
            ),
            fieldKey: const ValueKey('discount_customer_picker_field'),
            strings: _constraintFieldStrings(
              l10n,
              label: l10n.discountCustomerIdsLabel,
            ),
            selected: _selectedCustomers,
            onPick: () => _pickCustomers(context),
            onClear: _selectedCustomers.isEmpty
                ? null
                : () => setState(() => _selectedCustomers = []),
            validator: (_) => _validateCustomerSelection(),
          ),
        if (showSupplierFields)
          AsyncSelectionField<int>(
            key: ValueKey(
              'suppliers_${_selectedSuppliers.map((item) => item.id).join('_')}',
            ),
            fieldKey: const ValueKey('discount_supplier_picker_field'),
            strings: _constraintFieldStrings(
              l10n,
              label: l10n.discountSupplierIdsLabel,
            ),
            selected: _selectedSuppliers,
            onPick: () => _pickSuppliers(context),
            onClear: _selectedSuppliers.isEmpty
                ? null
                : () => setState(() => _selectedSuppliers = []),
            validator: (_) => _validateSupplierSelection(),
          ),
      ],
    );
  }

  // -- live summary ------------------------------------------------------

  String _summaryHeadline(AppLocalizations l10n) {
    switch (_valueType) {
      case DiscountValueType.multiBuy:
        final size = int.tryParse(_groupSizeController.text.trim()) ?? 0;
        final price = _valueController.text.trim();
        if (size <= 0 || price.isEmpty) {
          return l10n.discountSummaryPlaceholder;
        }
        return l10n.discountMultiBuyValue(size, price);
      case DiscountValueType.tiered:
        final cheapest = _cheapestTierPrice();
        if (cheapest == null) {
          return l10n.discountSummaryPlaceholder;
        }
        return l10n.discountTieredValue(_formatMoney(cheapest));
      case DiscountValueType.buyXGetY:
        final buy = int.tryParse(_buyQuantityController.text.trim()) ?? 0;
        final get = int.tryParse(_getQuantityController.text.trim()) ?? 0;
        if (buy <= 0 || get <= 0) {
          return l10n.discountSummaryPlaceholder;
        }
        return l10n.discountBuyGetValue(buy, get);
      case DiscountValueType.percentage:
      case DiscountValueType.fixedAmount:
      case DiscountValueType.fixedUnitAmount:
      case DiscountValueType.fixedPrice:
        final raw = _valueController.text.trim();
        if (raw.isEmpty) {
          return l10n.discountSummaryPlaceholder;
        }
        if (_valueType == DiscountValueType.percentage) {
          return l10n.discountPercentageValue(raw);
        }
        return raw;
    }
  }

  double? _cheapestTierPrice() {
    double? best;
    for (final tier in _tiers) {
      final text = tier.unitPriceController.text.trim().replaceAll(',', '.');
      final value = double.tryParse(text);
      if (value != null && (best == null || value < best)) {
        best = value;
      }
    }
    return best;
  }

  String? _promoSummaryChip(AppLocalizations l10n) {
    switch (_valueType) {
      case DiscountValueType.tiered:
        final count = _tiers
            .where((tier) => tier.unitPriceController.text.trim().isNotEmpty)
            .length;
        return count > 0 ? l10n.discountTierCountSummary(count) : null;
      case DiscountValueType.buyXGetY:
        final value = _valueController.text.trim().isEmpty
            ? '0'
            : _valueController.text.trim();
        return switch (_rewardType) {
          DiscountBuyGetReward.free => l10n.discountRewardSummaryFree,
          DiscountBuyGetReward.percentage =>
            l10n.discountRewardSummaryPercentage(value),
          DiscountBuyGetReward.fixedPrice =>
            l10n.discountRewardSummaryFixedPrice(value),
        };
      case DiscountValueType.multiBuy:
      case DiscountValueType.percentage:
      case DiscountValueType.fixedAmount:
      case DiscountValueType.fixedUnitAmount:
      case DiscountValueType.fixedPrice:
        return null;
    }
  }

  String _summarySubhead(AppLocalizations l10n) {
    return '${_valueTypeLabel(l10n, _valueType)} · ${_scopeLabel(l10n, _scope)}';
  }

  List<String> _summaryChips(AppLocalizations l10n) {
    final chips = <String>[_channelLabel(l10n, _channel)];
    final promoChip = _promoSummaryChip(l10n);
    if (promoChip != null) {
      chips.add(promoChip);
    }
    if (_applicationType == DiscountApplicationType.couponCode) {
      final code = _couponCodeController.text.trim().toUpperCase();
      chips.add(
        code.isEmpty
            ? _applicationLabel(l10n, _applicationType)
            : l10n.discountCouponSummary(code),
      );
    }

    if (_limitByProducts &&
        (_selectedProductCategories.isNotEmpty ||
            _selectedProducts.isNotEmpty ||
            _selectedVariants.isNotEmpty)) {
      if (_selectedProductCategories.isNotEmpty) {
        chips.add(
          l10n.discountProductCategoryConstraintSummary(
            _selectedProductCategories.length,
          ),
        );
      }
      if (_selectedProducts.isNotEmpty) {
        chips.add(
          l10n.discountProductConstraintSummary(_selectedProducts.length),
        );
      }
      if (_selectedVariants.isNotEmpty) {
        chips.add(
          l10n.discountVariantConstraintSummary(_selectedVariants.length),
        );
      }
    } else {
      chips.add(l10n.discountSummaryAppliesAll);
    }

    if (_limitByContacts) {
      if (_channel != DiscountChannel.purchasing &&
          _selectedCustomers.isNotEmpty) {
        chips.add(
          l10n.discountCustomerConstraintSummary(_selectedCustomers.length),
        );
      }
      if (_channel != DiscountChannel.sales && _selectedSuppliers.isNotEmpty) {
        chips.add(
          l10n.discountSupplierConstraintSummary(_selectedSuppliers.length),
        );
      }
    }

    if (_limitByRank &&
        _channel != DiscountChannel.purchasing &&
        _selectedRanks.isNotEmpty) {
      chips.add(l10n.discountRankConstraintSummary(_selectedRanks.length));
    }

    if (_limitByMinimumSubtotal &&
        _minSubtotalController.text.trim().isNotEmpty) {
      chips.add(
        l10n.discountMinSubtotalSummary(_minSubtotalController.text.trim()),
      );
    }
    if (_scope == DiscountScope.line &&
        _limitByMinimumLineQuantity &&
        _minLineQuantityController.text.trim().isNotEmpty) {
      chips.add(
        l10n.discountMinLineQuantitySummary(
          int.tryParse(_minLineQuantityController.text.trim()) ?? 0,
        ),
      );
    }
    if (_showMaximumDiscount && _maxDiscountController.text.trim().isNotEmpty) {
      chips.add(
        l10n.discountMaxAmountSummary(_maxDiscountController.text.trim()),
      );
    }
    if (_showSchedule && _startsAt != null) {
      chips.add(l10n.discountStartsAtSummary(_formatDate(_startsAt!)));
    }
    if (_showSchedule && _endsAt != null) {
      chips.add(l10n.discountEndsAtSummary(_formatDate(_endsAt!)));
    }
    if (_showUsageLimits && _usageLimitController.text.trim().isNotEmpty) {
      chips.add(
        l10n.discountUsageSummary(
          0,
          int.tryParse(_usageLimitController.text.trim()) ?? 0,
        ),
      );
    }
    if (_showAdvancedSettings && _exclusive) {
      chips.add(l10n.discountExclusiveShort);
    }
    if (!_isActive) {
      chips.add(l10n.discountStatusInactive);
    }
    return chips;
  }

  // -- submit ------------------------------------------------------------

  /// The value submitted to the API: tiered rules derive it server-side (empty),
  /// a free buy-X-get-Y reward is sent as 100 (= 100% off), otherwise the value
  /// field is used verbatim.
  String _valueForSubmit() {
    if (_valueType == DiscountValueType.tiered) {
      return '';
    }
    if (_valueType == DiscountValueType.buyXGetY &&
        _rewardType == DiscountBuyGetReward.free) {
      return '100';
    }
    return _valueController.text;
  }

  List<DiscountTier> _collectTiers() {
    final tiers = <DiscountTier>[];
    for (final row in _tiers) {
      final quantity = int.tryParse(row.minQuantityController.text.trim());
      final price = double.tryParse(
        row.unitPriceController.text.trim().replaceAll(',', '.'),
      );
      if (quantity != null && quantity > 0 && price != null && price >= 0) {
        tiers.add(DiscountTier(minQuantity: quantity, unitPrice: price));
      }
    }
    return tiers;
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    final invalidFields =
        _formKey.currentState?.validateGranularly() ??
        const <FormFieldState<Object?>>{};
    if (invalidFields.isNotEmpty) {
      _revealField(invalidFields);
      _showError(l10n.discountFormFixFieldsError);
      return;
    }
    if (_showSchedule &&
        _startsAt != null &&
        _endsAt != null &&
        !_endsAt!.isAfter(_startsAt!)) {
      _showError(l10n.discountDateRangeError);
      return;
    }
    if (_valueType == DiscountValueType.tiered && _collectTiers().isEmpty) {
      _showError(l10n.discountTiersRequiredError);
      return;
    }

    final draft = DiscountRuleDraft(
      name: _nameController.text,
      description: _showDescription ? _descriptionController.text : '',
      channel: _channel,
      applicationType: _applicationType,
      couponCode: _couponCodeController.text,
      scope: _scope,
      valueType: _valueType,
      value: _valueForSubmit(),
      groupSize: _valueType == DiscountValueType.multiBuy
          ? _groupSizeController.text
          : '',
      buyQuantity: _valueType == DiscountValueType.buyXGetY
          ? _buyQuantityController.text
          : '',
      getQuantity: _valueType == DiscountValueType.buyXGetY
          ? _getQuantityController.text
          : '',
      rewardType: _valueType == DiscountValueType.buyXGetY ? _rewardType : null,
      tiers: _valueType == DiscountValueType.tiered
          ? _collectTiers()
          : const [],
      maxDiscountAmount: _showMaximumDiscount
          ? _maxDiscountController.text
          : '',
      roundingMode: _enableRounding ? _roundingMode : DiscountRoundingMode.none,
      roundingIncrement: _enableRounding
          ? _roundingIncrementController.text
          : '',
      minOrderSubtotal: _limitByMinimumSubtotal
          ? _minSubtotalController.text
          : '0.00',
      minLineQuantity:
          _scope == DiscountScope.line &&
              _limitByMinimumLineQuantity &&
              !_valueType.isQuantityPromotion
          ? _minLineQuantityController.text
          : '',
      priority: _showAdvancedSettings ? _priorityController.text : '100',
      exclusive: _showAdvancedSettings ? _exclusive : true,
      isActive: _isActive,
      startsAt: _showSchedule ? _startsAt : null,
      endsAt: _showSchedule ? _endsAt : null,
      usageLimit: _showUsageLimits ? _usageLimitController.text : '',
      perCustomerUsageLimit:
          _showUsageLimits && _channel != DiscountChannel.purchasing
          ? _perCustomerLimitController.text
          : '',
      perSupplierUsageLimit:
          _showUsageLimits && _channel != DiscountChannel.sales
          ? _perSupplierLimitController.text
          : '',
      products: _limitByProducts
          ? _selectedProducts.map((item) => item.id).toList()
          : const [],
      variants: _limitByProducts
          ? _selectedVariants.map((item) => item.id).toList()
          : const [],
      productCategories: _limitByProducts
          ? _selectedProductCategories.map((item) => item.id).toList()
          : const [],
      customers: _limitByContacts && _channel != DiscountChannel.purchasing
          ? _selectedCustomers.map((item) => item.id).toList()
          : const [],
      customerRanks: _limitByRank && _channel != DiscountChannel.purchasing
          ? List.of(_selectedRanks)
          : const [],
      suppliers: _limitByContacts && _channel != DiscountChannel.sales
          ? _selectedSuppliers.map((item) => item.id).toList()
          : const [],
      metadata: widget.rule?.metadata ?? const {},
    );

    final rule = widget.rule;
    final saved = rule == null
        ? await widget.viewModel.createRule(draft)
        : await widget.viewModel.updateRule(rule: rule, draft: draft);
    if (!mounted) {
      return;
    }
    if (saved) {
      widget.onSaved();
    } else {
      _showError(l10n.discountSaveError);
    }
  }

  /// Scrolls the highest invalid field into view so a failed save points at the
  /// field that blocked it. The form is one tall scroll, so the offender is
  /// often above or below the fold; picking the smallest global `dy` keeps the
  /// choice in visual order rather than in the order fields happened to mount.
  void _revealField(Set<FormFieldState<Object?>> invalidFields) {
    FormFieldState<Object?>? topmost;
    double? topmostOffset;
    for (final field in invalidFields) {
      final box = field.context.findRenderObject();
      if (box is! RenderBox || !box.hasSize) {
        continue;
      }
      final offset = box.localToGlobal(Offset.zero).dy;
      if (topmostOffset == null || offset < topmostOffset) {
        topmostOffset = offset;
        topmost = field;
      }
    }
    final target = topmost;
    if (target == null) {
      return;
    }
    unawaited(
      Scrollable.ensureVisible(
        target.context,
        alignment: 0.2,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatDate(DateTime value) {
    return '${value.year}/${value.month.toString().padLeft(2, '0')}/${value.day.toString().padLeft(2, '0')}';
  }

  Future<void> _pickDate({required bool isStart}) async {
    final current = isStart ? _startsAt : _endsAt;
    final selected = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (selected == null || !mounted) {
      return;
    }
    setState(() {
      if (isStart) {
        _startsAt = DateTime(selected.year, selected.month, selected.day);
      } else {
        _endsAt = DateTime(selected.year, selected.month, selected.day, 23, 59);
      }
    });
  }

  // -- validators --------------------------------------------------------

  String? _validatePositiveDecimal(String? value) {
    final l10n = AppLocalizations.of(context)!;
    final parsed = parseDecimal(value);
    if (parsed == null || parsed <= 0) {
      return l10n.positiveNumberError;
    }
    if (_valueType == DiscountValueType.percentage && parsed > 100) {
      return l10n.discountPercentError;
    }
    if ((_valueType == DiscountValueType.fixedPrice ||
            _valueType == DiscountValueType.fixedUnitAmount) &&
        _scope != DiscountScope.line) {
      return l10n.discountLineOnlyValueTypeError;
    }
    return null;
  }

  String? _validateOptionalPositiveAmount(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    final parsed = parseDecimal(value);
    if (parsed == null || parsed <= 0) {
      return AppLocalizations.of(context)!.positiveNumberError;
    }
    return null;
  }

  String? _validateRequiredPositiveAmount(String? value) {
    final parsed = parseDecimal(value);
    if (parsed == null || parsed <= 0) {
      return AppLocalizations.of(context)!.positiveNumberError;
    }
    return null;
  }

  String? _validateRewardValue(String? value) {
    final l10n = AppLocalizations.of(context)!;
    final parsed = parseDecimal(value);
    if (parsed == null || parsed <= 0) {
      return l10n.positiveNumberError;
    }
    if (_rewardType == DiscountBuyGetReward.percentage && parsed > 100) {
      return l10n.discountPercentError;
    }
    return null;
  }

  String? _validateTierUnitPrice(String? value) {
    final parsed = parseDecimal(value);
    if (parsed == null || parsed < 0) {
      return AppLocalizations.of(context)!.nonNegativeNumberError;
    }
    return null;
  }

  String? _validateRoundingIncrement(String? value) {
    if (!_enableRounding) {
      return null;
    }
    final parsed = parseDecimal(value);
    if (parsed == null || parsed <= 0) {
      return AppLocalizations.of(context)!.discountRoundingIncrementError;
    }
    return null;
  }

  String? _validateOptionalNonNegativeDecimal(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    final parsed = parseDecimal(value);
    if (parsed == null || parsed < 0) {
      return AppLocalizations.of(context)!.nonNegativeNumberError;
    }
    return null;
  }

  String? _validatePositiveInteger(String? value) {
    final parsed = int.tryParse(value ?? '');
    if (parsed == null || parsed <= 0) {
      return AppLocalizations.of(context)!.positiveIntegerError;
    }
    return null;
  }

  String? _validateOptionalPositiveInteger(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return _validatePositiveInteger(value);
  }

  String? _validateCustomerSelection() {
    if (_selectedCustomers.isNotEmpty &&
        _channel == DiscountChannel.purchasing) {
      return AppLocalizations.of(context)!.discountCustomerChannelError;
    }
    return null;
  }

  String? _validateSupplierSelection() {
    if (_selectedSuppliers.isNotEmpty && _channel == DiscountChannel.sales) {
      return AppLocalizations.of(context)!.discountSupplierChannelError;
    }
    return null;
  }

  String? _validatePerCustomerLimit(String? value) {
    final base = _validateOptionalPositiveInteger(value);
    if (base != null) {
      return base;
    }
    if ((value?.trim().isNotEmpty ?? false) &&
        _channel == DiscountChannel.purchasing) {
      return AppLocalizations.of(context)!.discountCustomerChannelError;
    }
    return null;
  }

  String? _validatePerSupplierLimit(String? value) {
    final base = _validateOptionalPositiveInteger(value);
    if (base != null) {
      return base;
    }
    if ((value?.trim().isNotEmpty ?? false) &&
        _channel == DiscountChannel.sales) {
      return AppLocalizations.of(context)!.discountSupplierChannelError;
    }
    return null;
  }

  // -- pickers -----------------------------------------------------------

  AsyncSelectionFieldStrings<int> _constraintFieldStrings(
    AppLocalizations l10n, {
    required String label,
  }) {
    return AsyncSelectionFieldStrings<int>(
      label: label,
      emptyText: l10n.discountNoConstraintsSelected,
      helperText: l10n.discountPickerHelper,
      clearTooltip: l10n.clearButton,
      openPickerTooltip: l10n.discountOpenPickerTooltip,
      fallbackLabelForId: l10n.discountConstraintId,
    );
  }

  AsyncSelectionPickerStrings<int> _constraintPickerStrings(
    AppLocalizations l10n, {
    required String title,
    required String searchHint,
    required String emptyText,
  }) {
    return AsyncSelectionPickerStrings<int>(
      title: title,
      searchHint: searchHint,
      emptyText: emptyText,
      clearText: l10n.clearButton,
      clearSearchTooltip: l10n.clearSearchTooltip,
      loadErrorText: l10n.discountPickerLoadError,
      confirmText: l10n.confirmButton,
      fallbackLabelForId: l10n.discountConstraintId,
    );
  }

  Future<void> _pickProducts(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: _constraintPickerStrings(
        l10n,
        title: l10n.discountProductPickerTitle,
        searchHint: l10n.searchProductsHint,
        emptyText: l10n.discountProductPickerEmpty,
      ),
      selected: _selectedProducts,
      searchFieldKey: const ValueKey('discount_constraint_search_field'),
      applyButtonKey: const ValueKey('discount_constraint_apply_button'),
      optionKeyForId: (id) => ValueKey('discount_constraint_option_$id'),
      loadPage: (search, page) async {
        final result = await widget.catalogRepository.loadProducts(
          query: ProductQuery(
            search: search,
            availability: ProductAvailabilityFilter.all,
          ),
          page: page,
        );
        return switch (result) {
          Ok(value: final page) => AsyncSelectionPage<int>(
            options: [
              for (final product in page.products)
                AsyncSelectionOption<int>(
                  id: product.id,
                  label: product.name,
                  subtitle: product.categories
                      .where((category) => category.name.isNotEmpty)
                      .map((category) => category.name)
                      .join(' • '),
                ),
            ],
            hasMore: page.hasMore,
          ),
          Error() => throw Exception('product picker failed'),
        };
      },
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() => _selectedProducts = picked);
  }

  Future<void> _pickVariants(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: _constraintPickerStrings(
        l10n,
        title: l10n.discountVariantPickerTitle,
        searchHint: l10n.discountVariantPickerSearchHint,
        emptyText: l10n.discountVariantPickerEmpty,
      ),
      selected: _selectedVariants,
      searchFieldKey: const ValueKey('discount_constraint_search_field'),
      applyButtonKey: const ValueKey('discount_constraint_apply_button'),
      optionKeyForId: (id) => ValueKey('discount_constraint_option_$id'),
      loadPage: (search, page) async {
        final result = await widget.catalogRepository.loadProductVariants(
          query: ProductQuery(
            search: search,
            availability: ProductAvailabilityFilter.all,
          ),
          page: page,
        );
        return switch (result) {
          Ok(value: final page) => AsyncSelectionPage<int>(
            options: [
              for (final variant in page.variants)
                AsyncSelectionOption<int>(
                  id: variant.id,
                  label: variant.displayLabel,
                  subtitle: [
                    if (variant.sku.isNotEmpty) variant.sku,
                    if (variant.barcode.isNotEmpty) variant.barcode,
                  ].join(' • '),
                ),
            ],
            hasMore: page.hasMore,
          ),
          Error() => throw Exception('variant picker failed'),
        };
      },
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() => _selectedVariants = picked);
  }

  Future<void> _pickProductCategories(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: _constraintPickerStrings(
        l10n,
        title: l10n.discountProductCategoryPickerTitle,
        searchHint: l10n.categorySearchHint,
        emptyText: l10n.discountProductCategoryPickerEmpty,
      ),
      selected: _selectedProductCategories,
      searchFieldKey: const ValueKey('discount_constraint_search_field'),
      applyButtonKey: const ValueKey('discount_constraint_apply_button'),
      optionKeyForId: (id) => ValueKey('discount_constraint_option_$id'),
      loadPage: (search, page) => loadProductCategorySelectionPage(
        catalogRepository: widget.catalogRepository,
        search: search,
        page: page,
      ),
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() => _selectedProductCategories = picked);
  }

  Future<void> _pickCustomers(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: _constraintPickerStrings(
        l10n,
        title: l10n.discountCustomerPickerTitle,
        searchHint: l10n.discountCustomerPickerSearchHint,
        emptyText: l10n.discountCustomerPickerEmpty,
      ),
      selected: _selectedCustomers,
      searchFieldKey: const ValueKey('discount_constraint_search_field'),
      applyButtonKey: const ValueKey('discount_constraint_apply_button'),
      optionKeyForId: (id) => ValueKey('discount_constraint_option_$id'),
      loadPage: (search, page) async {
        final result = await widget.contactRepository.loadCustomers(
          query: ContactQuery(search: search),
          page: page,
        );
        return switch (result) {
          Ok(value: final page) => AsyncSelectionPage<int>(
            options: [
              for (final customer in page.customers)
                AsyncSelectionOption<int>(
                  id: customer.id,
                  label: customer.fullName,
                  subtitle: [
                    if (customer.phone.isNotEmpty) customer.phone,
                    if (customer.email.isNotEmpty) customer.email,
                  ].join(' • '),
                ),
            ],
            hasMore: page.hasMore,
          ),
          Error() => throw Exception('customer picker failed'),
        };
      },
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() => _selectedCustomers = picked);
  }

  Future<void> _pickSuppliers(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: _constraintPickerStrings(
        l10n,
        title: l10n.discountSupplierPickerTitle,
        searchHint: l10n.discountSupplierPickerSearchHint,
        emptyText: l10n.discountSupplierPickerEmpty,
      ),
      selected: _selectedSuppliers,
      searchFieldKey: const ValueKey('discount_constraint_search_field'),
      applyButtonKey: const ValueKey('discount_constraint_apply_button'),
      optionKeyForId: (id) => ValueKey('discount_constraint_option_$id'),
      loadPage: (search, page) async {
        final result = await widget.contactRepository.loadSuppliers(
          query: ContactQuery(search: search),
          page: page,
        );
        return switch (result) {
          Ok(value: final page) => AsyncSelectionPage<int>(
            options: [
              for (final supplier in page.suppliers)
                AsyncSelectionOption<int>(
                  id: supplier.id,
                  label: supplier.name,
                  subtitle: [
                    if (supplier.contactName.isNotEmpty) supplier.contactName,
                    if (supplier.phone.isNotEmpty) supplier.phone,
                  ].join(' • '),
                ),
            ],
            hasMore: page.hasMore,
          ),
          Error() => throw Exception('supplier picker failed'),
        };
      },
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() => _selectedSuppliers = picked);
  }

  List<AsyncSelectionOption<int>> _selectionsFromIds(List<int> ids) {
    return [
      for (final id in ids)
        AsyncSelectionOption<int>(id: id, label: '', subtitle: ''),
    ];
  }

  String _formatMoney(double value) => value.toStringAsFixed(2);

  /// Up to 4 decimals, with trailing zeros trimmed (20.0000 -> 20, 6.2500 ->
  /// 6.25) so values read cleanly in the field and the live summary.
  String _formatDecimal(double value) {
    var text = value.toStringAsFixed(4);
    if (text.contains('.')) {
      text = text.replaceAll(RegExp(r'0+$'), '');
      if (text.endsWith('.')) {
        text = text.substring(0, text.length - 1);
      }
    }
    return text;
  }

  String _channelLabel(AppLocalizations l10n, DiscountChannel channel) {
    return switch (channel) {
      DiscountChannel.sales => l10n.discountChannelSales,
      DiscountChannel.purchasing => l10n.discountChannelPurchasing,
      DiscountChannel.both => l10n.discountChannelBoth,
    };
  }

  String _applicationLabel(
    AppLocalizations l10n,
    DiscountApplicationType type,
  ) {
    return switch (type) {
      DiscountApplicationType.automatic => l10n.discountApplicationAutomatic,
      DiscountApplicationType.couponCode => l10n.discountApplicationCoupon,
    };
  }

  String _scopeLabel(AppLocalizations l10n, DiscountScope scope) {
    return switch (scope) {
      DiscountScope.document => l10n.discountScopeDocument,
      DiscountScope.line => l10n.discountScopeLine,
    };
  }

  String _valueTypeLabel(AppLocalizations l10n, DiscountValueType type) {
    return switch (type) {
      DiscountValueType.percentage => l10n.discountValueTypePercentage,
      DiscountValueType.fixedAmount => l10n.discountValueTypeFixedAmount,
      DiscountValueType.fixedUnitAmount =>
        l10n.discountValueTypeFixedUnitAmount,
      DiscountValueType.fixedPrice => l10n.discountValueTypeFixedPrice,
      DiscountValueType.multiBuy => l10n.discountValueTypeMultiBuy,
      DiscountValueType.tiered => l10n.discountValueTypeTiered,
      DiscountValueType.buyXGetY => l10n.discountValueTypeBuyXGetY,
    };
  }

  String _rewardLabel(AppLocalizations l10n, DiscountBuyGetReward reward) {
    return switch (reward) {
      DiscountBuyGetReward.free => l10n.discountRewardFree,
      DiscountBuyGetReward.percentage => l10n.discountRewardPercentage,
      DiscountBuyGetReward.fixedPrice => l10n.discountRewardFixedPrice,
    };
  }

  String _valueTypeHelp(AppLocalizations l10n, DiscountValueType type) {
    return switch (type) {
      DiscountValueType.percentage => l10n.discountValueTypePercentageHelp,
      DiscountValueType.fixedAmount => l10n.discountValueTypeFixedAmountHelp,
      DiscountValueType.fixedUnitAmount =>
        l10n.discountValueTypeFixedUnitAmountHelp,
      DiscountValueType.fixedPrice => l10n.discountValueTypeFixedPriceHelp,
      DiscountValueType.multiBuy => l10n.discountValueTypeMultiBuyHelp,
      DiscountValueType.tiered => l10n.discountValueTypeTieredHelp,
      DiscountValueType.buyXGetY => l10n.discountValueTypeBuyXGetYHelp,
    };
  }

  String _roundingModeLabel(AppLocalizations l10n, DiscountRoundingMode mode) {
    return switch (mode) {
      DiscountRoundingMode.none => l10n.discountRoundingModeNone,
      DiscountRoundingMode.down => l10n.discountRoundingModeDown,
      DiscountRoundingMode.nearest => l10n.discountRoundingModeNearest,
      DiscountRoundingMode.up => l10n.discountRoundingModeUp,
    };
  }
}
