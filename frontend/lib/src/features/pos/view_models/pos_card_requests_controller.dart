import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/card_request.dart';
import '../../../data/models/integration_card.dart';
import '../../../data/models/sale_order.dart';
import '../../../shared/barcode/scan_feedback_sounds.dart';

/// Whose lines the panel follows: the company's own shelf, read back by key.
const String cardRequestsProvider = 'pointy';

/// What runs when a handed-off sale has finished: prints its receipt.
typedef CardRequestPrinter =
    Future<Object?> Function(List<IntegrationChargeResult> performed);

/// What the till sold from the company's shelf, and how each request ended.
///
/// FazerCards can take minutes to finish an order, and a cashier with a queue
/// cannot stand at a spinner for that. So a sale is recorded, its request goes
/// out, and this follows it: asks the server while anything is open (the server
/// asks the relay, at most every few seconds a line), keeps the history for a
/// glance, and says when something ended. Lives with the till's view model, so
/// it survives the window crossing a breakpoint and the cart changing.
class PosCardRequestsController extends ChangeNotifier {
  PosCardRequestsController({
    Future<Result<List<CardRequest>>> Function()? load,
    Future<Result<List<CardRequest>>> Function(List<int> lines)? settle,
    Future<Result<List<IntegrationChargeResult>>> Function({
      required int orderId,
      bool noWait,
    })?
    charge,
    @visibleForTesting void Function(bool succeeded)? onEnded,
  }) : _load = load,
       _settle = settle,
       _charge = charge,
       _onEnded = onEnded;

  final Future<Result<List<CardRequest>>> Function()? _load;
  final Future<Result<List<CardRequest>>> Function(List<int> lines)? _settle;
  final Future<Result<List<IntegrationChargeResult>>> Function({
    required int orderId,
    bool noWait,
  })?
  _charge;
  final void Function(bool succeeded)? _onEnded;

  /// How long to wait between asks, in seconds: soon at first, when most orders
  /// finish, then easing off. A supplier taking minutes costs a dozen asks.
  static const List<int> pollSeconds = [3, 3, 4, 5, 6, 8, 10, 12];
  static const int _pollCeilingSeconds = 15;
  static const int _keep = 80;

  /// A success says so for this long; a failure stays until it is read.
  static const Duration successNoticeFor = Duration(seconds: 8);

  final Map<int, CardRequest> _rows = {};
  final Set<int> _quiet = {};
  final Map<int, CardRequestPrinter> _printers = {};
  final List<CardRequest> _notices = [];
  final Map<int, Timer> _noticeTimers = {};
  Timer? _poll;
  int _pollStep = 0;
  bool _asking = false;
  bool _started = false;
  bool _disposed = false;
  bool _panelOpen = false;
  int _unseenSucceeded = 0;
  int _unseenFailed = 0;

  bool get isSupported => _settle != null;

  /// Open first, then the newest.
  List<CardRequest> get requests {
    final rows = _rows.values.toList()
      ..sort((a, b) {
        if (a.isOpen != b.isOpen) {
          return a.isOpen ? -1 : 1;
        }
        return (b.createdAt ?? _epoch).compareTo(a.createdAt ?? _epoch);
      });
    return rows;
  }

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  int get openCount => _rows.values.where((row) => row.isOpen).length;
  int get unseenSucceeded => _unseenSucceeded;
  int get unseenFailed => _unseenFailed;
  bool get hasAny => _rows.isNotEmpty;
  bool get panelOpen => _panelOpen;

  /// What just ended, the newest first, while the panel is closed.
  List<CardRequest> get notices => List.unmodifiable(_notices);

  /// Reads the history once, as the till opens. Failures that came in while it
  /// was closed are still news; nothing else from the past is.
  Future<void> start() async {
    final load = _load;
    if (load == null || _started || _disposed) {
      return;
    }
    _started = true;
    final result = await load();
    if (_disposed) {
      return;
    }
    if (result case Ok<List<CardRequest>>(:final value)) {
      final recently = DateTime.now().subtract(const Duration(hours: 2));
      for (final row in value) {
        if (_rows.containsKey(row.orderLine)) {
          continue;
        }
        _rows[row.orderLine] = row;
        if (row.isFailed && (row.finishedAt?.isAfter(recently) ?? false)) {
          _unseenFailed++;
        }
      }
      _trim();
      _schedule();
      notifyListeners();
    }
  }

