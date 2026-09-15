import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/app_dependencies.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';

/// The authenticated shell rebuilds a fresh `AuthorizationCapabilities` every
/// time it builds, and that class has no value equality — so a cache keyed on
/// the capabilities object would dispose the view model the mounted learning
/// screen is still listening to, and the next notify would throw.
void main() {
  late PointyAppDependencies dependencies;

  setUp(() {
    dependencies = PointyAppDependencies(
      apiService: PosApiService(baseUrl: 'http://localhost'),
    );
  });

  tearDown(() => dependencies.dispose());

  test('the same user keeps the same instance across rebuilds', () {
    final first = dependencies.learningViewModel(
      7,
      AuthorizationCapabilities.forUser(_user(7, UserRole.cashier)),
    );
    final second = dependencies.learningViewModel(
      7,
      AuthorizationCapabilities.forUser(_user(7, UserRole.cashier)),
    );

    expect(identical(first, second), isTrue);
    // Still usable: a disposed ChangeNotifier throws here.
    expect(() => first.initialize(), returnsNormally);
  });

  test('a different user gets their own capabilities', () {
    final cashier = dependencies.learningViewModel(
      7,
      AuthorizationCapabilities.forUser(_user(7, UserRole.cashier)),
    );
    final manager = dependencies.learningViewModel(
      9,
      AuthorizationCapabilities.forUser(_user(9, UserRole.manager)),
    );

    expect(identical(cashier, manager), isFalse);
    expect(manager.capabilities.allows(AppCapability.managePayroll), isTrue);
  });
}

PosUser _user(int id, UserRole role) =>
    PosUser(id: id, username: 'u$id', role: role, isActive: true);
