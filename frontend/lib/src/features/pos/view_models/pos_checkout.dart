part of 'pos_view_model.dart';

extension PosCheckoutActions on PosViewModel {
  Future<SaleCheckoutOutcome> checkoutCurrentSale() async {
    if (_isCheckingOut) {
      return const SaleCheckoutOutcome.failure();
    }
    if (_activeRegisterSession == null || _cart.isEmpty) {
      return const SaleCheckoutOutcome.failure();
    }

    _isCheckingOut = true;
    _notifyChanged();

    final cartSnapshot = List<CartLine>.of(_cart);
    final result = await _saleRepository.checkout(
      SaleCheckoutDraft.fromCart(
        cart: cartSnapshot,
        amountReceived: cartSnapshot.fold(0, (sum, line) => sum + line.total),
      ),
    );

    switch (result) {
      case Ok<SaleOrder>():
        _cart.clear();
        _isCheckingOut = false;
        _notifyChanged();
        return SaleCheckoutOutcome.success(result.value);
      case Error<SaleOrder>():
        _isCheckingOut = false;
        _notifyChanged();
        return const SaleCheckoutOutcome.failure();
    }
  }
}

class SaleCheckoutOutcome {
  const SaleCheckoutOutcome._({required this.isSuccess, this.order});

  const SaleCheckoutOutcome.success(SaleOrder order)
    : this._(isSuccess: true, order: order);

  const SaleCheckoutOutcome.failure() : this._(isSuccess: false);

  final bool isSuccess;
  final SaleOrder? order;
}
