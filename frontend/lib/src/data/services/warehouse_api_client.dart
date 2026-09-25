import '../models/stock_transfer.dart';
import '../models/stock_unit.dart';
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
    _session.ensureSuccess(
      response,
      'Creating the warehouse failed with status',
    );
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
    _session.ensureSuccess(
      response,
      'Deleting the warehouse failed with status',
    );
  }

  /// Where every unit of one product is sitting.
  Future<List<WarehouseStockRow>> fetchStockByWarehouse(int variantId) async {
    final response = await _session.get(
      'stock/',
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
    _session.ensureSuccess(
      response,
      'Register profile request failed with status',
    );
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
    _session.ensureSuccess(
      response,
      'Saving the till warehouse failed with status',
    );
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

  /// Products a place actually holds, matching a search.
  ///
  /// One call answers both halves of "what can I send from here": which
  /// products, and how many of each. Asking the catalog and then asking stock
  /// per result would be a query per row and would still let somebody pick
  /// something the source has none of.
  Future<List<WarehouseStockRow>> searchStockAt({
    required int warehouseId,
    String search = '',
  }) async {
    final response = await _session.get(
      'stock/',
      query: <String, String>{
        'warehouse': '$warehouseId',
        'page_size': '40',
        if (search.trim().isNotEmpty) 'search': search.trim(),
      },
    );
    _session.ensureSuccess(response, 'Stock search failed with status');
    final decoded = _session.decodedBody(response);
    final rows = decoded is Map
        ? (decoded['results'] as List<Object?>? ?? const <Object?>[])
        : (decoded as List<Object?>? ?? const <Object?>[]);
    return rows
        .whereType<Map>()
        .map((row) => WarehouseStockRow.fromJson(row.cast<String, Object?>()))
        .toList(growable: false);
  }

  // -- transfers -------------------------------------------------------

  Future<List<StockTransfer>> fetchTransfers({String? status}) async {
    final response = await _session.get(
      'stock-transfers/',
      query: <String, String>{
        'page_size': '100',
        if (status != null && status.isNotEmpty) 'status': status,
      },
    );
    _session.ensureSuccess(response, 'Transfers request failed with status');
    final decoded = _session.decodedBody(response);
    final rows = decoded is Map
        ? (decoded['results'] as List<Object?>? ?? const <Object?>[])
        : (decoded as List<Object?>? ?? const <Object?>[]);
    return rows
        .whereType<Map>()
        .map((row) => StockTransfer.fromJson(row.cast<String, Object?>()))
        .toList(growable: false);
  }

  Future<StockTransfer> createTransfer(StockTransferDraft draft) async {
    final response = await _session.post(
      'stock-transfers/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Creating the transfer failed with status',
    );
    return StockTransfer.fromJson(
      (_session.decodedBody(response) as Map).cast<String, Object?>(),
    );
  }

  /// Send a draft transfer on its way.
  ///
  /// ``picks`` maps a line id to the identified stock that line is carrying —
  /// which handsets, and out of which lots. A serialized line is refused
  /// without one, deliberately: the van driver has already physically chosen
  /// five, and a system that picked a different five would make the far end's
  /// *«sent 5, arrived 4»* reconciliation a lie about which one is gone.
  Future<StockTransfer> dispatchTransfer(
    int id, {
    Map<int, TransferLinePick> picks = const {},
  }) async {
    final response = await _session.post(
      'stock-transfers/$id/dispatch/',
      body: <String, Object?>{
        if (picks.isNotEmpty)
          'picks': {
            for (final entry in picks.entries)
              '${entry.key}': entry.value.toJson(),
          },
      },
    );
    _session.ensureSuccess(response, 'Sending the transfer failed with status');
    return StockTransfer.fromJson(
      (_session.decodedBody(response) as Map).cast<String, Object?>(),
    );
  }

  /// ``lines`` maps a transfer line id to how much of it arrived, in base
  /// units.
  Future<StockTransfer> receiveTransfer(
    int id,
    Map<int, double> lines, {
    String note = '',
    Map<int, TransferLinePick> picks = const {},
  }) async {
    final response = await _session.post(
      'stock-transfers/$id/receive/',
      body: <String, Object?>{
        if (note.trim().isNotEmpty) 'note': note.trim(),
        if (picks.isNotEmpty)
          'picks': {
            for (final entry in picks.entries)
              '${entry.key}': entry.value.toJson(),
          },
        'lines': [
          for (final entry in lines.entries)
            <String, Object?>{
              'line': entry.key,
              'quantity': entry.value.toString(),
            },
        ],
      },
    );
    _session.ensureSuccess(
      response,
      'Receiving the transfer failed with status',
    );
    return StockTransfer.fromJson(
      (_session.decodedBody(response) as Map).cast<String, Object?>(),
    );
  }

  Future<StockTransfer> cancelTransfer(int id, String reason) async {
    final response = await _session.post(
      'stock-transfers/$id/cancel/',
      body: <String, Object?>{'reason': reason},
    );
    _session.ensureSuccess(
      response,
      'Cancelling the transfer failed with status',
    );
    return StockTransfer.fromJson(
      (_session.decodedBody(response) as Map).cast<String, Object?>(),
    );
  }
}
