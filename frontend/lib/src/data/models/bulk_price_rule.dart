/// The rule language of the bulk price editor — mirrors the backend's
/// `apps.catalog.bulk_pricing` spec: a filter tree of conditions and groups,
/// an ordered chain of price steps (each with an optional condition of its
/// own), and the safeguards that always run last.
///
/// Every node is immutable and carries a stable [key] so the editor can
/// replace one condition deep inside the tree without rebuilding the rest,
/// and so text fields keep their focus while the tree changes around them.
library;

enum BulkPriceFieldKind { text, number, refs, flag }

enum BulkPriceField {
  name('name', BulkPriceFieldKind.text),
  sku('sku', BulkPriceFieldKind.text),
  barcode('barcode', BulkPriceFieldKind.text),
  category('category', BulkPriceFieldKind.refs),
  supplier('supplier', BulkPriceFieldKind.refs),
  product('product', BulkPriceFieldKind.refs),
  price('price', BulkPriceFieldKind.number),
  cost('cost', BulkPriceFieldKind.number, needsCost: true),
  markup('markup', BulkPriceFieldKind.number, needsCost: true),
  stock('stock', BulkPriceFieldKind.number),
  isActive('is_active', BulkPriceFieldKind.flag),
  isService('is_service', BulkPriceFieldKind.flag),
  foreignPriced('foreign_priced', BulkPriceFieldKind.flag);

  const BulkPriceField(this.apiValue, this.kind, {this.needsCost = false});

  final String apiValue;
  final BulkPriceFieldKind kind;
  final bool needsCost;

  /// Stock is the only number that may be negative (oversold), and markup
  /// (sold at a loss); everything else is a price.
  bool get allowsNegative => this == stock || this == markup;

  int get maxDecimals => this == stock ? 3 : 2;

  /// Fields offered in the field menu. [product] only arrives prefilled from
  /// a multi-selection on the products list — there is nothing to type.
  bool get isPickable => this != product;

  List<BulkPriceOperator> get operators => switch (kind) {
    BulkPriceFieldKind.text => const [
      BulkPriceOperator.contains,
      BulkPriceOperator.notContains,
      BulkPriceOperator.equals,
      BulkPriceOperator.notEquals,
      BulkPriceOperator.startsWith,
      BulkPriceOperator.endsWith,
      BulkPriceOperator.isEmpty,
      BulkPriceOperator.isNotEmpty,
    ],
    BulkPriceFieldKind.number => const [
      BulkPriceOperator.lt,
      BulkPriceOperator.lte,
      BulkPriceOperator.gt,
      BulkPriceOperator.gte,
      BulkPriceOperator.eq,
      BulkPriceOperator.neq,
      BulkPriceOperator.between,
      BulkPriceOperator.isEmpty,
      BulkPriceOperator.isNotEmpty,
    ],
    BulkPriceFieldKind.refs => const [
      BulkPriceOperator.inList,
      BulkPriceOperator.notInList,
      BulkPriceOperator.isEmpty,
      BulkPriceOperator.isNotEmpty,
    ],
    BulkPriceFieldKind.flag => const [
      BulkPriceOperator.isTrue,
      BulkPriceOperator.isFalse,
    ],
  };

  /// Price and stock always have a value; offering "is empty" for them would
  /// be a choice that can only ever match nothing.
  bool supports(BulkPriceOperator operator) {
    if (!operators.contains(operator)) return false;
    final emptiness =
        operator == BulkPriceOperator.isEmpty ||
        operator == BulkPriceOperator.isNotEmpty;
    if (emptiness && (this == price || this == stock || this == product)) {
      return false;
    }
    return true;
  }

  List<BulkPriceOperator> get supportedOperators =>
      operators.where(supports).toList(growable: false);
}

enum BulkPriceOperator {
  contains('contains'),
  notContains('not_contains'),
  equals('equals'),
  notEquals('not_equals'),
  startsWith('starts_with'),
  endsWith('ends_with'),
  isEmpty('is_empty', needsValue: false),
  isNotEmpty('is_not_empty', needsValue: false),
  eq('eq'),
  neq('neq'),
  gt('gt'),
  gte('gte'),
  lt('lt'),
  lte('lte'),
  between('between'),
  inList('in'),
  notInList('not_in'),
  isTrue('is_true', needsValue: false),
  isFalse('is_false', needsValue: false);

