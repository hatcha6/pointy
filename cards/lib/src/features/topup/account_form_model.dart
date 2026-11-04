import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/result.dart';
import '../../data/accounts/saved_accounts.dart';
import '../../data/models/account_target.dart';
import '../../data/models/catalog.dart';
import '../../data/repositories/orders_repository.dart';

/// Where a look-up of the typed account stands.
enum CheckState {
  /// Nothing asked: the account is incomplete, cannot be looked up, or the
  /// customer is not signed in yet.
  idle,
  checking,

  /// The relay answered; [AccountFormModel.check] says what it found
  /// (maybe that the game has no look-up after all).
  done,

  /// The look-up itself failed (no connection, the game busy): the account
  /// may still be right.
  failed,
}

/// The account a top-up is sent to, as the customer types it on the brand
/// page: one value per field of the brand's target, read the relay's way,
/// the accounts this phone topped up before, and what a look-up found.
class AccountFormModel extends ChangeNotifier {
  AccountFormModel({
    required this.brand,
    required this.orders,
    required this.accounts,
    required this.signedIn,
  }) : assert(brand.target != null) {
    for (final field in target.fields) {
      if (field.isSelect) {
        _selected[field.key] = field.options.length == 1
            ? field.options.single.value
            : null;
      } else {
        final controller = TextEditingController();
        controller.addListener(() => _edited(field));
        _controllers[field.key] = controller;
        _focus[field.key] = FocusNode()..addListener(() => _blurred(field.key));
      }
    }
  }

  final CardBrand brand;
  final OrdersRepository orders;
  final SavedAccounts accounts;

  /// Whether the look-up may be asked now: it needs a signed-in customer.
  final bool Function() signedIn;

  AccountTarget get target => brand.target!;

  final _controllers = <String, TextEditingController>{};
  final _focus = <String, FocusNode>{};
  final _selected = <String, String?>{};

  /// Fields whose problem is shown: left with something typed, or every
  /// field once the customer tried to go on.
  final _shown = <String>{};

  /// The card asked for, which a look-up names (any of the brand's will do).
  String itemKey = '';

  /// The accounts this phone topped up before, the latest first.
  List<SavedAccount> saved = const [];

  /// The saved account now in the fields, if they hold one unchanged.
  SavedAccount? chosen;

  CheckState checkState = CheckState.idle;
  AccountCheck? check;

  /// The account [check] (or the look-up in flight) is about.
  Map<String, String>? _checkedFor;
  Timer? _settle;

  /// Set while the fields are filled in code, so the fill is not taken for
  /// the customer's own typing.
  bool _filling = false;
  bool _disposed = false;

  /// A typed account is looked up once the customer stops typing for this
  /// long.
  static const settleFor = Duration(milliseconds: 650);

  TextEditingController controllerOf(String key) => _controllers[key]!;
  FocusNode focusOf(String key) => _focus[key]!;
  String? selectedOf(String key) => _selected[key];

  /// The steam invite's link is used once: it is never kept.
  bool get remembers => target.kind != TargetKind.steamInvite;

  /// Every field as the relay will read it.
  Map<String, String> get values => {
    for (final field in target.fields)
      field.key: field.isSelect
          ? _selected[field.key] ?? ''
          : target.clean(field, _controllers[field.key]!.text),
  };

  Map<String, AccountProblem> get problems {
    final current = values;
    return {
      for (final field in target.fields)
        field.key: ?target.problemWith(field, current[field.key]!),
    };
  }

  bool get complete => problems.isEmpty;

  /// The problem to show under [key], if it is to be shown yet.
  AccountProblem? problemOf(String key) {
    if (!_shown.contains(key)) {
      return null;
    }
    return problems[key];
  }

  /// The game said there is no such account: paying would only bring the
  /// money back.
  bool get refused =>
      checkState == CheckState.done && check?.status == AccountStatus.invalid;

  /// The customer is done with the account as it stands: they left its
  /// field, pressed Done or tried to go on. Typing again takes it back.
  bool _finished = false;

  /// Still typing: a field has the cursor and the customer has not said
  /// they are done.
  bool get typing => !_finished && _focus.values.any((f) => f.hasFocus);

  /// What the look-up found, as it may be shown now. The player's name shows
  /// the moment the game gives it; «no such account» (or «could not tell»)
  /// waits until the customer has finished typing, so a pause halfway
  /// through an ID never flashes red. (Going on is refused either way:
  /// [refused].)
  AccountStatus? get shownStatus {
    final status = checkState == CheckState.done ? check?.status : null;
    return status != AccountStatus.valid && typing ? null : status;
  }

