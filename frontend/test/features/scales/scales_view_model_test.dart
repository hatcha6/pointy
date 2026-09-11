import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/scale.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/scales_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/scales/view_models/scales_view_model.dart';

class _FakeScalesRepository extends ScalesRepository {
  _FakeScalesRepository({this.scales = const [], this.push})
    : super(PosApiService());

  final List<Scale> scales;
  final ScalePushJob? push;
  int pushCalls = 0;

  @override
  Future<Result<List<Scale>>> loadScales() async => Ok(scales);

  @override
  Future<Result<List<ScaleDriverInfo>>> loadDrivers() async => const Ok([
    ScaleDriverInfo(
      key: 'file_export',
      label: 'ملف PLU',
      needsAddress: false,
      defaultPort: 0,
    ),
    ScaleDriverInfo(
      key: 'cas_cl5000',
      label: 'CAS',
      needsAddress: true,
      defaultPort: 20304,
    ),
  ]);

  @override
  Future<Result<List<ScalePlu>>> loadPlus() async => const Ok([
    ScalePlu(id: 1, variantId: 10, pluNumber: 1, printedName: 'طماطم'),
    ScalePlu(
      id: 2,
      variantId: 11,
      pluNumber: 2,
      printedName: 'خيار',
      isActive: false,
    ),
  ]);

  @override
  Future<Result<List<ScalePushJob>>> loadPushes(int id) async =>
      Ok(push == null ? const [] : [push!]);

  @override
  Future<Result<ScalePushJob>> pushScale(int id) async {
    pushCalls += 1;
    return Ok(push ?? const ScalePushJob(id: 1, status: 'exported'));
  }

  @override
  Future<Result<(String, Uint8List)>> exportPluFile(int id) async {
    return Ok(('plu.csv', Uint8List.fromList('1,x,1.00,1,0'.codeUnits)));
  }
}

ScalesViewModel _viewModel(_FakeScalesRepository repository) {
  return ScalesViewModel(repository, CatalogRepository(PosApiService()));
}

void main() {
  const scale = Scale(id: 1, name: 'ميزان', driver: 'file_export');

  group('ScalesViewModel', () {
    test('loads scales, drivers and the PLU list together', () async {
      final model = _viewModel(_FakeScalesRepository(scales: const [scale]));
      await model.load();

      expect(model.scales.single.name, 'ميزان');
      expect(model.drivers.length, 2);
      expect(model.driverFor('cas_cl5000')?.defaultPort, 20304);
    });

    test('counts only the PLUs that are still live', () async {
      // A retired PLU is kept — its stickers may still be in the shop — but it
      // is not something the scale is being told about any more.
      final model = _viewModel(_FakeScalesRepository(scales: const [scale]));
      await model.load();

      expect(model.plus.length, 2);
      expect(model.assignedCount, 1);
    });

    test('an exported file is not reported as delivered prices', () async {
      final repository = _FakeScalesRepository(
        scales: const [scale],
        push: const ScalePushJob(
          id: 1,
          status: 'exported',
          pluCount: 1,
          sentCount: 1,
          filename: 'plu.csv',
        ),
      );
      final model = _viewModel(repository);
      await model.load();
      final job = await model.push(scale.id);

      expect(job, isNotNull);
      expect(job!.delivered, isFalse);
      expect(model.lastPushFor(scale.id)?.status, 'exported');
    });

    test('a wire push that landed is delivered', () async {
      final repository = _FakeScalesRepository(
        scales: const [scale],
        push: const ScalePushJob(
          id: 2,
          status: 'succeeded',
          pluCount: 3,
          sentCount: 3,
        ),
      );
      final model = _viewModel(repository);
      await model.load();

      expect((await model.push(scale.id))!.delivered, isTrue);
    });

    test('a half-landed push is neither delivered nor a failure', () async {
      final job = const ScalePushJob(
        id: 3,
        status: 'partial',
        pluCount: 3,
        sentCount: 2,
        failedCount: 1,
        errors: {'7': 'refused'},
      );
      expect(job.delivered, isFalse);
      expect(job.isFailure, isFalse);
      expect(job.errors['7'], 'refused');
    });

    test('the export comes back as a saveable file', () async {
      final model = _viewModel(_FakeScalesRepository(scales: const [scale]));
      await model.load();
      final file = await model.exportFile(scale.id);

      expect(file, isNotNull);
      expect(file!.filename, 'plu.csv');
      expect(file.sizeBytes, greaterThan(0));
    });
  });

  group('Scale model', () {
    test('reads what the server says about needing an address', () {
      final parsed = Scale.fromJson(const {
        'id': 4,
        'name': 'CAS',
        'driver': 'cas_cl5000',
        'driver_label': 'CAS CL5000 / CL7200',
        'needs_address': true,
        'host': '192.168.1.50',
        'port': 20304,
        'is_active': true,
      });
      expect(parsed.needsAddress, isTrue);
      expect(parsed.host, '192.168.1.50');
      expect(parsed.port, 20304);
    });

    test('a push job with no finish time is still readable', () {
      final job = ScalePushJob.fromJson(const {
        'id': 9,
        'status': 'pending',
        'plu_count': 0,
      });
      expect(job.finishedAt, isNull);
      expect(job.delivered, isFalse);
    });
  });
}