  const BulkPriceOperator(this.apiValue, {this.needsValue = true});

  final String apiValue;
  final bool needsValue;
}

enum BulkPriceMatch {
  all('all'),
  any('any');

  const BulkPriceMatch(this.apiValue);
  final String apiValue;
}

/// What a step's number means, which decides its suffix and its bounds.
enum BulkPriceValueKind { percent, amount }

enum BulkPriceAction {
  increasePercent('increase_percent', BulkPriceValueKind.percent),
  decreasePercent('decrease_percent', BulkPriceValueKind.percent),
  increaseAmount('increase_amount', BulkPriceValueKind.amount),
  decreaseAmount('decrease_amount', BulkPriceValueKind.amount),
  set('set', BulkPriceValueKind.amount),
  costMarkup('cost_markup', BulkPriceValueKind.percent, needsCost: true),
  costPlus('cost_plus', BulkPriceValueKind.amount, needsCost: true),
  minMarkup('min_markup', BulkPriceValueKind.percent, needsCost: true),
  minPrice('min_price', BulkPriceValueKind.amount),
  maxPrice('max_price', BulkPriceValueKind.amount),
  round('round', BulkPriceValueKind.amount, hasDirection: true),
  ending('ending', BulkPriceValueKind.amount, hasDirection: true);

  const BulkPriceAction(
    this.apiValue,
    this.valueKind, {
    this.needsCost = false,
    this.hasDirection = false,
  });

  final String apiValue;
  final BulkPriceValueKind valueKind;
  final bool needsCost;
  final bool hasDirection;
}

enum BulkPriceDirection {
  nearest('nearest'),
  up('up'),
  down('down');

  const BulkPriceDirection(this.apiValue);
  final String apiValue;
}

enum BulkPricePackMode {
  scale('scale'),
  keep('keep');

  const BulkPricePackMode(this.apiValue);
  final String apiValue;
}

/// Why a node cannot be sent yet. The editor shows these next to the field.
enum BulkPriceIssue {
  required,
  notANumber,
  negative,
  tooManyDecimals,
  boundsReversed,
  percentOver100,
  zeroIncrement,
}

/// A picked category / supplier / product, with the name to show for it.
class BulkPriceRef {
  const BulkPriceRef({required this.id, required this.label});

  final int id;
  final String label;

  @override
  bool operator ==(Object other) => other is BulkPriceRef && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

sealed class BulkPriceNode {
  const BulkPriceNode(this.key);

  final String key;

  Map<String, Object?> toJson();
}

class BulkPriceCondition extends BulkPriceNode {
  const BulkPriceCondition({
    required String key,
    required this.field,
    required this.operator,
    this.value = '',
    this.valueTo = '',
    this.refs = const [],
  }) : super(key);

  final BulkPriceField field;
  final BulkPriceOperator operator;
  final String value;
  final String valueTo;
  final List<BulkPriceRef> refs;

  BulkPriceCondition copyWith({
    BulkPriceField? field,
    BulkPriceOperator? operator,
    String? value,
    String? valueTo,
    List<BulkPriceRef>? refs,
  }) {
    final nextField = field ?? this.field;
    final changedKind = nextField.kind != this.field.kind;
    var nextOperator = operator ?? this.operator;
    if (!nextField.supports(nextOperator)) {
      nextOperator = nextField.supportedOperators.first;
    }
    return BulkPriceCondition(
      key: key,
      field: nextField,
      operator: nextOperator,
      // A typed "cola" means nothing as a price; a picked category nothing
      // as a supplier. Values only survive a field change of the same kind.
      value: changedKind ? '' : (value ?? this.value),
      valueTo: changedKind ? '' : (valueTo ?? this.valueTo),
      refs: (changedKind || nextField != this.field)
          ? (refs ?? const [])
          : (refs ?? this.refs),
    );
  }

