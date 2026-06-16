import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/contact.dart';
import '../../../data/models/customer_asset.dart';
import '../../../data/models/operations_job.dart';
import '../../../data/models/workflow.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/operations_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/jobs_board_view_model.dart';
import 'operations_ui.dart';

String assetTypeLabel(AppLocalizations l10n, CustomerAssetType type) {
  return switch (type) {
    CustomerAssetType.phone => l10n.assetTypePhone,
    CustomerAssetType.tablet => l10n.assetTypeTablet,
    CustomerAssetType.laptop => l10n.assetTypeLaptop,
    CustomerAssetType.console => l10n.assetTypeConsole,
    CustomerAssetType.appliance => l10n.assetTypeAppliance,
    CustomerAssetType.other => l10n.assetTypeOther,
  };
}

/// Three guided steps — customer → device → details — so counter staff can
/// take in a repair without knowing anything about the data model.
class JobIntakeWizard extends StatefulWidget {
  const JobIntakeWizard({
    super.key,
    required this.template,
    required this.boardViewModel,
    required this.contactRepository,
    required this.operationsRepository,
  });

  final WorkflowTemplate template;
  final JobsBoardViewModel boardViewModel;
  final ContactRepository contactRepository;
  final OperationsRepository operationsRepository;

  @override
  State<JobIntakeWizard> createState() => _JobIntakeWizardState();
}

class _JobIntakeWizardState extends State<JobIntakeWizard> {
  var _step = 0;
  var _isWorking = false;

  // Step 1 — customer.
  final _customerSearchController = TextEditingController();
  Timer? _customerDebounce;
  List<Customer> _customerResults = const [];
  Customer? _selectedCustomer;
  var _creatingCustomer = false;
  final _newCustomerNameController = TextEditingController();
  final _newCustomerPhoneController = TextEditingController();
  var _showCustomerValidation = false;

  // Step 2 — device.
  List<CustomerAsset> _customerAssets = const [];
  CustomerAsset? _selectedAsset;
  var _creatingAsset = false;
  var _skipAsset = false;
  var _newAssetType = CustomerAssetType.phone;
  final _newAssetBrandController = TextEditingController();
  final _newAssetModelController = TextEditingController();
  final _newAssetSerialController = TextEditingController();
  final _newAssetImeiController = TextEditingController();
  final _newAssetColorController = TextEditingController();

  // Step 3 — details.
  final _symptomsController = TextEditingController();
  final _quotedPriceController = TextEditingController();
  final _warrantyDaysController = TextEditingController(text: '0');
  var _priority = OperationsJobPriority.normal;
  DateTime? _dueAt;

  bool get _isRepair => widget.template.jobType == OperationsJobType.repair;

  @override
  void initState() {
    super.initState();
    _searchCustomers('');
  }

