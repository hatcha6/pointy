import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/cart_line.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_page.dart';
import '../../../data/models/product_query.dart';
import '../../../data/models/register_session.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/register_session_repository.dart';
import '../../../data/repositories/sale_repository.dart';

part 'pos_cart_actions.dart';
part 'pos_catalog_actions.dart';
part 'pos_checkout.dart';
part 'pos_register_session_actions.dart';

enum RegisterSessionGateStatus {
  loading,
  noOpenSession,
  openSessionAvailable,
  active,
}

class PosViewModel extends ChangeNotifier {
  PosViewModel(
    this._catalogRepository,
    this._registerSessionRepository,
    this._saleRepository,
  ) {
    loadCurrentRegisterSession();
  }

  final CatalogRepository _catalogRepository;
  final RegisterSessionRepository _registerSessionRepository;
  final SaleRepository _saleRepository;

  List<Product> _products = [];
  final List<CartLine> _cart = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isLoadingRegisterSession = false;
  bool _isStartingRegisterSession = false;
  bool _isClosingRegisterSession = false;
  bool _isCheckingOut = false;
  bool _hasMoreProducts = true;
  int _nextProductPage = 1;
  String? _errorMessage;
  bool _hasRegisterSessionError = false;
  RegisterSession? _availableRegisterSession;
  RegisterSession? _activeRegisterSession;
  ProductQuery _query = const ProductQuery(
    availability: ProductAvailabilityFilter.active,
  );

  List<Product> get products => List.unmodifiable(_products);
  List<CartLine> get cart => List.unmodifiable(_cart);
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get isLoadingRegisterSession => _isLoadingRegisterSession;
  bool get isStartingRegisterSession => _isStartingRegisterSession;
  bool get isClosingRegisterSession => _isClosingRegisterSession;
  bool get isCheckingOut => _isCheckingOut;
  bool get hasMoreProducts => _hasMoreProducts;
  String? get errorMessage => _errorMessage;
  bool get hasRegisterSessionError => _hasRegisterSessionError;
  RegisterSession? get availableRegisterSession => _availableRegisterSession;
  RegisterSession? get activeRegisterSession => _activeRegisterSession;
  ProductQuery get query => _query;

  double get subtotal => _cart.fold(0, (sum, line) => sum + line.subtotal);
  double get total => subtotal;
  RegisterSessionGateStatus get registerSessionGateStatus {
    if (_activeRegisterSession != null) {
      return RegisterSessionGateStatus.active;
    }
    if (_isLoadingRegisterSession) {
      return RegisterSessionGateStatus.loading;
    }
    if (_availableRegisterSession != null) {
      return RegisterSessionGateStatus.openSessionAvailable;
    }
    return RegisterSessionGateStatus.noOpenSession;
  }

  void _notifyChanged() {
    notifyListeners();
  }
}
