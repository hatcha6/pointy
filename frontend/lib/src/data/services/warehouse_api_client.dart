import '../models/warehouse.dart';
import 'api_session.dart';

/// The places a shop keeps stock, and which of them each till sells from.
class WarehouseApiClient {
  const WarehouseApiClient(this._session);

  final PosApiSession _session;

  Future<List<Warehouse>> fetchWarehouses({bool activeOnly = false}) async {
    final response = await _session.get(
      'warehouses/',
      query: <String, String>{
        'page_size': '200',
        if (activeOnly) 'is_active': 'true',
      },
    );
    _session.ensureSuccess(response, 'Warehouse request failed with status');
    return _warehousesFrom(_session.decodedBody(response));
  }

  Future<Warehouse> createWarehouse(Warehouse warehouse) async {
    final response = await _session.post(
      'warehouses/',
      body: warehouse.toCreateJson(),
    );
    _session.ensureSuccess(response, 'Creating the warehouse failed with status');
    return Warehouse.fromJson(
      (_session.decodedBody(response) as Map).cast<String, Object?>(),
    );
  }

  Future<Warehouse> updateWarehouse(Warehouse warehouse) async {
    final response = await _session.patch(
      'warehouses/${warehouse.id}/',
      body: warehouse.toCreateJson(),
    );
    _session.ensureSuccess(response, 'Saving the warehouse failed with status');
    return Warehouse.fromJson(
      (_session.decodedBody(response) as Map).cast<String, Object?>(),
    );
  }

  Future<void> deleteWarehouse(int id) async {
    final response = await _session.delete('warehouses/$id/');
    _session.ensureSuccess(response, 'Deleting the warehouse failed with status');
  }

  /// Where every unit of one product is sitting.
  Future<List<WarehouseStockRow>> fetchStockByWarehouse(int variantId) async {
    final response = await _session.get(
      'stock-items/',
      query: <String, String>{'variant': '$variantId', 'page_size': '100'},
    );
    _session.ensureSuccess(response, 'Stock request failed with status');
    final decoded = _session.decodedBody(response);
    final rows = decoded is Map
        ? (decoded['results'] as List<Object?>? ?? const <Object?>[])
        : (decoded as List<Object?>? ?? const <Object?>[]);
    return rows
        .whereType<Map>()
        .map((row) => WarehouseStockRow.fromJson(row.cast<String, Object?>()))
        .toList(growable: false);
  }

  /// This till's own profile. Never throws for want of a setting: the backend
  /// answers with the shop's default when the device has no row.
  Future<RegisterProfile> fetchMyRegisterProfile() async {
    final response = await _session.get('register-profiles/me/');
    _session.ensureSuccess(response, 'Register profile request failed with status');
    return RegisterProfile.fromJson(
      (_session.decodedBody(response) as Map).cast<String, Object?>(),
    );
  }

  Future<RegisterProfile> assignMyRegisterWarehouse({
    required int warehouseId,
    String? name,
  }) async {
    final response = await _session.patch(
      'register-profiles/me/',
      body: <String, Object?>{
        'warehouse': warehouseId,
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      },
    );
    _session.ensureSuccess(response, 'Saving the till warehouse failed with status');
    return RegisterProfile.fromJson(
      (_session.decodedBody(response) as Map).cast<String, Object?>(),
    );
  }

  List<Warehouse> _warehousesFrom(Object? decoded) {
    final rows = decoded is Map
        ? (decoded['results'] as List<Object?>? ?? const <Object?>[])
        : (decoded as List<Object?>? ?? const <Object?>[]);
    return rows
        .whereType<Map>()
        .map((row) => Warehouse.fromJson(row.cast<String, Object?>()))
        .toList(growable: false);
  }
}
