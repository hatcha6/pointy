import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/features/learning/content/learning_library.dart';
import 'package:pointy_frontend/src/features/learning/models/learning_guide.dart';
import 'package:pointy_frontend/src/features/learning/models/learning_query.dart';
import 'package:pointy_frontend/src/features/learning/view_models/learning_view_model.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';

import '../shared/fake_app_navigation.dart';
import '../shared/role_fixtures.dart';

/// A guide's «افتح الشاشة» is a promise that its reader can get there.
///
/// The gate on a guide decides who «ما تسمح به صلاحياتي» shows it to, and the
/// screen it opens has a gate of its own. When the two drift apart the guide
/// either points its reader at a door that stays shut, or hides from the
/// people who work that screen every day — which is what the places guide did
/// while it was gated on reading stock levels rather than on the places.
void main() {
  final readers = <String, PosUser>{
    'manager': managerUser,
    'purchasing agent': userWithRole(
      UserRole.purchasingAgent,
      purchasingAgentPermissions,
    ),
    'auditor': userWithRole(UserRole.auditor, auditorPermissions),
    'accountant': userWithRole(UserRole.accountant, accountantPermissions),
    'a till with no grants': userWithRole(UserRole.cashier, const {}),
    'places only': _clerkWith({'inventory.view_warehouse'}),
    'transfers only': _clerkWith({'inventory.view_stocktransfer'}),
    'stock levels only': _clerkWith({'inventory.view_stockitem'}),
  };

  test('a guide that matches its reader never opens a screen they cannot '
      'reach', () {
    final deadEnds = <String>[];
    for (final MapEntry(key: reader, value: user) in readers.entries) {
      final navigation = FakeAppNavigation(currentUser: user);
      for (final guide in _matching(navigation)) {
        if (guide.opens case final opens?
            when !navigation.isDestinationAvailable(opens)) {
          deadEnds.add('$reader: ${guide.id} -> ${opens.name}');
        }
      }
    }
    expect(deadEnds, isEmpty);
  });

  group('the places and transfers guides', () {
    final places = learningGuidesById['inventory.warehouses']!;
    final transfers = learningGuidesById['inventory.transfers']!;

    Set<String> matchedFor(PosUser user) => {
      for (final guide in _matching(FakeAppNavigation(currentUser: user)))
        guide.id,
    };

    test('each opens its own screen, gated on the right that screen needs', () {
      expect(places.opens, AppNavigationDestination.warehouses);
      expect(transfers.opens, AppNavigationDestination.stockTransfers);
      expect(
        places.capability,
        appNavigationDestinationCapability(places.opens!),
      );
      expect(
        transfers.capability,
        appNavigationDestinationCapability(transfers.opens!),
      );
    });

    test('each matches whoever holds its view right, and only that', () {
      final placesOnly = matchedFor(readers['places only']!);
      final transfersOnly = matchedFor(readers['transfers only']!);

      expect(placesOnly, contains(places.id));
      expect(placesOnly, isNot(contains(transfers.id)));
      expect(transfersOnly, contains(transfers.id));
      expect(transfersOnly, isNot(contains(places.id)));
    });

    test('reading stock levels is not seeing the places', () {
      // The old gate: it matched this reader to a guide about two screens they
      // could not open, and missed both readers above.
      final stockOnly = matchedFor(readers['stock levels only']!);

      expect(stockOnly, isNot(contains(places.id)));
      expect(stockOnly, isNot(contains(transfers.id)));
    });

    test('every stock role matches both', () {
      for (final reader in ['purchasing agent', 'auditor', 'accountant']) {
        expect(
          matchedFor(readers[reader]!),
          containsAll([places.id, transfers.id]),
          reason: reader,
        );
      }
    });

    test('they link to each other', () {
      expect(places.related, contains(transfers.id));
      expect(transfers.related, contains(places.id));
    });
  });
}

/// An inventory clerk holding only [permissions], so each reader is exactly
/// the rights it is named for.
PosUser _clerkWith(Set<String> permissions) =>
    userWithRole(UserRole.inventoryClerk, permissions);

/// The guides «ما تسمح به صلاحياتي» offers [navigation]'s user.
List<LearningGuide> _matching(AppNavigation navigation) {
  final viewModel =
      LearningViewModel(
          capabilities: navigation.capabilities,
          userId: navigation.currentUser.id,
        )
        ..initialize()
        ..setQuery(
          const LearningQuery(audience: LearningAudienceFilter.myPermissions),
        );
  return viewModel.results;
}
