import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/server_state.dart';

void main() {
  group('parseServerStateHeader', () {
    test('reads the vector the backend stamps', () {
      expect(parseServerStateHeader('catalog=812,settings=37'), {
        'catalog': '812',
        'settings': '37',
      });
    });

    test('is empty for an absent or blank header', () {
      expect(parseServerStateHeader(null), isEmpty);
      expect(parseServerStateHeader(''), isEmpty);
    });

    test('skips malformed pairs instead of throwing', () {
      // A header the client cannot read must cost freshness, never the
      // response it rode in on.
      expect(parseServerStateHeader('catalog=812,,broken,=9,settings='), {
        'catalog': '812',
      });
    });

    test('keeps domains this client has never heard of', () {
      // An older client on a newer backend ignores what it has no watcher for;
      // neither side needs a coordinated release.
      final parsed = parseServerStateHeader('catalog=1,brand_new_thing=4');
      expect(parsed['brand_new_thing'], '4');
    });
  });

  group('ServerStateNotifier', () {
    test('first sighting of a domain is not a change', () {
      // Otherwise every device re-fetches everything on its first response
      // after a restart, having cached nothing under an older value.
      final state = ServerStateNotifier();
      var notifications = 0;
      state.addListener(() => notifications++);

      expect(state.apply({'catalog': '1', 'settings': '1'}), isEmpty);
      expect(notifications, 0);
      expect(state.versionOf('catalog'), '1');
    });

    test('reports only the domains whose number moved', () {
      final state = ServerStateNotifier();
      state.apply({'catalog': '1', 'settings': '1'});

      expect(state.apply({'catalog': '2', 'settings': '1'}), {'catalog'});
    });

    test('re-reading the same vector notifies nobody', () {
      // The POS would refresh in a loop otherwise: the vector arrives on every
      // single response.
      final state = ServerStateNotifier();
      state.apply({'catalog': '1'});
      var notifications = 0;
      state.addListener(() => notifications++);

      state.apply({'catalog': '1'});
      state.apply({'catalog': '1'});
      expect(notifications, 0);

      state.apply({'catalog': '2'});
      expect(notifications, 1);
    });

    test('an empty vector changes nothing', () {
      // A backend with the feature off, or Redis down, sends no header.
      final state = ServerStateNotifier();
      state.apply({'catalog': '1'});
      expect(state.apply(const {}), isEmpty);
      expect(state.versionOf('catalog'), '1');
    });

    test('reset forgets everything', () {
      // Counters belong to one backend and one session. After a reset the next
      // vector is a first sighting again, not a phantom change.
      final state = ServerStateNotifier();
      state.apply({'catalog': '9'});
      state.reset();

      expect(state.versionOf('catalog'), isNull);
      expect(state.apply({'catalog': '1'}), isEmpty);
    });
  });
}
