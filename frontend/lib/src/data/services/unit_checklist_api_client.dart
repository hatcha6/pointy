import 'package:http/http.dart' as http;

import '../models/unit_attribute.dart';
import '../models/unit_checklist_kind.dart';
import 'api_session.dart';

/// Writing the condition checklists — «قوائم فحص الأجهزة» — each kind of
/// device records at intake. Reading one kind's list stays with
/// `UnitDetailApiClient.fetchAttributeDefinitions`, which the capture sheet
/// already uses.
///
/// Every write throws [PosApiException] on a refusal, carrying the server's
/// per-field Arabic messages (`label`, `choices`, `suffix`, `data_type`).
class UnitChecklistApiClient {
  const UnitChecklistApiClient(this._session);

  final PosApiSession _session;

  static const _path = 'unit-attribute-definitions/';

  /// Every active kind of device, with how long its checklist is.
  Future<List<UnitChecklistKind>> fetchKinds() async {
    final response = await _session.get('${_path}summary/');
    _session.throwApiException(response, 'Checklist kinds failed with status');
    final decoded = _session.decodedBody(response);
    if (decoded is! List<Object?>) {
      return const [];
    }
    return decoded
        .whereType<Map<String, Object?>>()
        .map(UnitChecklistKind.fromJson)
        .toList(growable: false);
  }

  Future<UnitAttributeDefinition> create(
    UnitAttributeDefinition definition,
  ) async {
    final response = await _session.post(_path, body: definition.toJson());
    _session.throwApiException(response, 'Checklist field create failed');
    return _definition(response);
  }

  /// A PATCH of everything the editor shows. The server refuses a changed
  /// type outright and never moves the key; neither is sent.
  Future<UnitAttributeDefinition> update(
    UnitAttributeDefinition definition,
  ) async {
    final body = definition.toJson()
      ..remove('asset_type')
      ..remove('data_type');
    final response = await _session.patch(
      '$_path${definition.id}/',
      body: body,
    );
    _session.throwApiException(response, 'Checklist field update failed');
    return _definition(response);
  }

  Future<void> delete(int definitionId) async {
    final response = await _session.delete('$_path$definitionId/');
    _session.throwApiException(response, 'Checklist field delete failed');
  }

  /// One kind's fields in their new order, top to bottom. Answers the whole
  /// list as the server stored it.
  Future<List<UnitAttributeDefinition>> reorder(
    int assetTypeId,
    List<int> definitionIds,
  ) async {
    final response = await _session.post(
      '${_path}reorder/',
      body: {'asset_type': assetTypeId, 'ids': definitionIds},
    );
    _session.throwApiException(response, 'Checklist reorder failed');
    final decoded = _session.decodedBody(response);
    if (decoded is! List<Object?>) {
      return const [];
    }
    return decoded
        .whereType<Map<String, Object?>>()
        .map(UnitAttributeDefinition.fromJson)
        .toList(growable: false);
  }

  UnitAttributeDefinition _definition(http.Response response) =>
      UnitAttributeDefinition.fromJson(
        _session.decodedBody(response) as Map<String, Object?>,
      );
}