  /// The first problem with [value] and the one with [valueTo], if any.
  ({BulkPriceIssue? value, BulkPriceIssue? valueTo}) get issues {
    if (!operator.needsValue) return (value: null, valueTo: null);
    switch (field.kind) {
      case BulkPriceFieldKind.text:
        return (
          value: value.trim().isEmpty ? BulkPriceIssue.required : null,
          valueTo: null,
        );
      case BulkPriceFieldKind.refs:
        return (
          value: refs.isEmpty ? BulkPriceIssue.required : null,
          valueTo: null,
        );
      case BulkPriceFieldKind.flag:
        return (value: null, valueTo: null);
      case BulkPriceFieldKind.number:
        final first = numberIssue(
          value,
          allowNegative: field.allowsNegative,
          maxDecimals: field.maxDecimals,
        );
        if (operator != BulkPriceOperator.between) {
          return (value: first, valueTo: null);
        }
        var second = numberIssue(
          valueTo,
          allowNegative: field.allowsNegative,
          maxDecimals: field.maxDecimals,
        );
        if (first == null && second == null) {
          final low = double.parse(normalizeDigits(value));
          final high = double.parse(normalizeDigits(valueTo));
          if (high < low) second = BulkPriceIssue.boundsReversed;
        }
        return (value: first, valueTo: second);
    }
  }

  bool get isValid {
    final found = issues;
    return found.value == null && found.valueTo == null;
  }

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'field': field.apiValue,
      'op': operator.apiValue,
    };
    if (!operator.needsValue) return json;
    switch (field.kind) {
      case BulkPriceFieldKind.refs:
        json['value'] = [for (final ref in refs) ref.id];
      case BulkPriceFieldKind.number:
        json['value'] = normalizeDigits(value);
        if (operator == BulkPriceOperator.between) {
          json['value_to'] = normalizeDigits(valueTo);
        }
      case BulkPriceFieldKind.text:
        json['value'] = value.trim();
      case BulkPriceFieldKind.flag:
        break;
    }
    return json;
  }
}

class BulkPriceGroup extends BulkPriceNode {
  const BulkPriceGroup({
    required String key,
    this.match = BulkPriceMatch.all,
    this.children = const [],
  }) : super(key);

  final BulkPriceMatch match;
  final List<BulkPriceNode> children;

  bool get isEmpty => children.isEmpty;

  BulkPriceGroup copyWith({
    BulkPriceMatch? match,
    List<BulkPriceNode>? children,
  }) => BulkPriceGroup(
    key: key,
    match: match ?? this.match,
    children: children ?? this.children,
  );

  Iterable<BulkPriceCondition> get conditions sync* {
    for (final child in children) {
      switch (child) {
        case BulkPriceCondition():
          yield child;
        case BulkPriceGroup():
          yield* child.conditions;
      }
    }
  }

  int get invalidCount => conditions.where((c) => !c.isValid).length;

  /// Replaces the node with [key] anywhere in this tree. Returning null from
  /// [update] removes it.
  BulkPriceGroup updateNode(
    String key,
    BulkPriceNode? Function(BulkPriceNode node) update,
  ) {
    var touched = false;
    final next = <BulkPriceNode>[];
    for (final child in children) {
      if (child.key == key) {
        touched = true;
        final replaced = update(child);
        if (replaced != null) next.add(replaced);
        continue;
      }
      if (child is BulkPriceGroup) {
        final updated = child.updateNode(key, update);
        if (!identical(updated, child)) touched = true;
        next.add(updated);
        continue;
      }
      next.add(child);
    }
    if (key == this.key) {
      final replaced = update(this);
      return replaced is BulkPriceGroup ? replaced : this;
    }
    return touched ? copyWith(children: next) : this;
  }

  @override
  Map<String, Object?> toJson() => {
    'match': match.apiValue,
    'conditions': [for (final child in children) child.toJson()],
  };
}

class BulkPriceStep {
  const BulkPriceStep({
    required this.key,
    required this.action,
    this.value = '',
    this.direction = BulkPriceDirection.nearest,
    this.when,
    this.stop = false,
  });

