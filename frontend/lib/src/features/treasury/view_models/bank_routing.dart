import 'package:flutter/widgets.dart';

import '../../../core/result.dart';
import '../../../data/models/card_terminal.dart';
import '../../../data/models/money_position.dart';
import '../../../data/repositories/treasury_repository.dart';

/// Where the shop's card and transfer money goes, available to any screen.
///
/// Three surfaces need the same two lists — the till's payment sheet, the
/// record-payment dialog behind every collection and settlement, and the
/// settings screen that edits them. Threading a repository through all three
/// (and through every preview harness and widget test that builds one) to
/// forward a list they only read is the plumbing a scope exists to avoid, so
/// this follows the companion camera's pattern: screens that want it look it
/// up, and screens that do not — tests, previews, an older build — get nothing
/// and behave exactly as they did before bank accounts existed.
///
/// Loaded once and kept. The lists change when an owner opens the settings
/// screen, which is rare enough that refetching per checkout would be a round
/// trip on the busiest screen in the shop for an answer that has not moved.
class BankRouting extends ChangeNotifier {
  BankRouting(this._repository);

  final TreasuryRepository _repository;

  List<MoneyAccount> _bankAccounts = const [];
  List<CardTerminal> _terminals = const [];
  bool _hasLoaded = false;
  Future<void>? _inFlight;

  /// Active bank accounts only. A cash box is not a choice at checkout — the
  /// money goes in the drawer that is open — and a provider float is not a
  /// place a customer's card payment can land.
  List<MoneyAccount> get bankAccounts => _bankAccounts;
  List<CardTerminal> get terminals => _terminals;
  bool get hasLoaded => _hasLoaded;

  /// The account a slip from this terminal belongs to, or null when the
  /// terminal is unknown, unmapped, or the shop maps nothing.
  ///
  /// Matching folds the confusable glyphs an OCR'd id can carry (O↔0, S↔5),
  /// exactly as the server does — a till that routed by a stricter rule than
  /// the one the server trusts by would show the cashier one bank and record
  /// another.
  MoneyAccount? accountForTerminal(String? terminalId) {
    final needle = _foldTerminalId(terminalId);
    if (needle.isEmpty) {
      return null;
    }
    for (final terminal in _terminals) {
      if (!terminal.isActive || terminal.moneyAccountId == null) {
        continue;
      }
      if (_foldTerminalId(terminal.terminalId) != needle) {
        continue;
      }
      for (final account in _bankAccounts) {
        if (account.id == terminal.moneyAccountId) {
          return account;
        }
      }
    }
    return null;
  }

  /// Loads both lists, once. Safe to call from every screen's `initState`.
  Future<void> load({bool force = false}) {
    if (_hasLoaded && !force) {
      return Future<void>.value();
    }
    final inFlight = _inFlight;
    if (inFlight != null) {
      return inFlight;
    }
    late final Future<void> future;
    future = _load().whenComplete(() {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    });
    _inFlight = future;
    return future;
  }

  Future<void> _load() async {
    final accounts = await _repository.loadAccounts();
    final terminals = await _repository.loadCardTerminals();
    // A failure is silence, never an error state: the till must ring up a sale
    // whether or not the treasury screen answers, and a shop with no accounts
    // configured is the same picture as a shop whose request failed — no
    // picker, money routed the way it always was.
    if (accounts is Ok<List<MoneyAccount>>) {
      _bankAccounts = accounts.value
          .where(
            (account) =>
                account.isActive && account.kind == MoneyAccountKind.bank,
          )
          .toList(growable: false);
    }
    if (terminals is Ok<List<CardTerminal>>) {
      _terminals = terminals.value;
    }
    _hasLoaded = true;
    notifyListeners();
  }
}

String _foldTerminalId(String? value) {
  final buffer = StringBuffer();
  for (final rune in (value ?? '').toUpperCase().runes) {
    final character = String.fromCharCode(rune);
    if (!RegExp(r'[0-9A-Z]').hasMatch(character)) {
      continue;
    }
    buffer.write(_confusable[character] ?? character);
  }
  return buffer.toString();
}

/// The glyphs a terminal id is misread as, folded to one representative each.
/// Mirrors `apps/payments/card_receipts/ocr.py`; the ids are short, uppercase
/// and meaningless, so nothing in the string says which reading is right.
const _confusable = <String, String>{
  'O': '0',
  'Q': '0',
  'D': '0',
  'I': '1',
  'L': '1',
  'Z': '2',
  'S': '5',
  'B': '8',
  'G': '6',
};

/// Makes [BankRouting] reachable from any screen. Absent in tests and
/// previews, where every surface falls back to today's behaviour.
class BankRoutingScope extends InheritedNotifier<BankRouting> {
  const BankRoutingScope({
    super.key,
    required BankRouting routing,
    required super.child,
  }) : super(notifier: routing);

  static BankRouting? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<BankRoutingScope>()
        ?.notifier;
  }

  /// The bank accounts a payment may land in, or an empty list when nothing
  /// is configured or no scope is installed.
  static List<MoneyAccount> accountsOf(BuildContext context) {
    return maybeOf(context)?.bankAccounts ?? const [];
  }
}
