import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../core/result.dart';
import '../../../data/models/voucher_account.dart';

/// Where the look-up of the typed account stands.
enum VoucherAccountCheckState { idle, checking, done, failed }

/// The account a card goes to, as the cashier fills it in at the till.
///
/// A shop sells to many customers, so the shop's book is searched as the first
/// field is typed: typing a known ID, a name or a customer finds their account,
/// and a new one is simply typed through. Looked up (where the game can) once
/// the typing pauses, so the cashier reads the player's name back before taking
/// the money — a top-up cannot be taken back from a wrong account.
class VoucherAccountFormModel extends ChangeNotifier {
  VoucherAccountFormModel({
    required this.brandKey,
    required this.target,
    required this.checkVariantId,
    this.customerId,
    this.loadSaved,
    this.check,
    this.rename,
    this.forget,
    this.searchAfter = const Duration(milliseconds: 220),
    this.checkAfter = const Duration(milliseconds: 650),
  }) {
    for (final field in target.fields) {
      if (field.isSelect) {
        _selected[field.key] = field.options.length == 1
            ? field.options.single.value
            : null;
      } else {
        final controller = TextEditingController();
        controller.addListener(() => _edited(field));
        _controllers[field.key] = controller;
        _focus[field.key] = FocusNode();
      }
    }
  }

  final String brandKey;
  final VoucherTarget target;

  /// Any card of the brand: the look-up only needs the game.
  final int? checkVariantId;
  final int? customerId;
  final Future<Result<SavedVoucherAccountPage>> Function({
    required String brand,
    String search,
    int? customer,
  })?
  loadSaved;
  final Future<Result<VoucherAccountCheck>> Function({
    required int variantId,
    required Map<String, String> values,
  })?
  check;
  final Future<Result<SavedVoucherAccount>> Function(int id, String label)?
  rename;
  final Future<Result<void>> Function(int id)? forget;
  final Duration searchAfter;
  final Duration checkAfter;

  final _controllers = <String, TextEditingController>{};
  final _focus = <String, FocusNode>{};
  final _selected = <String, String?>{};
  final _lastText = <String, String>{};

  List<SavedVoucherAccount> saved = const [];
  bool savedHasMore = false;
  bool savedLoaded = false;

  /// The saved account now in the fields, while they hold it unchanged.
  SavedVoucherAccount? chosen;

  /// The row arrow keys have reached in the saved list; -1 is none.
  int highlighted = -1;

  VoucherAccountCheckState checkState = VoucherAccountCheckState.idle;
  VoucherAccountCheck? checked;

  /// Every problem is shown once the cashier has tried to go on.
  bool showProblems = false;

  Timer? _searchTimer;
  Timer? _checkTimer;
  int _searchSeq = 0;
  int _checkSeq = 0;
  bool _filling = false;
  bool _disposed = false;

  TextEditingController controllerOf(String key) => _controllers[key]!;
  FocusNode focusOf(String key) => _focus[key]!;
  String? selectedOf(String key) => _selected[key];

  /// The field typing in searches the book.
  VoucherTargetField? get searchField =>
      target.fields.where((field) => !field.isSelect).firstOrNull;

  Map<String, String> get values => {
    for (final field in target.fields)
      field.key: field.isSelect
          ? _selected[field.key] ?? ''
          : target.clean(field, _controllers[field.key]!.text),
  };

  Map<String, VoucherAccountProblem> get problems {
    final current = values;
    return {
      for (final field in target.fields)
        field.key: ?target.problemWith(field, current[field.key]!),
    };
  }

  bool get complete => problems.isEmpty;

  /// The game said there is no such account: selling it could only be refused.
  bool get refused =>
      checkState == VoucherAccountCheckState.done &&
      checked?.status == VoucherAccountStatus.invalid;

  /// What the denominations wait for.
  bool get ready => complete && !refused;

  /// The player's own name, from the look-up or remembered with the account.
  String get playerName {
    final found = checked;
    if (checkState == VoucherAccountCheckState.done &&
        found?.status == VoucherAccountStatus.valid &&
        (found?.name ?? '').isNotEmpty) {
      return found!.name;
    }
    return chosen?.playerName ?? '';
  }

  /// The account on one line, as the server will write it.
  String get line => target.line(values);

  /// Reads the book as the sheet opens.
  Future<void> load() => _search('');

  void setSelect(String key, String? value) {
    _selected[key] = value;
    chosen = null;
    _accountChanged();
    notifyListeners();
  }

  void _edited(VoucherTargetField field) {
    if (_filling) {
      return;
    }
    final text = _controllers[field.key]!.text;
    if (_lastText[field.key] == text) {
      return; // A selection moved; the text did not.
    }
    final pasted = text.length - (_lastText[field.key] ?? '').length > 1;
    _lastText[field.key] = text;
    chosen = null;
    highlighted = -1;
    if (identical(field, searchField) && target.remembers) {
      _searchTimer?.cancel();
      _searchTimer = Timer(
        pasted ? Duration.zero : searchAfter,
        () => unawaited(_search(target.clean(field, text))),
      );
    }
    _accountChanged(now: pasted);
    notifyListeners();
  }

