import '../../data/models/esim.dart';
import '../../data/models/order.dart';

/// «كروتي» as it last stood, so the page opens on it at once on the next
/// visit (its cards, which of them are used, the eSIMs) and reads again
/// underneath. Kept in memory only, and forgotten with the session.
class MyCardsMemory {
  MyCardsSnapshot? last;

  void forget() => last = null;
}

class MyCardsSnapshot {
  const MyCardsSnapshot({
    required this.orders,
    required this.esims,
    required this.used,
    required this.saved,
  });

  /// As the relay listed them, before the page's own filtering.
  final List<CardOrder> orders;
  final List<CustomerEsim> esims;
  final Set<String> used;
  final Map<String, List<CardCode>> saved;
}