  @override
  void dispose() {
    _customerDebounce?.cancel();
    _customerSearchController.dispose();
    _newCustomerNameController.dispose();
    _newCustomerPhoneController.dispose();
    _newAssetBrandController.dispose();
    _newAssetModelController.dispose();
    _newAssetSerialController.dispose();
    _newAssetImeiController.dispose();
    _newAssetColorController.dispose();
    _symptomsController.dispose();
    _quotedPriceController.dispose();
    _warrantyDaysController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return PointyScaffold(
      appBar: PointyAppBar(
        title: Text(l10n.intakeTitle),
        isLoading: _isWorking,
      ),
      body: ListView(
        padding: spacing.pagePadding,
        children: [
          AdaptiveMaxWidth(
            width: AppContentWidth.form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StepHeader(step: _step, isRepair: _isRepair),
                SizedBox(height: spacing.md),
                switch (_step) {
                  0 => _customerStep(context),
                  1 => _isRepair ? _assetStep(context) : _detailsStep(context),
                  _ => _detailsStep(context),
                },
                SizedBox(height: spacing.lg),
                _navigationButtons(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  int get _lastStep => _isRepair ? 2 : 1;

  Widget _navigationButtons(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    return Row(
      children: [
        if (_step > 0)
          OutlinedButton.icon(
            onPressed: _isWorking ? null : () => setState(() => _step -= 1),
            icon: const Icon(Icons.arrow_back),
            label: Text(l10n.intakeBackButton),
          ),
        const Spacer(),
        SizedBox(width: spacing.sm),
        FilledButton.icon(
          onPressed: _isWorking ? null : _onPrimaryPressed,
          icon: Icon(_step == _lastStep ? Icons.check : Icons.arrow_forward),
          label: Text(
            _step == _lastStep
                ? l10n.intakeCreateButton
                : l10n.intakeNextButton,
          ),
        ),
      ],
    );
  }

  Future<void> _onPrimaryPressed() async {
    if (_step == 0) {
      final customer = await _resolveCustomer();
      if (customer == null) {
        setState(() => _showCustomerValidation = true);
        return;
      }
      _selectedCustomer = customer;
      _showCustomerValidation = false;
      if (_isRepair) {
        await _loadAssets(customer.id);
      }
      if (mounted) {
        setState(() => _step = 1);
      }
      return;
    }
    if (_step < _lastStep) {
      setState(() => _step += 1);
      return;
    }
    await _createJob();
  }

  // -------------------------------------------------------------------------
  // Step 1 — customer
  // -------------------------------------------------------------------------

  Widget _customerStep(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.intakeSelectCustomerHint,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        SizedBox(height: spacing.sm),
        TextField(
          controller: _customerSearchController,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: l10n.intakeSelectCustomerHint,
            isDense: true,
          ),
          onChanged: (value) {
            _customerDebounce?.cancel();
            _customerDebounce = Timer(
              const Duration(milliseconds: 350),
              () => _searchCustomers(value),
            );
          },
        ),
        SizedBox(height: spacing.sm),
        if (_showCustomerValidation &&
            _selectedCustomer == null &&
            !_creatingCustomer)
          PointyInlineMessage.error(
            message: l10n.intakeCustomerRequired,
            icon: Icons.person_off_outlined,
          ),
        for (final customer in _customerResults.take(6))
          Padding(
            padding: EdgeInsets.only(bottom: spacing.xs),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(PointyRadii.card),
                side: BorderSide(
                  color: _selectedCustomer?.id == customer.id
                      ? PointyColors.primary
                      : context.pointyColors.line,
                ),
              ),
              selected: _selectedCustomer?.id == customer.id,
              selectedTileColor: PointyColors.primaryContainer,
              leading: OperationsIconBadge(
                icon: Icons.person_outline,
                size: 40,
                color: _selectedCustomer?.id == customer.id
                    ? context.pointyColors.success
                    : null,
              ),
              title: Text(customer.fullName),
              subtitle: customer.phone.isEmpty ? null : Text(customer.phone),
              trailing: _selectedCustomer?.id == customer.id
                  ? Icon(
                      Icons.check_circle,
                      color: context.pointyColors.success,
                    )
                  : null,
              onTap: () => setState(() {
                _selectedCustomer = customer;
                _creatingCustomer = false;
              }),
            ),
          ),
        SizedBox(height: spacing.sm),
        if (!_creatingCustomer)
          OutlinedButton.icon(
            onPressed: () => setState(() {
              _creatingCustomer = true;
              _selectedCustomer = null;
            }),
            icon: const Icon(Icons.person_add_outlined),
            label: Text(l10n.intakeNewCustomerButton),
          )
        else ...[
          TextField(
            controller: _newCustomerNameController,
            decoration: InputDecoration(
              labelText: l10n.intakeCustomerNameLabel,
              errorText:
                  _showCustomerValidation &&
                      _newCustomerNameController.text.trim().isEmpty
                  ? l10n.intakeCustomerRequired
                  : null,
            ),
          ),
          SizedBox(height: spacing.sm),
          TextField(
            controller: _newCustomerPhoneController,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: l10n.intakeCustomerPhoneLabel,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _searchCustomers(String query) async {
    final result = await widget.contactRepository.loadCustomers(
      query: ContactQuery(search: query),
    );
    if (!mounted) {
      return;
    }
    if (result case Ok<CustomerPage>(value: final page)) {
      setState(() => _customerResults = page.customers);
    }
  }

  Future<Customer?> _resolveCustomer() async {
    if (_selectedCustomer != null) {
      return _selectedCustomer;
    }
    if (!_creatingCustomer || _newCustomerNameController.text.trim().isEmpty) {
      return null;
    }
    setState(() => _isWorking = true);
    final result = await widget.contactRepository.createCustomer(
      CustomerDraft(
        fullName: _newCustomerNameController.text.trim(),
        phone: _newCustomerPhoneController.text.trim(),
        email: '',
        gender: CustomerGender.unspecified,
        birthday: null,
        marketingConsent: false,
        notes: '',
        isActive: true,
      ),
    );
    if (mounted) {
      setState(() => _isWorking = false);
    }
    return switch (result) {
      Ok<Customer>(value: final customer) => customer,
      Error<Customer>() => null,
    };
  }

  // -------------------------------------------------------------------------
  // Step 2 — device (repair only)
  // -------------------------------------------------------------------------

  Future<void> _loadAssets(int customerId) async {
    final result = await widget.operationsRepository.loadCustomerAssets(
      customer: customerId,
    );
    if (!mounted) {
      return;
    }
    if (result case Ok<CustomerAssetPage>(value: final page)) {
      setState(() => _customerAssets = page.assets);
    }
  }

  Widget _assetStep(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.intakeSelectAssetHint,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        SizedBox(height: spacing.sm),
        if (_customerAssets.isEmpty && !_creatingAsset)
          PointyInlineMessage.warning(
            message: l10n.customerAssetsEmpty,
            icon: Icons.devices_other_outlined,
          ),
        for (final asset in _customerAssets)
          Card(
            margin: EdgeInsets.only(bottom: spacing.xs),
            child: ListTile(
              leading: Icon(
                _selectedAsset?.id == asset.id
                    ? Icons.check_circle
                    : Icons.smartphone_outlined,
                color: _selectedAsset?.id == asset.id
                    ? context.pointyColors.success
                    : null,
              ),
              title: Text(asset.displayName),
              subtitle: Text(
                [
                  assetTypeLabel(l10n, asset.assetType),
                  if (asset.imei.isNotEmpty) 'IMEI ${asset.imei}',
                  if (asset.serialNumber.isNotEmpty) asset.serialNumber,
                  l10n.jobCountLabel(asset.jobCount),
                ].join(' · '),
              ),
              selected: _selectedAsset?.id == asset.id,
              onTap: () => setState(() {
                _selectedAsset = asset;
                _creatingAsset = false;
                _skipAsset = false;
              }),
            ),
          ),
        SizedBox(height: spacing.sm),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => setState(() {
                  _creatingAsset = !_creatingAsset;
                  _selectedAsset = null;
                  _skipAsset = false;
                }),
                icon: const Icon(Icons.add),
                label: Text(l10n.intakeNewAssetButton),
              ),
            ),
            SizedBox(width: spacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => setState(() {
                  _skipAsset = true;
                  _selectedAsset = null;
                  _creatingAsset = false;
                  _step = 2;
                }),
                icon: const Icon(Icons.no_cell_outlined),
                label: Text(l10n.intakeSkipAssetButton),
              ),
            ),
          ],
        ),
        if (_creatingAsset) ...[
          SizedBox(height: spacing.md),
          DropdownButtonFormField<CustomerAssetType>(
            initialValue: _newAssetType,
            decoration: InputDecoration(labelText: l10n.assetTypeLabel),
            items: [
              for (final type in CustomerAssetType.values)
                DropdownMenuItem(
                  value: type,
                  child: Text(assetTypeLabel(l10n, type)),
                ),
            ],
            onChanged: (type) {
              if (type != null) {
                setState(() => _newAssetType = type);
              }
            },
          ),
          SizedBox(height: spacing.sm),
          TextField(
            controller: _newAssetBrandController,
            decoration: InputDecoration(labelText: l10n.assetBrandLabel),
          ),
          SizedBox(height: spacing.sm),
          TextField(
            controller: _newAssetModelController,
            decoration: InputDecoration(labelText: l10n.assetModelLabel),
          ),
          SizedBox(height: spacing.sm),
          TextField(
            controller: _newAssetImeiController,
            decoration: InputDecoration(labelText: l10n.assetImeiLabel),
          ),
          SizedBox(height: spacing.sm),
          TextField(
            controller: _newAssetSerialController,
            decoration: InputDecoration(labelText: l10n.assetSerialLabel),
          ),
          SizedBox(height: spacing.sm),
          TextField(
            controller: _newAssetColorController,
            decoration: InputDecoration(labelText: l10n.assetColorLabel),
          ),
        ],
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Step 3 — details
  // -------------------------------------------------------------------------

  Widget _detailsStep(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _symptomsController,
          maxLines: 3,
          decoration: InputDecoration(labelText: l10n.jobSymptomsLabel),
        ),
        SizedBox(height: spacing.md),
        DropdownButtonFormField<OperationsJobPriority>(
          initialValue: _priority,
          decoration: InputDecoration(labelText: l10n.jobPriorityLabel),
          items: [
            for (final priority in OperationsJobPriority.values)
              DropdownMenuItem(
                value: priority,
                child: Text(switch (priority) {
                  OperationsJobPriority.low => l10n.jobPriorityLow,
                  OperationsJobPriority.normal => l10n.jobPriorityNormal,
                  OperationsJobPriority.high => l10n.jobPriorityHigh,
                  OperationsJobPriority.urgent => l10n.jobPriorityUrgent,
                }),
              ),
          ],
          onChanged: (priority) {
            if (priority != null) {
              setState(() => _priority = priority);
            }
          },
        ),
        SizedBox(height: spacing.md),
        ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          leading: const Icon(Icons.event_outlined),
          title: Text(l10n.jobDueAtLabel),
          subtitle: Text(
            _dueAt == null
                ? l10n.shopSettingsEmptyValue
                : formatDateTime(_dueAt!),
          ),
          onTap: _pickDueDate,
        ),
        if (_isRepair) ...[
          SizedBox(height: spacing.md),
          TextField(
            controller: _quotedPriceController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalTextInputFormatter()],
            decoration: InputDecoration(labelText: l10n.jobQuotedPriceLabel),
          ),
          SizedBox(height: spacing.md),
          TextField(
            controller: _warrantyDaysController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: l10n.jobWarrantyDaysLabel),
          ),
        ],
      ],
    );
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueAt ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null && mounted) {
      setState(
        () => _dueAt = DateTime(picked.year, picked.month, picked.day, 18),
      );
    }
  }

  Future<void> _createJob() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final customer = _selectedCustomer;
    if (customer == null) {
      setState(() {
        _step = 0;
        _showCustomerValidation = true;
      });
      return;
    }

    setState(() => _isWorking = true);

    var assetIds = <int>[];
    if (_isRepair && !_skipAsset) {
      if (_selectedAsset != null) {
        assetIds = [_selectedAsset!.id];
      } else if (_creatingAsset &&
          (_newAssetBrandController.text.trim().isNotEmpty ||
              _newAssetModelController.text.trim().isNotEmpty ||
              _newAssetImeiController.text.trim().isNotEmpty)) {
        final created = await widget.operationsRepository.createCustomerAsset(
          CustomerAssetDraft(
            customer: customer.id,
            assetType: _newAssetType,
            brand: _newAssetBrandController.text.trim(),
            modelName: _newAssetModelController.text.trim(),
            serialNumber: _newAssetSerialController.text.trim(),
            imei: _newAssetImeiController.text.trim(),
            color: _newAssetColorController.text.trim(),
          ),
        );
        switch (created) {
          case Ok<CustomerAsset>(value: final asset):
            assetIds = [asset.id];
          case Error<CustomerAsset>():
            if (mounted) {
              setState(() => _isWorking = false);
              messenger.showSnackBar(
                SnackBar(content: Text(l10n.operationsActionError)),
              );
            }
            return;
        }
      }
    }

    final job = await widget.boardViewModel.createJob(
      OperationsJobDraft(
        workflowTemplate: widget.template.id,
        customer: customer.id,
        assetIds: assetIds,
        priority: _priority,
        dueAt: _dueAt,
        symptoms: _symptomsController.text.trim(),
        quotedPrice: double.tryParse(_quotedPriceController.text.trim()),
        warrantyDays: int.tryParse(_warrantyDaysController.text.trim()),
      ),
    );
    if (!mounted) {
      return;
    }
    setState(() => _isWorking = false);
    if (job == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.operationsActionError)),
      );
      return;
    }
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.intakeJobCreated(job.jobNumber))),
    );
    Navigator.of(context).pop(job);
  }
}

class _StepHeader extends StatelessWidget {
  const _StepHeader({required this.step, required this.isRepair});

  final int step;
  final bool isRepair;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final labels = [
      l10n.intakeStepCustomer,
      if (isRepair) l10n.intakeStepAsset,
      l10n.intakeStepDetails,
    ];
    final colors = context.pointyColors;

    return Row(
      children: [
        for (var index = 0; index < labels.length; index++) ...[
          if (index > 0)
            Expanded(
              child: Divider(
                color: index <= step ? colors.primaryStrong : colors.line,
                thickness: 2,
              ),
            ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: index <= step
                    ? colors.primaryStrong
                    : colors.subtleFill,
                child: index < step
                    ? const Icon(Icons.check, size: 18, color: Colors.white)
                    : Text(
                        '${index + 1}',
                        style: TextStyle(
                          color: index <= step ? Colors.white : colors.mutedInk,
                        ),
                      ),
              ),
              const SizedBox(height: 4),
              Text(
                labels[index],
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ],
      ],
    );
  }
}