  /// Follows the lines of a sale just recorded. Quiet until [CardRequestTicket.
  /// handOff]: a card that answers while the result dialog waits is said there.
  CardRequestTicket trackSale(
    SaleOrder order, {
    required Future<List<IntegrationChargeResult>> charge,
  }) {
    final now = DateTime.now();
    final lines = <int>{};
    for (final line in order.lines) {
      final integration = line.integration;
      if (integration == null) {
        continue;
      }
      lines.add(line.id);
      _quiet.add(line.id);
      _rows[line.id] = CardRequest(
        orderLine: line.id,
        orderId: order.id,
        state: CardRequestState.working,
        label: integration.optionLabel,
        receiptNumber: order.receiptNumber ?? '',
        kind: integration.kind,
        account: integration.subscriberRef,
        amount: line.total,
        createdAt: now,
      );
    }
    _trim();
    _notify();
    unawaited(charge.then(_mergeAnswers));
    return CardRequestTicket._(this, lines);
  }

  void _handOff(Set<int> lines, CardRequestPrinter? printWhenDone) {
    _quiet.removeAll(lines);
    if (printWhenDone != null) {
      for (final line in lines) {
        _printers[line] = printWhenDone;
      }
    }
    _pollStep = 0;
    _schedule();
    // It may have ended in the very moment it was handed over.
    for (final line in lines) {
      final row = _rows[line];
      if (row != null && !row.isOpen) {
        _announce(row);
        _printIfFinished(row);
      }
    }
    _notify();
  }

  void _mergeAnswers(List<IntegrationChargeResult> answers) {
    if (_disposed) {
      return;
    }
    final merged = <CardRequest>[];
    for (final answer in answers) {
      final line = answer.orderLine;
      final current = line == null ? null : _rows[line];
      // Only ever onward: a late answer knows less than a read-back.
      if (current != null && current.isOpen) {
        merged.add(current.answeredBy(answer));
      }
    }
    _merge(merged);
  }

  /// Takes what the server says of each row, and says what just ended.
  void _merge(List<CardRequest> incoming) {
    var changed = false;
    for (final row in incoming) {
      if (row.orderLine <= 0) {
        continue;
      }
      final before = _rows[row.orderLine];
      _rows[row.orderLine] = row;
      changed = true;
      if (before != null && before.isOpen && !row.isOpen) {
        if (!_quiet.contains(row.orderLine)) {
          _announce(row);
          _printIfFinished(row);
        }
      }
    }
    if (changed) {
      _schedule();
      _notify();
    }
  }

  void _announce(CardRequest row) {
    if (row.state == CardRequestState.cancelled) {
      return;
    }
    (_onEnded ?? _playEnded)(row.isSucceeded);
    if (row.isSucceeded) {
      _unseenSucceeded++;
    } else {
      _unseenFailed++;
    }
    if (_panelOpen) {
      return;
    }
    _notices.insert(0, row);
    if (_notices.length > 3) {
      _dropNotice(_notices.last.orderLine);
    }
    if (row.isSucceeded) {
      _noticeTimers[row.orderLine]?.cancel();
      _noticeTimers[row.orderLine] = Timer(
        successNoticeFor,
        () => dismissNotice(row.orderLine),
      );
    }
  }

  static void _playEnded(bool succeeded) => ScanFeedbackSounds.instance.play(
    succeeded ? ScanFeedback.success : ScanFeedback.error,
  );