  final String key;
  final BulkPriceAction action;
  final String value;
  final BulkPriceDirection direction;

  /// Null = applies to every product the filter let in.
  final BulkPriceGroup? when;
  final bool stop;

  BulkPriceStep copyWith({
    BulkPriceAction? action,
    String? value,
    BulkPriceDirection? direction,
    BulkPriceGroup? Function()? when,
    bool? stop,
  }) => BulkPriceStep(
    key: key,
    action: action ?? this.action,
    value: value ?? this.value,
    direction: direction ?? this.direction,
    when: when == null ? this.when : when(),
    stop: stop ?? this.stop,
  );

  BulkPriceIssue? get valueIssue {
    final issue = numberIssue(value, allowNegative: false, maxDecimals: 2);
    if (issue != null) return issue;
    final number = double.parse(normalizeDigits(value));
    if (action == BulkPriceAction.decreasePercent && number > 100) {
      return BulkPriceIssue.percentOver100;
    }
    if (action == BulkPriceAction.round && number <= 0) {
      return BulkPriceIssue.zeroIncrement;
    }
    return null;
  }

  int get invalidCount =>
      (valueIssue == null ? 0 : 1) + (when?.invalidCount ?? 0);

  Map<String, Object?> toJson() => {
    'action': action.apiValue,
    'value': normalizeDigits(value),
    if (action.hasDirection) 'direction': direction.apiValue,
    if (when != null && !when!.isEmpty) 'when': when!.toJson(),
    'stop': stop,
  };
}

class BulkPriceSpec {
  const BulkPriceSpec({
    required this.filter,
    required this.steps,
    this.neverBelowCost = false,
    this.packMode = BulkPricePackMode.scale,
  });

  final BulkPriceGroup filter;
  final List<BulkPriceStep> steps;
  final bool neverBelowCost;
  final BulkPricePackMode packMode;

  BulkPriceSpec copyWith({
    BulkPriceGroup? filter,
    List<BulkPriceStep>? steps,
    bool? neverBelowCost,
    BulkPricePackMode? packMode,
  }) => BulkPriceSpec(
    filter: filter ?? this.filter,
    steps: steps ?? this.steps,
    neverBelowCost: neverBelowCost ?? this.neverBelowCost,
    packMode: packMode ?? this.packMode,
  );

  int get invalidCount =>
      filter.invalidCount +
      steps.fold(0, (sum, step) => sum + step.invalidCount);

  bool get isComplete => steps.isNotEmpty && invalidCount == 0;

  Map<String, Object?> toJson() => {
    'filter': filter.toJson(),
    'steps': [for (final step in steps) step.toJson()],
    'finish': {'never_below_cost': neverBelowCost, 'packs': packMode.apiValue},
  };
}

/// Arabic-Indic and Eastern Arabic digits, and the Arabic decimal separator,
/// as ASCII — a cashier's keyboard may type either.
String normalizeDigits(String raw) {
  final buffer = StringBuffer();
  for (final rune in raw.trim().runes) {
    if (rune >= 0x0660 && rune <= 0x0669) {
      buffer.writeCharCode(0x30 + rune - 0x0660);
    } else if (rune >= 0x06F0 && rune <= 0x06F9) {
      buffer.writeCharCode(0x30 + rune - 0x06F0);
    } else if (rune == 0x066B || rune == 0x060C) {
      buffer.write('.');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

final _numberPattern = RegExp(r'^-?\d+(\.\d+)?$');

BulkPriceIssue? numberIssue(
  String raw, {
  required bool allowNegative,
  required int maxDecimals,
}) {
  final text = normalizeDigits(raw);
  if (text.isEmpty) return BulkPriceIssue.required;
  if (!_numberPattern.hasMatch(text)) return BulkPriceIssue.notANumber;
  if (!allowNegative && text.startsWith('-')) return BulkPriceIssue.negative;
  final dot = text.indexOf('.');
  if (dot >= 0 && text.length - dot - 1 > maxDecimals) {
    return BulkPriceIssue.tooManyDecimals;
  }
  return null;
}
