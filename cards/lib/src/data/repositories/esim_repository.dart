import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/result.dart';
import '../api/relay_api.dart';
import '../models/esim.dart';
import '../vault/esim_vault.dart';

/// The eSIM shelf and the customer's eSIMs. The shelf is public, but asked with
/// the session when there is one: while the relay's eSIMs are still in review
/// with Airalo, only the stores' review account is shown them. A customer's
/// eSIMs need a signed-in session.
class EsimRepository {
  EsimRepository({
    required this.api,
    this.preferences,
    this.vault,
    String Function()? owner,
  }) : _owner = owner ?? _nobody;

  final RelayApi api;

  /// Where the shelf and the destinations opened are kept, so they show at
  /// once and still show offline. Null in tests: nothing is kept.
  final SharedPreferencesAsync? preferences;

  /// Where the customer's own eSIMs are kept. Null in tests: nothing is kept.
  final EsimVault? vault;

  /// Who is asking: the signed-in customer's id, or empty. The relay may show
  /// one account a shelf it shows nobody else, so a saved copy is only ever
  /// shown to whoever it was read for.
  final String Function() _owner;
  static String _nobody() => '';

  static const _shelfKey = 'cards.esim.shelf';
  static String _destinationKey(String key) => 'cards.esim.destination.$key';

  /// The shelf as last read. The home page's entry listens: it appears once the
  /// relay says eSIMs are on sale (now, or when this device last asked), and
  /// never before.
  final ValueNotifier<EsimShelf> shelf = ValueNotifier(EsimShelf.closed);

  /// Whose shelf [shelf] holds; null while it holds nobody's.
  String? _shelfOwner;

  /// The destinations read since launch, by key, for [_destinationsOwner].
  final Map<String, EsimDestination> _destinations = {};
  String? _destinationsOwner;

  /// Moves when an eSIM was bought, topped up or renamed here.
  final ValueNotifier<int> changes = ValueNotifier(0);

  /// A saved answer and the tag the relay gave it, when it was saved for
  /// [owner] and can still be read.
  Future<({Map<String, dynamic> body, String? etag})?> _saved(
    String key,
    String owner,
  ) async {
    try {
      final raw = await preferences?.getString(key);
      if (raw == null) {
        return null;
      }
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      if (saved['owner'] != owner) {
        return null;
      }
      return (
        body: saved['body'] as Map<String, dynamic>,
        etag: saved['etag'] as String?,
      );
    } on Object {
      // A saved copy that cannot be read is no saved copy.
      return null;
    }
  }

  Future<void> _save(
    String key,
    String owner,
    Map<String, dynamic> body,
    String? etag,
  ) async {
    try {
      await preferences?.setString(
        key,
        jsonEncode({'owner': owner, 'etag': ?etag, 'body': body}),
      );
    } on Object {
      // A full or failing disk costs the saved copy, not what is on screen.
    }
  }

  /// [path] as the relay has it now. The saved copy's tag goes with the
  /// question: an answer that did not change costs a 304 and no download.
  Future<T> _fresh<T>(
    String path,
    String key,
    T Function(Map<String, dynamic>) read,
  ) async {
    final owner = _owner();
    // Only a copy that reads can be answered "not modified".
    final saved = await _saved(key, owner);
    T? kept;
    try {
      kept = saved == null ? null : read(saved.body);
    } on Object {
      kept = null;
    }
    final answer = await api.getIfChanged(
      path,
      etag: kept == null ? null : saved?.etag,
      withSession: true,
    );
    if (answer == null) {
      return kept as T;
    }
    final value = read(answer.body);
    // An answer that was on its way while the customer changed is kept for
    // nobody.
    if (_owner() == owner) {
      await _save(key, owner, answer.body, answer.etag);
    }
    return value;
  }

  /// The shelf this device last read for whoever is asking, or null.
  Future<EsimShelf?> cachedShelf() async {
    final owner = _owner();
    if (_shelfOwner == owner) {
      return shelf.value;
    }
    final saved = await _saved(_shelfKey, owner);
    if (saved == null) {
      return null;
    }
    try {
      final kept = EsimShelf.fromJson(saved.body);
      // A fresher answer may have landed while the disk was read.
      if (_shelfOwner != owner && _owner() == owner) {
        _shelfOwner = owner;
        shelf.value = kept;
      }
      return _shelfOwner == owner ? shelf.value : kept;
    } on Object {
      return null;
    }
  }

  /// The shelf as the relay has it now. The saved copy shows first, and a
  /// shelf that could not be read keeps what it had.
  Future<Result<EsimShelf>> loadShelf() async {
    final owner = _owner();
    await cachedShelf();
    return Result.guard(() async {
      final answer = await _fresh(
        '/v1/customers/esim/destinations',
        _shelfKey,
        EsimShelf.fromJson,
      );
      // The customer changed on the way: shown (the change asks again), but
      // nobody's.
      _shelfOwner = _owner() == owner ? owner : null;
      shelf.value = answer;
      return answer;
    });
  }

  /// A destination as this device last read it for whoever is asking.
  Future<EsimDestination?> cachedDestination(String key) async {
    final owner = _owner();
    if (_destinationsOwner == owner && _destinations[key] != null) {
      return _destinations[key];
    }
    final saved = await _saved(_destinationKey(key), owner);
    if (saved == null) {
      return null;
    }
    try {
      return EsimDestination.fromJson(saved.body);
    } on Object {
      return null;
    }
  }