  /// One receipt for the whole sale, once every line of it has ended, with
  /// everything on it. Nothing to print when nothing was delivered.
  void _printIfFinished(CardRequest row) {
    final printer = _printers[row.orderLine];
    if (printer == null) {
      return;
    }
    final siblings = _rows.values
        .where((other) => other.orderId == row.orderId)
        .toList(growable: false);
    if (siblings.any((other) => other.isOpen)) {
      return;
    }
    for (final other in siblings) {
      _printers.remove(other.orderLine);
    }
    if (siblings.any((other) => other.isSucceeded)) {
      unawaited(
        printer([for (final other in siblings) other.toChargeResult()]),
      );
    }
  }

  void _schedule() {
    if (_disposed || _poll != null || _asking) {
      return;
    }
    final followed = _rows.values.any(
      (row) => row.isOpen && !_quiet.contains(row.orderLine),
    );
    if (!followed || _settle == null) {
      return;
    }
    final seconds = _pollStep < pollSeconds.length
        ? pollSeconds[_pollStep]
        : _pollCeilingSeconds;
    _pollStep++;
    _poll = Timer(Duration(seconds: seconds), () {
      _poll = null;
      unawaited(_ask());
    });
  }

  Future<void> _ask() async {
    final settle = _settle;
    if (settle == null || _disposed) {
      return;
    }
    final open = [
      for (final row in _rows.values)
        if (row.isOpen && !_quiet.contains(row.orderLine)) row.orderLine,
    ];
    if (open.isEmpty) {
      return;
    }
    _asking = true;
    final result = await settle(open);
    _asking = false;
    if (_disposed) {
      return;
    }
    if (result case Ok<List<CardRequest>>(:final value)) {
      _merge(value);
    }
    // Whether it answered or not: an open request is never left unfollowed.
    _schedule();
  }

  /// Sends a request whose sale was recorded but which never left (the till
  /// lost the network, or closed, in between). Safe to press: the server allows
  /// each line one attempt, ever.
  Future<void> sendQueued(CardRequest request) async {
    final charge = _charge;
    if (charge == null || !request.isOpen) {
      return;
    }
    _rows[request.orderLine] = request.answeredBy(
      IntegrationChargeResult(
        fulfillment: null,
        outcome: 'unknown',
        kind: request.kind,
        inProgress: true,
      ),
    );
    _notify();
    final result = await charge(orderId: request.orderId, noWait: true);
    if (_disposed) {
      return;
    }
    if (result case Ok<List<IntegrationChargeResult>>(:final value)) {
      _mergeAnswers(value);
    }
    _pollStep = 0;
    _schedule();
  }

  /// False when there is nothing to show, so the key is not swallowed.
  bool togglePanel() {
    if (!_panelOpen && _rows.isEmpty) {
      return false;
    }
    setPanelOpen(!_panelOpen);
    return true;
  }

  void setPanelOpen(bool open) {
    if (_panelOpen == open) {
      return;
    }
    _panelOpen = open;
    if (open) {
      _unseenSucceeded = 0;
      _unseenFailed = 0;
      for (final notice in List.of(_notices)) {
        _dropNotice(notice.orderLine);
      }
    }
    _notify();
  }

  void dismissNotice(int orderLine) {
    _dropNotice(orderLine);
    _notify();
  }

  void _dropNotice(int orderLine) {
    _noticeTimers.remove(orderLine)?.cancel();
    _notices.removeWhere((row) => row.orderLine == orderLine);
  }

  void _trim() {
    if (_rows.length <= _keep) {
      return;
    }
    for (final row in requests.skip(_keep)) {
      _rows.remove(row.orderLine);
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    for (final timer in _noticeTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }
}

/// A sale the till is still waiting on, in the moment before the panel takes it.
class CardRequestTicket {
  CardRequestTicket._(this._controller, this._lines);

  final PosCardRequestsController _controller;
  final Set<int> _lines;

  /// The panel follows these lines from here, and says how they end.
  void handOff({CardRequestPrinter? printWhenDone}) =>
      _controller._handOff(_lines, printWhenDone);

  /// The dialog said how these ended, so nothing announces them; one whose
  /// answer was lost is still followed, behind the dialog that says so.
  void close() {
    _controller._quiet.removeAll(_lines);
    _controller._schedule();
  }
}
