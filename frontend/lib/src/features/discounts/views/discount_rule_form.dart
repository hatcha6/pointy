import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/discount_rule.dart';
import '../../../data/models/product_query.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/async_selection/async_selection.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/product_category_picker.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/discount_management_view_model.dart';

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
  static const _stepCount = 5;

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _couponCodeController;
  late final TextEditingController _valueController;
  late final TextEditingController _maxDiscountController;
  late final TextEditingController _roundingIncrementController;
  late final TextEditingController _minSubtotalController;
  late final TextEditingController _minLineQuantityController;
  late final TextEditingController _priorityController;
  late final TextEditingController _usageLimitController;
  late final TextEditingController _perCustomerLimitController;
  late final TextEditingController _perSupplierLimitController;

  int _step = 0;
  late DiscountChannel _channel;
  late DiscountApplicationType _applicationType;
  late DiscountScope _scope;
  late DiscountValueType _valueType;
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
  late bool _showSchedule;
  late bool _showUsageLimits;
  late bool _showAdvancedSettings;
  late List<AsyncSelectionOption<int>> _selectedProducts;
  late List<AsyncSelectionOption<int>> _selectedVariants;
  late List<AsyncSelectionOption<int>> _selectedProductCategories;
  late List<AsyncSelectionOption<int>> _selectedCustomers;
  late List<AsyncSelectionOption<int>> _selectedSuppliers;
  DateTime? _startsAt;
  DateTime? _endsAt;

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
    _showSchedule = _startsAt != null || _endsAt != null;
    _showUsageLimits =
        rule?.usageLimit != null ||
        rule?.perCustomerUsageLimit != null ||
        rule?.perSupplierUsageLimit != null;
    _showAdvancedSettings =
        rule != null && (!rule.exclusive || rule.priority != 100);
  }

  @override
  void dispose() {
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        Expanded(
          child: Form(
            key: _formKey,
            child: ListView(
              key: const ValueKey('discount_rule_form_scroll'),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.rule == null
                            ? l10n.discountCreateTitle
                            : l10n.discountEditTitle,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    Text(l10n.discountWizardStepLabel(_step + 1, _stepCount)),
                  ],
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(value: (_step + 1) / _stepCount),
                const SizedBox(height: 12),
                _WizardStepBar(
                  currentStep: _step,
                  labels: [
                    l10n.discountWizardStepBasics,
                    l10n.discountWizardStepValue,
                    l10n.discountWizardStepEligibility,
                    l10n.discountWizardStepLimits,
                    l10n.discountWizardStepReview,
                  ],
                ),
                const SizedBox(height: 18),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: _buildCurrentStep(l10n),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Row(
            children: [
              if (_step > 0)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: widget.viewModel.isSaving ? null : _goBack,
                    icon: const Icon(Icons.arrow_back),
                    label: Text(l10n.backButton),
                  ),
                ),
              if (_step > 0) const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('discount_rule_save_button'),
                  onPressed: widget.viewModel.isSaving
                      ? null
                      : _step == _stepCount - 1
                      ? _submit
                      : _goNext,
                  icon: widget.viewModel.isSaving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _step == _stepCount - 1
                              ? Icons.save_outlined
                              : Icons.arrow_forward,
                        ),
                  label: Text(
                    _step == _stepCount - 1
                        ? l10n.discountSaveButton
                        : l10n.nextButton,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCurrentStep(AppLocalizations l10n) {
    return switch (_step) {
      0 => _buildBasicsStep(l10n),
      1 => _buildValueStep(l10n),
      2 => _buildEligibilityStep(l10n),
      3 => _buildLimitsStep(l10n),
      _ => _buildReviewStep(l10n),
    };
  }

  Widget _buildBasicsStep(AppLocalizations l10n) {
    return _WizardSection(
      key: const ValueKey('discount_wizard_basics_step'),
      icon: Icons.sell_outlined,
      title: l10n.discountWizardStepBasics,
      children: [
        TextFormField(
          controller: _nameController,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: l10n.discountNameLabel,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          validator: (value) => value == null || value.trim().isEmpty
              ? l10n.requiredFieldError
              : null,
        ),
        SwitchListTile(
          value: _isActive,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.discountActiveLabel),
          onChanged: (value) => setState(() => _isActive = value),
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
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            validator: (value) {
              if (_applicationType == DiscountApplicationType.couponCode &&
                  (value == null || value.trim().isEmpty)) {
                return l10n.requiredFieldError;
              }
              return null;
            },
          ),
        SwitchListTile(
          value: _showDescription,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.discountWizardDescriptionToggle),
          onChanged: (value) => setState(() => _showDescription = value),
        ),
        if (_showDescription)
          TextFormField(
            controller: _descriptionController,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: l10n.discountDescriptionLabel,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
      ],
    );
  }

  Widget _buildValueStep(AppLocalizations l10n) {
    return _WizardSection(
      key: const ValueKey('discount_wizard_value_step'),
      icon: Icons.price_change_outlined,
      title: l10n.discountWizardStepValue,
      children: [
        _SegmentedField<DiscountScope>(
          label: l10n.discountScopeLabel,
          selected: _scope,
          values: DiscountScope.values,
          labelFor: (value) => _scopeLabel(l10n, value),
          onSelected: (value) => setState(() => _scope = value),
        ),
        DropdownButtonFormField<DiscountValueType>(
          initialValue: _valueType,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: l10n.discountValueTypeLabel,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (final type in DiscountValueType.values)
              DropdownMenuItem(
                value: type,
                child: Text(_valueTypeLabel(l10n, type)),
              ),
          ],
          onChanged: (value) {
            if (value == null) {
              return;
            }
            setState(() {
              _valueType = value;
              if (value == DiscountValueType.fixedPrice ||
                  value == DiscountValueType.fixedUnitAmount) {
                _scope = DiscountScope.line;
              }
            });
          },
        ),
        TextFormField(
          controller: _valueController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [DecimalTextInputFormatter()],
          decoration: InputDecoration(
            labelText: l10n.discountValueLabel,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          validator: _validatePositiveDecimal,
        ),
        SwitchListTile(
          value: _showMaximumDiscount,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.discountWizardMaximumDiscountToggle),
          onChanged: (value) => setState(() => _showMaximumDiscount = value),
        ),
        if (_showMaximumDiscount)
          TextFormField(
            controller: _maxDiscountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
            decoration: InputDecoration(
              labelText: l10n.discountMaxAmountLabel,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            validator: _validateOptionalPositiveAmount,
          ),
        SwitchListTile(
          value: _enableRounding,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.discountWizardRoundingToggle),
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
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            validator: _validateRoundingIncrement,
          ),
        ],
      ],
    );
  }

  Widget _buildEligibilityStep(AppLocalizations l10n) {
    final showCustomerFields = _channel != DiscountChannel.purchasing;
    final showSupplierFields = _channel != DiscountChannel.sales;
    return _WizardSection(
      key: const ValueKey('discount_wizard_eligibility_step'),
      icon: Icons.rule_outlined,
      title: l10n.discountWizardStepEligibility,
      children: [
        SwitchListTile(
          value: _limitByMinimumSubtotal,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.discountWizardMinimumSubtotalToggle),
          onChanged: (value) => setState(() => _limitByMinimumSubtotal = value),
        ),
        if (_limitByMinimumSubtotal)
          TextFormField(
            controller: _minSubtotalController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
            decoration: InputDecoration(
              labelText: l10n.discountMinSubtotalLabel,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            validator: _validateOptionalNonNegativeDecimal,
          ),
        if (_scope == DiscountScope.line)
          SwitchListTile(
            value: _limitByMinimumLineQuantity,
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.discountWizardMinimumLineQuantityToggle),
            onChanged: (value) =>
                setState(() => _limitByMinimumLineQuantity = value),
          ),
        if (_scope == DiscountScope.line && _limitByMinimumLineQuantity)
          TextFormField(
            controller: _minLineQuantityController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: l10n.discountMinLineQuantityLabel,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            validator: _validateOptionalPositiveInteger,
          ),
        SwitchListTile(
          value: _limitByProducts,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.discountWizardProductScopeToggle),
          onChanged: (value) => setState(() => _limitByProducts = value),
        ),
        if (_limitByProducts) _buildProductConstraints(l10n),
        SwitchListTile(
          value: _limitByContacts,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.discountWizardContactScopeToggle),
          onChanged: (value) => setState(() => _limitByContacts = value),
        ),
        if (_limitByContacts)
          _buildContactConstraints(
            l10n,
            showCustomerFields: showCustomerFields,
            showSupplierFields: showSupplierFields,
          ),
      ],
    );
  }

  Widget _buildLimitsStep(AppLocalizations l10n) {
    return _WizardSection(
      key: const ValueKey('discount_wizard_limits_step'),
      icon: Icons.event_available_outlined,
      title: l10n.discountWizardStepLimits,
      children: [
        SwitchListTile(
          value: _showSchedule,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.discountWizardScheduleToggle),
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
        SwitchListTile(
          value: _showUsageLimits,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.discountWizardUsageLimitsToggle),
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
                  border: const OutlineInputBorder(),
                  isDense: true,
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
                    border: const OutlineInputBorder(),
                    isDense: true,
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
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  validator: _validatePerSupplierLimit,
                ),
            ],
          ),
        SwitchListTile(
          value: _showAdvancedSettings,
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.discountWizardAdvancedToggle),
          onChanged: (value) => setState(() => _showAdvancedSettings = value),
        ),
        if (_showAdvancedSettings) ...[
          TextFormField(
            controller: _priorityController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: l10n.discountPriorityLabel,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            validator: _validatePositiveInteger,
          ),
          SwitchListTile(
            value: _exclusive,
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.discountExclusiveLabel),
            subtitle: Text(l10n.discountExclusiveHelper),
            onChanged: (value) => setState(() => _exclusive = value),
          ),
        ],
      ],
    );
  }

  Widget _buildReviewStep(AppLocalizations l10n) {
    return _WizardSection(
      key: const ValueKey('discount_wizard_review_step'),
      icon: Icons.fact_check_outlined,
      title: l10n.discountWizardStepReview,
      children: [
        _ReviewRow(label: l10n.discountNameLabel, value: _nameController.text),
        _ReviewRow(
          label: l10n.discountChannelLabel,
          value: _channelLabel(l10n, _channel),
        ),
        _ReviewRow(
          label: l10n.discountApplicationTypeLabel,
          value: _applicationReviewValue(l10n),
        ),
        _ReviewRow(
          label: l10n.discountValueLabel,
          value: l10n.discountValueSummary(
            _valueTypeLabel(l10n, _valueType),
            _valueController.text,
          ),
        ),
        _ReviewRow(
          label: l10n.discountScopeLabel,
          value: _scopeLabel(l10n, _scope),
        ),
        if (_enableRounding)
          _ReviewRow(
            label: l10n.discountRoundingModeLabel,
            value: l10n.discountRoundingSummary(
              _roundingModeLabel(l10n, _roundingMode),
              _roundingIncrementController.text,
            ),
          ),
        _ReviewRow(
          label: l10n.discountDetailsConstraintsSection,
          value: _constraintsReviewValue(l10n),
        ),
        _ReviewRow(
          label: l10n.discountUsageSection,
          value: _limitsReviewValue(l10n),
        ),
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

  void _goBack() {
    if (_step == 0) {
      return;
    }
    setState(() => _step -= 1);
  }

  void _goNext() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final invalidStep = _firstInvalidStep();
    if (invalidStep != null && invalidStep <= _step) {
      _showFixStepMessage();
      return;
    }
    setState(() => _step += 1);
  }

  int? _firstInvalidStep() {
    if (_nameController.text.trim().isEmpty) {
      return 0;
    }
    if (_applicationType == DiscountApplicationType.couponCode &&
        _couponCodeController.text.trim().isEmpty) {
      return 0;
    }
    if (_validatePositiveDecimal(_valueController.text) != null) {
      return 1;
    }
    if (_showMaximumDiscount &&
        _validateOptionalPositiveAmount(_maxDiscountController.text) != null) {
      return 1;
    }
    if (_enableRounding &&
        _validateRoundingIncrement(_roundingIncrementController.text) != null) {
      return 1;
    }
    if (_limitByMinimumSubtotal &&
        _validateOptionalNonNegativeDecimal(_minSubtotalController.text) !=
            null) {
      return 2;
    }
    if (_scope == DiscountScope.line &&
        _limitByMinimumLineQuantity &&
        _validateOptionalPositiveInteger(_minLineQuantityController.text) !=
            null) {
      return 2;
    }
    if (_limitByContacts &&
        ((_channel != DiscountChannel.purchasing &&
                _validateCustomerSelection() != null) ||
            (_channel != DiscountChannel.sales &&
                _validateSupplierSelection() != null))) {
      return 2;
    }
    if (_showSchedule &&
        _endsAt != null &&
        _startsAt != null &&
        !_endsAt!.isAfter(_startsAt!)) {
      return 3;
    }
    if (_showUsageLimits &&
        (_validateOptionalPositiveInteger(_usageLimitController.text) != null ||
            (_channel != DiscountChannel.purchasing &&
                _validatePerCustomerLimit(_perCustomerLimitController.text) !=
                    null) ||
            (_channel != DiscountChannel.sales &&
                _validatePerSupplierLimit(_perSupplierLimitController.text) !=
                    null))) {
      return 3;
    }
    if (_showAdvancedSettings &&
        _validatePositiveInteger(_priorityController.text) != null) {
      return 3;
    }
    return null;
  }

  void _showFixStepMessage() {
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.discountWizardFixStepError)));
  }

  String _applicationReviewValue(AppLocalizations l10n) {
    if (_applicationType == DiscountApplicationType.couponCode) {
      final code = _couponCodeController.text.trim().toUpperCase();
      return code.isEmpty
          ? _applicationLabel(l10n, _applicationType)
          : l10n.discountCouponSummary(code);
    }
    return _applicationLabel(l10n, _applicationType);
  }

  String _constraintsReviewValue(AppLocalizations l10n) {
    final parts = <String>[];
    if (_limitByMinimumSubtotal &&
        _minSubtotalController.text.trim().isNotEmpty) {
      parts.add(
        l10n.discountMinSubtotalSummary(_minSubtotalController.text.trim()),
      );
    }
    if (_scope == DiscountScope.line &&
        _limitByMinimumLineQuantity &&
        _minLineQuantityController.text.trim().isNotEmpty) {
      parts.add(
        l10n.discountMinLineQuantitySummary(
          int.tryParse(_minLineQuantityController.text.trim()) ?? 0,
        ),
      );
    }
    if (_limitByProducts) {
      if (_selectedProductCategories.isNotEmpty) {
        parts.add(
          l10n.discountProductCategoryConstraintSummary(
            _selectedProductCategories.length,
          ),
        );
      }
      if (_selectedProducts.isNotEmpty) {
        parts.add(
          l10n.discountProductConstraintSummary(_selectedProducts.length),
        );
      }
      if (_selectedVariants.isNotEmpty) {
        parts.add(
          l10n.discountVariantConstraintSummary(_selectedVariants.length),
        );
      }
    }
    if (_limitByContacts) {
      if (_selectedCustomers.isNotEmpty &&
          _channel != DiscountChannel.purchasing) {
        parts.add(
          l10n.discountCustomerConstraintSummary(_selectedCustomers.length),
        );
      }
      if (_selectedSuppliers.isNotEmpty && _channel != DiscountChannel.sales) {
        parts.add(
          l10n.discountSupplierConstraintSummary(_selectedSuppliers.length),
        );
      }
    }
    return parts.isEmpty ? l10n.discountWizardNoExtraRules : parts.join(' • ');
  }

  String _limitsReviewValue(AppLocalizations l10n) {
    final parts = <String>[];
    if (_showSchedule) {
      if (_startsAt != null) {
        parts.add('${l10n.discountStartsAtLabel}: ${_formatDate(_startsAt!)}');
      }
      if (_endsAt != null) {
        parts.add('${l10n.discountEndsAtLabel}: ${_formatDate(_endsAt!)}');
      }
    }
    if (_showUsageLimits && _usageLimitController.text.trim().isNotEmpty) {
      parts.add(
        l10n.discountUsageSummary(
          0,
          int.tryParse(_usageLimitController.text.trim()) ?? 0,
        ),
      );
    }
    if (_showAdvancedSettings) {
      parts.add(
        l10n.discountPrioritySummary(
          int.tryParse(_priorityController.text.trim()) ?? 100,
        ),
      );
      if (_exclusive) {
        parts.add(l10n.discountExclusiveShort);
      }
    }
    return parts.isEmpty ? l10n.discountWizardNoLimits : parts.join(' • ');
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

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final invalidStep = _firstInvalidStep();
    if (invalidStep != null) {
      setState(() => _step = invalidStep);
      _showFixStepMessage();
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
      value: _valueController.text,
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
          _scope == DiscountScope.line && _limitByMinimumLineQuantity
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.discountSaveError)));
    }
  }

  String? _validatePositiveDecimal(String? value) {
    final l10n = AppLocalizations.of(context)!;
    final parsed = double.tryParse((value ?? '').replaceAll(',', '.'));
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
    final parsed = double.tryParse(value.replaceAll(',', '.'));
    if (parsed == null || parsed <= 0) {
      return AppLocalizations.of(context)!.positiveNumberError;
    }
    return null;
  }

  String? _validateRoundingIncrement(String? value) {
    if (!_enableRounding) {
      return null;
    }
    final parsed = double.tryParse((value ?? '').replaceAll(',', '.'));
    if (parsed == null || parsed <= 0) {
      return AppLocalizations.of(context)!.discountRoundingIncrementError;
    }
    return null;
  }

  String? _validateOptionalNonNegativeDecimal(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    final parsed = double.tryParse(value.replaceAll(',', '.'));
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
  String _formatDecimal(double value) => value.toStringAsFixed(4);

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

class _WizardStepBar extends StatelessWidget {
  const _WizardStepBar({required this.currentStep, required this.labels});

  final int currentStep;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var index = 0; index < labels.length; index++)
          _WizardStepChip(
            label: labels[index],
            isCurrent: index == currentStep,
            isComplete: index < currentStep,
            colorScheme: colorScheme,
          ),
      ],
    );
  }
}