  /// The look-up has answered for the account as it stands now, or there is
  /// none to wait for.
  bool get checkSettled =>
      !target.checkable ||
      checkState == CheckState.done ||
      checkState == CheckState.failed;

  /// The player's own name, from the look-up or remembered with the account.
  String get playerName {
    if (checkState == CheckState.done &&
        check?.status == AccountStatus.valid &&
        (check?.name ?? '').isNotEmpty) {
      return check!.name;
    }
    return chosen?.name ?? '';
  }

  /// Reads this phone's accounts for the brand and puts the latest in the
  /// fields, so a second top-up is one tap.
  Future<void> load() async {
    if (!remembers) {
      return;
    }
    final list = await accounts.of(brand.key);
    if (_disposed) {
      return;
    }
    saved = list
        .where((a) => target.fields.every((f) => a.values.containsKey(f.key)))
        .toList();
    if (saved.isNotEmpty && values.values.every((v) => v.isEmpty)) {
      // Looked up at once: the game's own look-up is slow the first time
      // (seconds), and by checkout it is done.
      use(saved.first);
    } else {
      notifyListeners();
    }
  }

  /// Puts a saved account in the fields. Its remembered name stands for it
  /// until a look-up is asked (at checkout, signed in).
  void use(SavedAccount account, {bool lookUp = true}) {
    _filling = true;
    for (final field in target.fields) {
      final value = account.values[field.key] ?? '';
      if (field.isSelect) {
        _selected[field.key] = value.isEmpty ? null : value;
      } else {
        _controllers[field.key]!.text = value;
      }
    }
    _filling = false;
    chosen = account;
    _shown.clear();
    _resetCheck();
    notifyListeners();
    if (lookUp) {
      _lookUpSoon(now: true);
    }
  }

  /// Empties the fields for an account not typed before.
  void startNew() {
    _filling = true;
    for (final controller in _controllers.values) {
      controller.clear();
    }
    for (final field in target.fields.where((f) => f.isSelect)) {
      _selected[field.key] = field.options.length == 1
          ? field.options.single.value
          : null;
    }
    _filling = false;
    chosen = null;
    _shown.clear();
    _resetCheck();
    notifyListeners();
    firstField()?.requestFocus();
  }

  /// Where each account forgotten here was, should it be taken back.
  final _forgottenAt = <SavedAccount, int>{};

  /// Forgets a saved account; the one in use gives way to a new one typed.
  Future<void> forget(SavedAccount account) async {
    _forgottenAt[account] = saved.indexWhere((a) => a.same(account.values));
    final wasChosen = chosen?.same(account.values) ?? false;
    await accounts.forget(brand.key, account.values);
    saved = [
      for (final a in saved)
        if (!a.same(account.values)) a,
    ];
    if (wasChosen) {
      // The next one along takes its place, or empty fields for a new one.
      if (saved.isNotEmpty) {
        use(saved.first, lookUp: false);
        return;
      }
      startNew();
      return;
    }
    notifyListeners();
  }

  /// Takes back a forgotten account, where it was in the list.
  Future<void> restore(SavedAccount account) async {
    final at = _forgottenAt.remove(account) ?? 0;
    await accounts.restore(brand.key, account, at: at);
    saved = await accounts.of(brand.key);
    if (!_disposed) {
      notifyListeners();
    }
  }

  void select(String key, String value) {
    _selected[key] = value;
    _shown.add(key);
    _changed();
  }

  /// Done typing on the keyboard: what the game said shows, and the account
  /// is looked up now if it has not been.
  void submitted() {
    _finished = true;
    notifyListeners();
    lookUp();
  }

  /// The customer is going on: every problem shows. True when there is
  /// none.
  bool validate() {
    _finished = true;
    _shown.addAll(target.fields.map((f) => f.key));
    notifyListeners();
    return complete;
  }

  /// The first typed field with a problem (the first field when none), to
  /// put the cursor in.
  FocusNode? firstField() {
    final wrong = problems.keys.toSet();
    for (final field in target.fields.where((f) => !f.isSelect)) {
      if (wrong.isEmpty || wrong.contains(field.key)) {
        return _focus[field.key];
      }
    }
    return null;
  }

