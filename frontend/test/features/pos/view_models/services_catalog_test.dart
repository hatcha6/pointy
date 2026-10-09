import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/services_fake_repository.dart';
import 'package:pointy_frontend/dev/services_fixtures.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/service_country_detail.dart';
import 'package:pointy_frontend/src/data/models/services_directory.dart';
import 'package:pointy_frontend/src/features/pos/view_models/services_catalog.dart';

/// What the services know of the world: read once and kept, a country at a
/// time. Flags ship with the app and are never asked for.
void main() {
  late PreviewServicesRepository repository;
  late ServicesCatalog catalog;

  setUp(() {
    repository = PreviewServicesRepository();
    catalog = ServicesCatalog(repository: repository);
  });

  tearDown(() => catalog.dispose());

  Future<void> settle([int milliseconds = 60]) =>
      Future<void>.delayed(Duration(milliseconds: milliseconds));

  group('the directory', () {
    test('is read once and held', () async {
      expect(catalog.directory, isNull);
      final first = catalog.ensureLoaded();
      expect(catalog.isLoadingDirectory, isTrue);
      await first;
      await catalog.ensureLoaded();

      expect(catalog.directory!.countries, isNotEmpty);
      expect(catalog.isLoadingDirectory, isFalse);
      expect(repository.directoryReads, 1);
    });

    test('shares one read between two askers', () async {
      await Future.wait([catalog.ensureLoaded(), catalog.ensureLoaded()]);

      expect(repository.directoryReads, 1);
    });

    test('says it could not be read, and reads again on request', () async {
      repository.failDirectory = true;
      await catalog.ensureLoaded();
      expect(catalog.hasDirectoryError, isTrue);
      expect(catalog.directory, isNull);

      repository.failDirectory = false;
      await catalog.reload();

      expect(catalog.hasDirectoryError, isFalse);
      expect(catalog.directory, isNotNull);
    });

    test('keeps what it has when a re-read fails', () async {
      await catalog.ensureLoaded();
      repository.failDirectory = true;
      await catalog.reload();

      expect(catalog.directory, isNotNull);
      expect(catalog.hasDirectoryError, isFalse, reason: 'stale beats blank');
    });

    test('gives a search for airtime, and one for each type of bill', () async {
      expect(catalog.airtimeSearch, isNull);
      await catalog.ensureLoaded();

      expect(catalog.airtimeSearch!.countries.length, greaterThan(20));
      expect(catalog.airtimeSearch!.unsupported, isNotEmpty);
      final bills = catalog.billSearch(
        catalog.directory!.billTypes.first.type,
      )!;
      expect(bills.unsupported, isEmpty, reason: 'named for airtime only');
      expect(identical(catalog.airtimeSearch, catalog.airtimeSearch), isTrue);
    });

    test('a screen that opens does not read one that is still fresh', () async {
      await catalog.ensureFresh();
      await catalog.ensureFresh();

      expect(repository.directoryReads, 1);
    });

    test('a screen that opens reads again once it is old', () async {
      await catalog.ensureFresh();
      final held = catalog.directory;

      await catalog.ensureFresh(maxAge: Duration.zero);

      expect(repository.directoryReads, 2);
      expect(catalog.directory, isNot(same(held)));
    });

    test(
      'keeps showing what it has while the new read is on its way',
      () async {
        await catalog.ensureFresh();
        repository.directoryDelay = const Duration(milliseconds: 30);

        final reading = catalog.ensureFresh(maxAge: Duration.zero);

        expect(catalog.directory, isNotNull, reason: 'stale beats blank');
        expect(catalog.isLoadingDirectory, isFalse);
        await reading;
      },
    );

    test('a failed read of an old directory keeps it', () async {
      await catalog.ensureFresh();
      repository.failDirectory = true;

      await catalog.ensureFresh(maxAge: Duration.zero);

      expect(catalog.directory, isNotNull);
      expect(catalog.hasDirectoryError, isFalse);
    });

    test('countries read under an older edition are read again', () async {
      await catalog.ensureLoaded();
      await catalog.loadDetail('ML');
      await catalog.loadDetail('NG');
      expect(repository.countryReads, {'ML': 1, 'NG': 1});

      repository.directory = ServicesDirectory.fromJson({
        ...servicesPreviewDirectoryJson(),
        'version': 'a-newer-edition',
      });
      await catalog.reload();

      expect(catalog.directory!.version, 'a-newer-edition');
      expect(catalog.detailOf('ML'), isNull);
      await catalog.loadDetail('ML');
      expect(repository.countryReads['ML'], 2);
    });

    test('countries are kept when the edition did not change', () async {
      await catalog.ensureLoaded();
      final detail = await catalog.loadDetail('ML');

      await catalog.reload();

      expect(catalog.detailOf('ML'), same(detail));
    });

    test('is forgotten whole when the till changes hands', () async {
      await catalog.ensureLoaded();
      await catalog.loadDetail('ML');

      catalog.clear();

      expect(catalog.directory, isNull);
      expect(catalog.detailOf('ML'), isNull);
      expect(catalog.airtimeSearch, isNull);
      await catalog.ensureFresh();
      expect(repository.directoryReads, 2);
    });
  });

  group('a country', () {
    test('is read when asked for, once, and kept', () async {
      expect(catalog.detailOf('ML'), isNull);
      final read = catalog.loadDetail('ml');
      expect(catalog.isLoadingDetail('ML'), isTrue);
      final detail = await read;

      expect(detail!.operators, hasLength(3));
      expect(catalog.detailOf('ML'), same(detail));
      await catalog.loadDetail('ML');
      expect(repository.countryReads['ML'], 1);
    });

    test('shares one read between two askers', () async {
      await Future.wait([catalog.loadDetail('NG'), catalog.loadDetail('NG')]);

      expect(repository.countryReads['NG'], 1);
    });

    test('says it could not be read, and can be read again by force', () async {
      repository.failCountries.add('ML');
      expect(await catalog.loadDetail('ML'), isNull);
      expect(catalog.hasDetailError('ML'), isTrue);

      repository.failCountries.clear();
      expect(await catalog.loadDetail('ML', force: true), isNotNull);
      expect(catalog.hasDetailError('ML'), isFalse);
    });

    test('are read in the background, each once', () async {
      catalog.prefetchDetails(['NG', 'ML', 'NG']);
      await settle();
      catalog.prefetchDetails(['NG', 'ML']);
      await settle();

      expect(repository.countryReads, {'NG': 1, 'ML': 1});
      expect(catalog.detailOf('NG'), isNotNull);
    });

    test(
      'an answer that forgot to name the country still belongs to it',
      () async {
        final nameless = _NamelessRepository();
        final other = ServicesCatalog(repository: nameless);
        await other.ensureLoaded();

        final detail = await other.loadDetail('ML');

        expect(detail!.country.code, 'ML');
        expect(detail.country.dial, ['223'], reason: 'from the directory');
        other.dispose();
      },
    );
  });
}

/// A directory with Mali in it, and a country answer with no `country` in it.
class _NamelessRepository extends PreviewServicesRepository {
  @override
  Future<Result<ServiceCountryDetail>> loadServiceCountry(String code) async {
    final result = await super.loadServiceCountry(code);
    return switch (result) {
      Ok(:final value) => Ok(
        ServiceCountryDetail(
          country: const ServiceCountry(code: ''),
          operators: value.operators,
          billers: value.billers,
        ),
      ),
      Error(:final exception) => Error(exception),
    };
  }
}
