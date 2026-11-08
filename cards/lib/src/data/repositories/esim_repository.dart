import 'package:flutter/foundation.dart';

import '../../core/result.dart';
import '../api/relay_api.dart';
import '../models/esim.dart';

/// The eSIM shelf and the customer's eSIMs. The shelf is public, but asked with
/// the session when there is one: while the relay's eSIMs are still in review
/// with Airalo, only the stores' review account is shown them. A customer's
/// eSIMs need a signed-in session.
class EsimRepository {
  EsimRepository({required this.api});

  final RelayApi api;

  /// The shelf as last read. The home page's entry listens: it appears once the
  /// relay says eSIMs are on sale, and never before.
  final ValueNotifier<EsimShelf> shelf = ValueNotifier(EsimShelf.closed);

  /// Moves when an eSIM was bought, topped up or renamed here.
  final ValueNotifier<int> changes = ValueNotifier(0);

  /// The rows already read answer again at once, and a shelf that could not be
  /// read keeps what it had.
  Future<Result<EsimShelf>> loadShelf() => Result.guard(() async {
    final answer = EsimShelf.fromJson(
      await api.get('/v1/customers/esim/destinations', withSession: true),
    );
    shelf.value = answer;
    return answer;
  });

  Future<Result<EsimDestination>> destination(String key) =>
      Result.guard(() async {
        return EsimDestination.fromJson(
          await api.get(
            '/v1/customers/esim/destinations/${Uri.encodeComponent(key)}',
            withSession: true,
          ),
        );
      });

  /// Does this hardware model take eSIMs? Null when nobody can tell right now.
  Future<EsimModelCheck?> checkModel(String model) async {
    final result = await Result.guard(
      () => api.post(
        '/v1/customers/esim/device',
        body: {'model': model},
        withSession: true,
      ),
    );
    if (result case Ok(:final value)) {
      if (value['known'] != true) {
        return null;
      }
      return EsimModelCheck(
        supported: value['supported'] == true,
        listed: value['listed'] != false,
        name: value['name'] is String ? value['name'] as String : '',
      );
    }
    return null;
  }

  Future<Result<List<CustomerEsim>>> esims() => Result.guard(() async {
    final answer = await api.get('/v1/customers/esims', signedIn: true);
    return [
      for (final row in answer['esims'] as List? ?? const [])
        CustomerEsim.fromJson(row as Map<String, dynamic>),
    ];
  });

  /// One eSIM, with how to install it.
  Future<Result<CustomerEsim>> esim(String iccid) => Result.guard(() async {
    final answer = await api.get(
      '/v1/customers/esims/${Uri.encodeComponent(iccid)}',
      signedIn: true,
    );
    return CustomerEsim.fromJson(answer['esim'] as Map<String, dynamic>);
  });

  /// The eSIM a delivered order issued; null when the order has none (yet).
  Future<Result<CustomerEsim?>> esimOfOrder(String orderId) =>
      Result.guard(() async {
        final answer = await api.get(
          '/v1/customers/esims',
          query: {'order': orderId},
          signedIn: true,
        );
        final rows = answer['esims'] as List? ?? const [];
        return rows.isEmpty
            ? null
            : CustomerEsim.fromJson(rows.first as Map<String, dynamic>);
      });

  Future<Result<List<EsimPlan>>> topUps(String iccid) => Result.guard(() async {
    final answer = await api.get(
      '/v1/customers/esims/${Uri.encodeComponent(iccid)}/topups',
      signedIn: true,
    );
    return [
      for (final row in answer['plans'] as List? ?? const [])
        EsimPlan.fromJson(row as Map<String, dynamic>),
    ];
  });

  Future<Result<CustomerEsim>> rename(String iccid, String label) =>
      Result.guard(() async {
        final answer = await api.put(
          '/v1/customers/esims/${Uri.encodeComponent(iccid)}',
          signedIn: true,
          body: {'label': label},
        );
        changes.value++;
        return CustomerEsim.fromJson(answer['esim'] as Map<String, dynamic>);
      });
}

/// Airalo's word on a hardware model. A model off its list ([listed] false) is
/// not a verdict: it may well take an eSIM.
class EsimModelCheck {
  const EsimModelCheck({
    required this.supported,
    required this.listed,
    required this.name,
  });

  final bool supported;
  final bool listed;
  final String name;
}
