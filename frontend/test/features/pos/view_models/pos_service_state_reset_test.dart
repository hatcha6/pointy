import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/services_fake_repository.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';

/// What one cashier half-typed, and what the last customers were, is nobody
/// else's: the next person at the till — another sign-in, another shift — finds
/// the airtime form empty, no recent numbers and a directory read afresh.
void main() {
  late PreviewServicesRepository relay;
  late _Register register;
  late PosViewModel viewModel;

  Future<void> halfTypedForm() async {
    final shelves = viewModel.serviceShelves;
    await shelves.catalog!.ensureLoaded();
    await shelves.airtime!.loadRecents();
    final airtime = shelves.airtime!;
    airtime.selectCountry(shelves.catalog!.directory!.country('ML')!);
    airtime.onPhoneInput('70123');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(airtime.country, isNotNull, reason: 'the form really was filled');
    expect(airtime.recents, isNotEmpty);
    expect(shelves.catalog!.directory, isNotNull);
  }

  void expectForgotten() {
    final shelves = viewModel.serviceShelves;
    expect(shelves.airtime!.country, isNull);
    expect(shelves.airtime!.national, isEmpty);
    expect(shelves.airtime!.recents, isEmpty);
    expect(shelves.catalog!.directory, isNull);
  }

  setUp(() async {
    relay = PreviewServicesRepository();
    register = _Register();
    viewModel = PosViewModel(
      _Catalog(),
      register,
      SaleRepository(PosApiService()),
      ShopSettingsRepository(PosApiService()),
      PrintingRepository(PosApiService()),
      integrationsRepository: relay,
      sessionStorage: MemoryScopedJsonStorage(),
    );
    addTearDown(viewModel.dispose);
    await viewModel.loadCurrentRegisterSession();
    await viewModel.resumeRegisterSession();
  });

  test(
    'a signed-out till forgets the form, the recents and the directory',
    () async {
      await halfTypedForm();

      viewModel.resetServiceState();

      expectForgotten();
    },
  );

  test('a different user signing in finds none of it', () async {
    await viewModel.restorePersistedSessions('user-1');
    await halfTypedForm();

    await viewModel.restorePersistedSessions('user-2');

    expectForgotten();
  });

  test('the same user signing in again keeps their form', () async {
    await viewModel.restorePersistedSessions('user-1');
    await halfTypedForm();

    await viewModel.restorePersistedSessions('user-1');

    expect(viewModel.serviceShelves.airtime!.country, isNotNull);
  });

  test('a new shift starts clean', () async {
    await halfTypedForm();

    register.sessionId = 3;
    await viewModel.loadCurrentRegisterSession();
    await viewModel.resumeRegisterSession();

    expectForgotten();
  });

  test('the same shift, read again, is the same shift', () async {
    await halfTypedForm();

    await viewModel.loadCurrentRegisterSession();
    await viewModel.resumeRegisterSession();

    expect(viewModel.serviceShelves.airtime!.country, isNotNull);
  });

  test(
    'prices waiting to be shown to the last cashier are not shown to the next',
    () async {
      viewModel.serviceRequotes.add([]);
      viewModel.resetServiceState();

      expect(viewModel.serviceRequotes.hasPending, isFalse);
    },
  );

  test(
    'a directory forgotten is read again when the pane next opens',
    () async {
      await halfTypedForm();
      final reads = relay.directoryReads;
      viewModel.resetServiceState();

      await viewModel.serviceShelves.catalog!.ensureLoaded();

      expect(relay.directoryReads, reads + 1);
      expect(viewModel.serviceShelves.catalog!.directory, isNotNull);
    },
  );
}

class _Catalog extends CatalogRepository {
  _Catalog() : super(PosApiService());

  @override
  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
    bool bypassCache = false,
  }) async => const Ok(ProductPage(products: <Product>[], hasMore: false));
}

class _Register extends RegisterSessionRepository {
  _Register() : super(PosApiService());

  int sessionId = 2;

  @override
  Future<Result<RegisterSession?>> loadCurrentSession() async => Ok(
    RegisterSession(
      id: sessionId,
      sessionNumber: 'RS-$sessionId',
      status: 'open',
      openingCash: 100,
    ),
  );
}
