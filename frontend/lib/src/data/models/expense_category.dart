/// A shop-managed bucket for expenses (rent, utilities, maintenance, ...).
class ExpenseCategory {
  const ExpenseCategory({
    required this.id,
    required this.name,
    required this.isActive,
    required this.displayOrder,
  });

  final int id;
  final String name;
  final bool isActive;
  final int displayOrder;

  factory ExpenseCategory.fromJson(Map<String, Object?> json) {
    return ExpenseCategory(
      id: json['id'] as int,
      name: json['name']?.toString() ?? '',
      isActive: json['is_active'] == true,
      displayOrder: (json['display_order'] as num?)?.toInt() ?? 0,
    );
  }
}

class ExpenseCategoryPage {
  const ExpenseCategoryPage({required this.categories, required this.hasMore});

  final List<ExpenseCategory> categories;
  final bool hasMore;

  factory ExpenseCategoryPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(ExpenseCategory.fromJson)
        .toList(growable: false);

    return ExpenseCategoryPage(
      categories: results,
      hasMore: json['next'] != null,
    );
  }
}

class ExpenseCategoryDraft {
  const ExpenseCategoryDraft({
    required this.name,
    this.isActive = true,
    this.displayOrder = 0,
  });

  final String name;
  final bool isActive;
  final int displayOrder;

  Map<String, Object?> toJson() {
    return {'name': name, 'is_active': isActive, 'display_order': displayOrder};
  }
}
