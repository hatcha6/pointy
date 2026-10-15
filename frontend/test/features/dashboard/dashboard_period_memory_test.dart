import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/src/data/repositories/dashboard_repository.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/dashboard/view_models/dashboard_view_model.dart';

/// The dashboard remembers each user's chosen range, on its own key.
void main() {
  late List<String> requestedDays;

  DashboardViewModel build(ScopedJsonStorage storage, String? scope) {
    final apiService = PosApiService(
      client: MockClient((request) async {
        requestedDays.add(request.url.queryParameters['days'] ?? '');
        return http.Response(
          jsonEncode({'generated_at': '2026-10-15T09:00:00Z', 'sections': {}}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    return DashboardViewModel(
      DashboardRepository(apiService),
      canRequestAiDigest: () => false,
      periodStorage: storage,
      periodScope: scope,
    );
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() => requestedDays = []);

  test('a user reopens the dashboard on the range they last chose', () async {
    final storage = MemoryScopedJsonStorage();
    final first = build(storage, '7');
    await settle();
    expect(first.selectedDays, 30);
    await first.changePeriod(90);
    first.dispose();

    requestedDays.clear();
    final again = build(storage, '7');
    await settle();
    await settle();
    expect(again.selectedDays, 90);
    // Straight onto the saved range — no 30-day fetch first.
    expect(requestedDays, ['90']);
    again.dispose();
  });

  test('each user keeps their own range', () async {
    final storage = MemoryScopedJsonStorage();
    final manager = build(storage, '1');
    await settle();
    await manager.changePeriod(7);
    manager.dispose();

    final owner = build(storage, '2');
    await settle();
    expect(owner.selectedDays, 30);
    owner.dispose();

    final managerAgain = build(storage, '1');
    await settle();
    expect(managerAgain.selectedDays, 7);
    managerAgain.dispose();
  });

  test('a saved range the toolbar does not offer is ignored', () async {
    final storage = MemoryScopedJsonStorage();
    await storage.save('3', '45');
    final vm = build(storage, '3');
    await settle();
    expect(vm.selectedDays, 30);
    vm.dispose();
  });

  test('no signed-in user means nothing is remembered', () async {
    final storage = MemoryScopedJsonStorage();
    final vm = build(storage, null);
    await settle();
    await vm.changePeriod(7);
    expect(await storage.load(''), isNull);
    vm.dispose();
  });
}