  Future<Result<EsimDestination>> destination(String key) =>
      Result.guard(() async {
        final owner = _owner();
        final answer = await _fresh(
          '/v1/customers/esim/destinations/${Uri.encodeComponent(key)}',
          _destinationKey(key),
          EsimDestination.fromJson,
        );
        if (_owner() == owner) {
          if (_destinationsOwner != owner) {
            _destinationsOwner = owner;
            _destinations.clear();
          }
          _destinations[key] = answer;
        }
        return answer;
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
    final customer = _customer;
    final answer = await api.get('/v1/customers/esims', signedIn: true);
    final rows = [
      for (final row in answer['esims'] as List? ?? const [])
        if (row is Map<String, dynamic>) row,
    ];
    final list = [for (final row in rows) CustomerEsim.fromJson(row)];
    // An answer that was on its way while the customer changed is not kept.
    if (customer == _customer) {
      lastEsims = list;
      final kept = await _keptRows();
      if (customer == _customer) {
        // The list carries no install details: those already read stay.
        await _keep({
          for (final row in rows)
            row['iccid'] as String: {
              'install': ?kept[row['iccid']]?['install'],
              ...row,
            },
        });
      }
    }
    return list;
  });

  /// Moves with every [forget].
  int _customer = 0;

  /// The customer's eSIMs as last read, shown at once while they are read
  /// again. Null before the first read, and after [forget].
  List<CustomerEsim>? lastEsims;

  /// The vault's rows by ICCID, as the relay sent them; read once.
  Map<String, Map<String, dynamic>>? _rows;

  Future<Map<String, Map<String, dynamic>>> _keptRows() async {
    if (_rows case final known?) {
      return known;
    }
    final customer = _customer;
    final owner = _owner();
    var rows = <String, Map<String, dynamic>>{};
    try {
      final raw = owner.isEmpty ? null : await vault?.read();
      if (raw != null) {
        final saved = jsonDecode(raw) as Map<String, dynamic>;
        if (saved['owner'] == owner) {
          rows = {
            for (final row in saved['esims'] as List)
              if (row is Map<String, dynamic>) row['iccid'] as String: row,
          };
        }
      }
    } on Object {
      // A keychain that cannot be read is an empty one.
      rows = {};
    }
    if (customer != _customer) {
      return {};
    }
    return _rows ??= rows;
  }

  Future<void> _keep(Map<String, Map<String, dynamic>> rows) async {
    _rows = rows;
    final owner = _owner();
    if (owner.isEmpty) {
      return;
    }
    try {
      await vault?.write(
        jsonEncode({'owner': owner, 'esims': rows.values.toList()}),
      );
    } on Object {
      // A keychain that cannot be written costs the saved copy only.
    }
  }

  /// One row read again, or read with its install details.
  Future<void> _keepRow(Map<String, dynamic> row, int customer) async {
    final iccid = row['iccid'];
    if (iccid is! String || customer != _customer) {
      return;
    }
    final kept = await _keptRows();
    if (customer != _customer) {
      return;
    }
    await _keep({
      ...kept,
      iccid: {'install': ?kept[iccid]?['install'], ...row},
    });
  }

  /// The customer's eSIMs as this phone holds them, newest first as the relay
  /// listed them: what «شرائحي» shows with no network. Empty when none.
  Future<List<CustomerEsim>> keptEsims() async {
    if (lastEsims case final known?) {
      return known;
    }
    try {
      return [
        for (final row in (await _keptRows()).values)
          CustomerEsim.fromJson(row),
      ];
    } on Object {
      return const [];
    }
  }

  /// One eSIM as this phone holds it, by its ICCID or by the order that
  /// issued it; with how to install it once that was read here.
  Future<CustomerEsim?> keptEsim({String? iccid, String? orderId}) async {
    try {
      for (final row in (await _keptRows()).values) {
        if (iccid != null
            ? row['iccid'] == iccid
            : orderId != null && row['order_id'] == orderId) {
          return CustomerEsim.fromJson(row);
        }
      }
    } on Object {
      // Falls through: nothing held.
    }
    return null;
  }

  /// Whoever was signed in has gone: nothing of theirs is kept in memory.
  /// What the keychain holds is theirs alone, and goes with [clearKept].
  void forget() {
    _customer++;
    lastEsims = null;
    _rows = null;
  }

  /// Signed out, or the account deleted: the keychain forgets the eSIMs.
  Future<void> clearKept() async {
    _rows = null;
    await vault?.clear();
  }

  /// One eSIM, with how to install it.
  Future<Result<CustomerEsim>> esim(String iccid) => Result.guard(() async {
    final customer = _customer;
    final answer = await api.get(
      '/v1/customers/esims/${Uri.encodeComponent(iccid)}',
      signedIn: true,
    );
    final row = answer['esim'] as Map<String, dynamic>;
    final esim = CustomerEsim.fromJson(row);
    await _keepRow(row, customer);
    return esim;
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
        final customer = _customer;
        final answer = await api.put(
          '/v1/customers/esims/${Uri.encodeComponent(iccid)}',
          signedIn: true,
          body: {'label': label},
        );
        final row = answer['esim'] as Map<String, dynamic>;
        await _keepRow(row, customer);
        changes.value++;
        return CustomerEsim.fromJson(row);
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