class _WizardStepChip extends StatelessWidget {
  const _WizardStepChip({
    required this.label,
    required this.isCurrent,
    required this.isComplete,
    required this.colorScheme,
  });

  final String label;
  final bool isCurrent;
  final bool isComplete;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final background = isCurrent
        ? colorScheme.primaryContainer
        : isComplete
        ? colorScheme.secondaryContainer
        : colorScheme.surfaceContainerHighest;
    final foreground = isCurrent
        ? colorScheme.onPrimaryContainer
        : isComplete
        ? colorScheme.onSecondaryContainer
        : colorScheme.onSurfaceVariant;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isComplete ? Icons.check : Icons.circle,
            size: isComplete ? 16 : 8,
            color: foreground,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _WizardSection extends StatelessWidget {
  const _WizardSection({
    super.key,
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, color: colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        for (final child in children) ...[child, const SizedBox(height: 12)],
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

class _ReviewRow extends StatelessWidget {
  const _ReviewRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final displayValue = value.trim();
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      child: Text(
        displayValue,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: displayValue.isEmpty
              ? colorScheme.onSurfaceVariant
              : colorScheme.onSurface,
        ),
      ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
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
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      child: Row(
        children: [
          Expanded(child: Text(text, overflow: TextOverflow.ellipsis)),
          IconButton(
            tooltip: l10n.discountPickDateTooltip,
            onPressed: onPick,
            icon: const Icon(Icons.calendar_month_outlined),
          ),
          if (value != null)
            IconButton(
              tooltip: l10n.clearButton,
              onPressed: onClear,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    );
  }
}
