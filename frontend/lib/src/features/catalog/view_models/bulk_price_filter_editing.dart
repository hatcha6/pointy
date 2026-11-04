import '../../../data/models/bulk_price_rule.dart';

/// What the condition editor needs from whoever owns the filter tree it edits:
/// the bulk price editor, or any other screen that picks products by the same
/// rule language (the bulk tracking page). Keeps the editor from depending on
/// price steps and previews.
abstract interface class BulkPriceFilterEditing {
  void addCondition(String groupKey);
  void addGroup(String groupKey);
  void setGroupMatch(String groupKey, BulkPriceMatch match);
  void updateCondition(
    String key,
    BulkPriceCondition Function(BulkPriceCondition condition) update,
  );
  void removeNode(String key);
}