  /// Looks the account up now (the checkout asks this before paying), or
  /// waits for the look-up already on its way.
  Future<void> lookUp() {
    if (!target.checkable || !complete || !signedIn()) {
      return Future.value();
    }
    final account = values;
    if (_same(_checkedFor, account) && checkState != CheckState.failed) {
      return _asking ?? Future.value();
    }
    _settle?.cancel();
    _checkedFor = account;
    checkState = CheckState.checking;
    check = null;
    notifyListeners();
    return _asking = _ask(account);
  }

  Future<void>? _asking;

  Future<void> _ask(Map<String, String> account) async {
    final result = await orders.checkAccount(
      itemKey.isEmpty ? brand.items.first.key : itemKey,
      account,
    );
    if (_disposed || !_same(_checkedFor, account)) {
      return;
    }
    switch (result) {
      case Ok(:final value):
        check = value;
        checkState = CheckState.done;
      case Error():
        checkState = CheckState.failed;
    }
    notifyListeners();
  }

  /// Keeps the account on this phone once an order went to it, with the
  /// name the look-up gave.
  Future<void> remember() async {
    if (!remembers || !complete) {
      return;
    }
    final account = values;
    final name =
        check?.status == AccountStatus.valid && _same(_checkedFor, account)
        ? check!.name
        : '';
    await accounts.remember(brand.key, account, name: name);
    saved = await accounts.of(brand.key);
    chosen = saved.where((a) => a.same(account)).firstOrNull;
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _edited(TargetField field) {
    final controller = _controllers[field.key]!;
    final before = _lastText[field.key] ?? '';
    _lastText[field.key] = controller.text;
    if (_filling) {
      return;
    }
    // «123456789 (1234)», as some games show the ID with its zone, pasted
    // into the first field: each part goes to its own.
    if (field == target.fields.first && _splitIdAndZone(controller.text)) {
      return;
    }
    // More than one character at once is a paste (or the keyboard's
    // autofill): the whole ID is there, so it is looked up now, and what the
    // game says shows at once.
    _changed(pasted: (controller.text.length - before.length).abs() > 1);
  }

  /// Each field's text as last seen, to tell a paste from a keystroke.
  final _lastText = <String, String>{};

  bool _splitIdAndZone(String text) {
    final typed = target.fields.where((f) => !f.isSelect).toList();
    if (target.kind != TargetKind.gameAccount || typed.length < 2) {
      return false;
    }
    final match = RegExp(r'^\s*(\d+)\s*\(\s*(\d+)\s*\)\s*$')
        .firstMatch(asciiDigits(text));
    if (match == null) {
      return false;
    }
    _filling = true;
    for (final (field, value) in [
      (typed[0], match.group(1)!),
      (typed[1], match.group(2)!),
    ]) {
      _controllers[field.key]!.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }
    _filling = false;
    _changed(pasted: true);
    return true;
  }

  /// Leaving a field shows what is wrong with it, and tidies what was
  /// pasted into it («https://t.me/name» becomes «name») once that reads.
  void _blurred(String key) {
    final controller = _controllers[key]!;
    if (_focus[key]!.hasFocus) {
      return;
    }
    if (controller.text.trim().isEmpty) {
      return;
    }
    // Left with something typed: the customer is done with it for now.
    _finished = true;
    final field = target.fields.firstWhere((f) => f.key == key);
    final clean = target.clean(field, controller.text);
    if (clean != controller.text && target.problemWith(field, clean) == null) {
      _filling = true;
      controller.text = clean;
      _filling = false;
    }
    _shown.add(key);
    notifyListeners();
  }

  void _changed({bool pasted = false}) {
    _finished = pasted;
    final account = values;
    if (chosen != null && !chosen!.same(account)) {
      chosen = null;
    }
    if (!_same(_checkedFor, account)) {
      _resetCheck();
      _lookUpSoon(now: pasted);
    }
    notifyListeners();
  }

  void _lookUpSoon({bool now = false}) {
    _settle?.cancel();
    if (!target.checkable || !complete || !signedIn()) {
      return;
    }
    _settle = Timer(now ? Duration.zero : settleFor, lookUp);
  }

  void _resetCheck() {
    _settle?.cancel();
    _asking = null;
    _checkedFor = null;
    check = null;
    checkState = CheckState.idle;
  }

  static bool _same(Map<String, String>? a, Map<String, String> b) =>
      a != null &&
      a.length == b.length &&
      a.entries.every((e) => b[e.key] == e.value);

  @override
  void dispose() {
    _disposed = true;
    _settle?.cancel();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final node in _focus.values) {
      node.dispose();
    }
    super.dispose();
  }
}
