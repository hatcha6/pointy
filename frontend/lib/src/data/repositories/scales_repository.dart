import 'dart:typed_data';

import '../../core/result.dart';
import '../models/scale.dart';
import '../services/pos_api_service.dart';

/// The shop's weighing scales.
class ScalesRepository {
  const ScalesRepository(this._service);

  final PosApiService _service;

  Future<Result<List<Scale>>> loadScales() =>
      Result.guard(() => _service.scales.fetchScales());

  Future<Result<List<ScaleDriverInfo>>> loadDrivers() =>
      Result.guard(() => _service.scales.fetchDrivers());

  Future<Result<Scale>> saveScale({
    int? id,
    required Map<String, Object?> draft,
  }) {
    return Result.guard(
      () => id == null
          ? _service.scales.createScale(draft)
          : _service.scales.updateScale(id: id, changes: draft),
    );
  }

  Future<Result<void>> deleteScale(int id) =>
      Result.guard(() => _service.scales.deleteScale(id));

  Future<Result<ScaleReachability>> checkScale(int id) =>
      Result.guard(() => _service.scales.checkScale(id));

  Future<Result<ScalePushJob>> pushScale(int id) =>
      Result.guard(() => _service.scales.pushScale(id));

  Future<Result<List<ScalePushJob>>> loadPushes(int id) =>
      Result.guard(() => _service.scales.fetchPushes(id));

  Future<Result<(String, Uint8List)>> exportPluFile(int id) =>
      Result.guard(() => _service.scales.exportPluFile(id));

  Future<Result<List<ScalePlu>>> loadPlus() =>
      Result.guard(() => _service.scales.fetchPlus());

  Future<Result<ScalePlu>> assignPlu({
    required int variantId,
    String labelName = '',
    int tareGrams = 0,
    int? shelfLifeDays,
  }) {
    return Result.guard(
      () => _service.scales.assignPlu(
        variantId: variantId,
        labelName: labelName,
        tareGrams: tareGrams,
        shelfLifeDays: shelfLifeDays,
      ),
    );
  }

  Future<Result<ScalePlu>> updatePlu({
    required int id,
    required Map<String, Object?> changes,
  }) {
    return Result.guard(
      () => _service.scales.updatePlu(id: id, changes: changes),
    );
  }
}
