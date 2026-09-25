import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../data/models/purchase_submission.dart';
import '../data/models/sale_order.dart';

String paymentMethodLabel(AppLocalizations l10n, PaymentMethod method) {
  return switch (method) {
    PaymentMethod.cash => l10n.paymentMethodCash,
    PaymentMethod.card => l10n.paymentMethodCard,
    PaymentMethod.transfer => l10n.paymentMethodTransfer,
    PaymentMethod.salaryDeduction => l10n.paymentMethodSalaryDeduction,
  };
}

IconData paymentMethodIcon(PaymentMethod method) {
  return switch (method) {
    PaymentMethod.cash => Icons.payments_outlined,
    PaymentMethod.card => Icons.credit_card_outlined,
    PaymentMethod.transfer => Icons.account_balance_outlined,
    PaymentMethod.salaryDeduction => Icons.badge_outlined,
  };
}

String supplierPaymentMethodLabel(
  AppLocalizations l10n,
  SupplierPaymentMethod method,
) {
  return switch (method) {
    SupplierPaymentMethod.cash => l10n.paymentMethodCash,
    SupplierPaymentMethod.card => l10n.paymentMethodCard,
    SupplierPaymentMethod.transfer => l10n.paymentMethodTransfer,
    SupplierPaymentMethod.supplierCredit => l10n.supplierPaymentMethodCredit,
    SupplierPaymentMethod.refund => l10n.purchaseAdjustmentTypeRefund,
  };
}

IconData supplierPaymentMethodIcon(SupplierPaymentMethod method) {
  return switch (method) {
    SupplierPaymentMethod.cash => Icons.payments_outlined,
    SupplierPaymentMethod.card => Icons.credit_card_outlined,
    SupplierPaymentMethod.transfer => Icons.account_balance_outlined,
    SupplierPaymentMethod.supplierCredit => Icons.savings_outlined,
    SupplierPaymentMethod.refund => Icons.keyboard_return_outlined,
  };
}
