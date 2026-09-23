import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/services/connection_route_reporter.dart';
import 'package:pointy_frontend/src/data/services/connection_status_controller.dart';

void main() {
  late ConnectionStatusController status;
  late List<String> moves;
  late ConnectionRouteReporter reporter;

  void start() {
    reporter = ConnectionRouteReporter(
      status,
      ({required from, required to}) => moves.add('$from>$to'),
    );
  }

  setUp(() {
    status = ConnectionStatusController();
    moves = [];
  });

  tearDown(() => reporter.dispose());

  test('reports each move between the LAN and the relay', () {
    status.update(ConnectionPhase.connectedLocal);
    start();

    status.update(ConnectionPhase.connectedRelay);
    status.update(ConnectionPhase.connectedLocal);

    expect(moves, ['lan>relay', 'relay>lan']);
  });

  test('starting out on the relay is itself worth a row', () {
    status.update(ConnectionPhase.connectedRelay);
    start();

    expect(moves, ['startup>relay']);
  });

  test('starting out on the LAN is the normal case and says nothing', () {
    status.update(ConnectionPhase.connectedLocal);
    start();

    expect(moves, isEmpty);
  });

  test('a till that found its server only later reports that move', () {
    status.update(ConnectionPhase.needsManual);
    start();

    status.update(ConnectionPhase.connectedLocal);

    expect(moves, ['startup>lan']);
  });

  test('status noise that is not a move says nothing', () {
    status.update(ConnectionPhase.connectedRelay);
    start();
    moves.clear();

    status.setSearching(true);
    status.update(ConnectionPhase.connectedRelay, shopName: 'متجر آمن');
    status.setSearching(false);

    expect(moves, isEmpty);
  });

  test('dispose stops the reports', () {
    status.update(ConnectionPhase.connectedLocal);
    start();
    reporter.dispose();

    status.update(ConnectionPhase.connectedRelay);

    expect(moves, isEmpty);
  });
}