  void _accountChanged({bool now = false}) {
    _checkTimer?.cancel();
    _checkSeq++;
    checked = null;
    checkState = VoucherAccountCheckState.idle;
    if (!complete || !target.checkable) {
      return;
    }
    if (now) {
      unawaited(_check());
    } else {
      _checkTimer = Timer(checkAfter, () => unawaited(_check()));
    }
  }

  Future<void> _check() async {
    final ask = check;
    final variant = checkVariantId;
    if (ask == null || variant == null || !complete) {
      return;
    }
    final seq = ++_checkSeq;
    final account = values;
    checkState = VoucherAccountCheckState.checking;
    _notify();
    final result = await ask(variantId: variant, values: account);
    if (_disposed || seq != _checkSeq) {
      return; // The account has changed since it was asked about.
    }
    switch (result) {
      case Ok<VoucherAccountCheck>(:final value):
        checked = value;
        checkState = VoucherAccountCheckState.done;
      case Error<VoucherAccountCheck>():
        checkState = VoucherAccountCheckState.failed;
    }
    notifyListeners();
  }

  Future<void> _search(String text) async {
    final read = loadSaved;
    if (read == null || !target.remembers) {
      return;
    }
    final seq = ++_searchSeq;
    final result = await read(
      brand: brandKey,
      search: text,
      customer: customerId,
    );
    if (_disposed || seq != _searchSeq) {
      return;
    }
    if (result case Ok<SavedVoucherAccountPage>(:final value)) {
      // An account the shop's book has moved past this brand's fields (a game
      // that added a server) cannot fill the form in.
      saved = value.accounts
          .where(
            (account) => target.fields.every(
              (field) => account.values.containsKey(field.key),
            ),
          )
          .toList(growable: false);
      savedHasMore = value.hasMore;
      highlighted = -1;
    }
    savedLoaded = true;
    notifyListeners();
  }

  /// Puts a saved account in the fields, and looks it up again at once: a name
  /// remembered from last month may have changed hands.
  void use(SavedVoucherAccount account) {
    _filling = true;
    for (final field in target.fields) {
      final value = account.values[field.key] ?? '';
      if (field.isSelect) {
        _selected[field.key] = value.isEmpty ? null : value;
      } else {
        _controllers[field.key]!.text = value;
        _lastText[field.key] = value;
      }
    }
    _filling = false;
    chosen = account;
    showProblems = false;
    _searchTimer?.cancel();
    _accountChanged(now: true);
    notifyListeners();
  }

  /// Empties the fields, and shows the whole book again.
  void clear() {
    _filling = true;
    for (final field in target.fields) {
      if (field.isSelect) {
        _selected[field.key] = field.options.length == 1
            ? field.options.single.value
            : null;
      } else {
        _controllers[field.key]!.clear();
        _lastText[field.key] = '';
      }
    }
    _filling = false;
    chosen = null;
    showProblems = false;
    _accountChanged();
    unawaited(_search(''));
    notifyListeners();
    final first = searchField;
    if (first != null) {
      focusOf(first.key).requestFocus();
    }
  }

  /// Moves through the saved list with the arrow keys. False past its ends.
  bool moveHighlight(int by) {
    if (saved.isEmpty) {
      return false;
    }
    final next = highlighted + by;
    highlighted = next < -1
        ? saved.length - 1
        : next >= saved.length
        ? -1
        : next;
    notifyListeners();
    return true;
  }

  /// Enter on a highlighted row chooses it. False with nothing highlighted.
  bool useHighlighted() {
    if (highlighted < 0 || highlighted >= saved.length) {
      return false;
    }
    use(saved[highlighted]);
    return true;
  }

  Future<void> renameAccount(SavedVoucherAccount account, String label) async {
    final ask = rename;
    if (ask == null) {
      return;
    }
    final result = await ask(account.id, label.trim());
    if (_disposed) {
      return;
    }
    if (result case Ok<SavedVoucherAccount>()) {
      final named = account.named(label.trim());
      saved = [
        for (final row in saved)
          if (row.id == account.id) named else row,
      ];
      if (chosen?.id == account.id) {
        chosen = named;
      }
      notifyListeners();
    }
  }

  Future<void> forgetAccount(SavedVoucherAccount account) async {
    saved = saved.where((row) => row.id != account.id).toList(growable: false);
    if (chosen?.id == account.id) {
      chosen = null;
    }
    highlighted = -1;
    notifyListeners();
    await forget?.call(account.id);
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _searchTimer?.cancel();
    _checkTimer?.cancel();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final node in _focus.values) {
      node.dispose();
    }
    super.dispose();
  }
}
