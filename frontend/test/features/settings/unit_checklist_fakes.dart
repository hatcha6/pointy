import 'dart:convert';

import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/unit_attribute.dart';
import 'package:pointy_frontend/src/data/models/unit_checklist_kind.dart';
import 'package:pointy_frontend/src/data/repositories/tracked_stock_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';

/// The seeded phone checklist, as the server answers it.
List<UnitAttributeDefinition> phoneChecklist() => const [
  UnitAttributeDefinition(
    id: 1,
    assetTypeId: 7,
    key: 'battery_health',
    label: 'صحة البطارية',
    dataType: UnitAttributeType.percent,
    suffix: '%',
  ),
  UnitAttributeDefinition(
    id: 2,
    assetTypeId: 7,
    key: 'condition_grade',
    label: 'درجة الحالة',
    dataType: UnitAttributeType.choice,
    choices: [
      UnitAttributeChoice(value: 'a_plus', label: 'ممتاز +'),
      UnitAttributeChoice(value: 'a', label: 'ممتاز'),
      UnitAttributeChoice(value: 'b', label: 'جيد'),
      UnitAttributeChoice(value: 'c', label: 'مقبول'),
      UnitAttributeChoice(value: 'parts', label: 'قطع غيار'),
    ],
    isRequired: true,
    showOnLabel: true,
  ),
  UnitAttributeDefinition(
    id: 3,
    assetTypeId: 7,
    key: 'box_and_accessories',
    label: 'العلبة والملحقات',
    dataType: UnitAttributeType.choice,
    choices: [
      UnitAttributeChoice(value: 'full_box', label: 'علبة كاملة'),
      UnitAttributeChoice(value: 'device_only', label: 'الجهاز فقط'),
    ],
    showInPicker: false,
    showOnReceipt: true,
  ),
];

const phoneKind = UnitChecklistKind(
  assetTypeId: 7,
  name: 'هاتف',
  slug: 'phone',
  iconKey: 'phone',
  fieldCount: 3,
  requiredCount: 1,
);

/// A 400 the way DRF words one.
PosApiException badRequest(Map<String, Object?> body) => PosApiException(
  message: 'Checklist field create failed 400',
  statusCode: 400,
  responseBody: jsonEncode(body),
);

/// In-memory checklists. Every call is recorded; a non-null `refuse*` answers
/// that call with the exception instead.
class FakeChecklistRepository extends TrackedStockRepository {
  FakeChecklistRepository({List<UnitAttributeDefinition>? fields})
    : fields = fields ?? phoneChecklist(),
      super(PosApiService());

  List<UnitAttributeDefinition> fields;
  List<UnitChecklistKind> kinds = const [phoneKind];
  final List<UnitAttributeDefinition> saved = [];
  final List<int> deleted = [];
  final List<List<int>> reorders = [];
  Exception? refuseLoad;
  Exception? refuseSave;
  Exception? refuseDelete;
  Exception? refuseReorder;
  int _nextId = 100;

  @override
  Future<Result<List<UnitChecklistKind>>> loadChecklistKinds() async {
    final error = refuseLoad;
    return error == null ? Ok(kinds) : Error(error);
  }

  @override
  Future<Result<List<UnitAttributeDefinition>>> loadAttributeDefinitions(
    int assetTypeId,
  ) async {
    final error = refuseLoad;
    return error == null ? Ok(fields) : Error(error);
  }

  @override
  Future<Result<UnitAttributeDefinition>> saveAttributeDefinition(
    UnitAttributeDefinition definition,
  ) async {
    saved.add(definition);
    final error = refuseSave;
    if (error != null) return Error(error);
    final stored = UnitAttributeDefinition(
      id: definition.id == 0 ? _nextId++ : definition.id,
      assetTypeId: definition.assetTypeId,
      key: definition.key.isEmpty
          ? 'field_${fields.length + 1}'
          : definition.key,
      label: definition.label,
      dataType: definition.dataType,
      choices: [
        for (final (index, choice) in definition.choices.indexed)
          UnitAttributeChoice(
            value: choice.value.isEmpty ? 'opt_${index + 1}' : choice.value,
            label: choice.label,
          ),
      ],
      suffix: definition.suffix,
      isRequired: definition.isRequired,
      showInPicker: definition.showInPicker,
      showOnLabel: definition.showOnLabel,
      showOnReceipt: definition.showOnReceipt,
    );
    final exists = fields.any((field) => field.id == stored.id);
    fields = [
      for (final field in fields) field.id == stored.id ? stored : field,
      if (!exists) stored,
    ];
    return Ok(stored);
  }

  @override
  Future<Result<void>> deleteAttributeDefinition(int definitionId) async {
    deleted.add(definitionId);
    final error = refuseDelete;
    if (error != null) return Error(error);
    fields = [
      for (final field in fields)
        if (field.id != definitionId) field,
    ];
    return const Ok(null);
  }

  @override
  Future<Result<List<UnitAttributeDefinition>>> reorderAttributeDefinitions(
    int assetTypeId,
    List<int> definitionIds,
  ) async {
    reorders.add(definitionIds);
    final error = refuseReorder;
    if (error != null) return Error(error);
    final byId = {for (final field in fields) field.id: field};
    fields = [for (final id in definitionIds) byId[id]!];
    return Ok(fields);
  }
}
