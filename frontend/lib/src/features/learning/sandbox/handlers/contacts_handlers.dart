import '../sandbox_payloads.dart';
import '../sandbox_request.dart';
import '../sandbox_shop.dart';

/// Customers and suppliers, and the money that moves between them and the shop.
SandboxReply handleContacts(SandboxShop shop, SandboxRequest request) {
  if (request.on('GET', 'customers/') != null) {
    final search = request.query('search');
    return (
      200,
      page([
        for (final contact in shop.customers)
          if (search.isEmpty ||
              contact.name.contains(search) ||
              contact.phone.contains(search))
            customerJson(contact),
      ]),
    );
  }
  if (request.on('POST', 'customers/') != null) {
    final contact = shop.createContact(
      name: request.text('full_name'),
      isSupplier: false,
      phone: request.text('phone'),
    );
    return (201, customerJson(contact));
  }

  final customer = request.on('GET', 'customers/{id}/');
  if (customer != null) {
    final contact = shop.contactById(int.tryParse(customer.first) ?? 0);
    return contact == null
        ? (404, {'detail': 'not found'})
        : (200, customerJson(contact));
  }

  final patch = request.on('PATCH', 'customers/{id}/');
  if (patch != null) {
    final contact = shop.contactById(int.tryParse(patch.first) ?? 0);
    if (contact == null) {
      return (404, {'detail': 'not found'});
    }
    if (request.body.containsKey('full_name')) {
      contact.name = request.text('full_name');
    }
    if (request.body.containsKey('phone')) {
      contact.phone = request.text('phone');
    }
    shop.stateVersion++;
    return (200, customerJson(contact));
  }

  final summary = request.on('GET', 'customers/{id}/sales-summary/');
  if (summary != null) {
    final contact = shop.contactById(int.tryParse(summary.first) ?? 0);
    return contact == null
        ? (404, {'detail': 'not found'})
        : (200, customerSalesSummaryJson(contact));
  }

  final orders = request.on('GET', 'customers/{id}/orders/');
  if (orders != null) {
    final id = int.tryParse(orders.first) ?? 0;
    return (
      200,
      page([
        for (final order in shop.orders.reversed)
          if (order.customerId == id) orderJson(order),
      ]),
    );
  }

  final pay = request.on('POST', 'customers/{id}/record-payment/');
  if (pay != null) {
    final id = int.tryParse(pay.first) ?? 0;
    final amount = request.field('amount');
    final balance = shop.recordCustomerPayment(
      customerId: id,
      amount: amount,
      method: request.body['method']?.toString() ?? 'cash',
    );
    final contact = shop.contactById(id);
    if (contact == null) {
      return (404, {'detail': 'not found'});
    }
    return (
      201,
      {
        'id': nextPracticeId(),
        'customer': id,
        'amount': money(amount),
        'method': request.body['method']?.toString() ?? 'cash',
        'outstanding_balance': money(balance),
        'created_at': stamp(DateTime.now()),
      },
    );
  }

  if (request.on('GET', 'suppliers/') != null) {
    final search = request.query('search');
    return (
      200,
      page([
        for (final contact in shop.suppliers)
          if (search.isEmpty || contact.name.contains(search))
            supplierJson(contact),
      ]),
    );
  }
  if (request.on('POST', 'suppliers/') != null) {
    final contact = shop.createContact(
      name: request.text('name'),
      isSupplier: true,
      phone: request.text('phone'),
    );
    return (201, supplierJson(contact));
  }

  final supplier = request.on('GET', 'suppliers/{id}/');
  if (supplier != null) {
    final contact = shop.contactById(int.tryParse(supplier.first) ?? 0);
    return contact == null
        ? (404, {'detail': 'not found'})
        : (200, supplierJson(contact));
  }

  if (request.on('GET', 'suppliers/{id}/purchase-history/') != null) {
    return (200, page(const []));
  }

  if (request.on('GET', 'payments/') != null) {
    return (200, page(const []));
  }

  if (request.on('GET', 'supplier-payments/') != null) {
    return (200, page(const []));
  }
  if (request.on('POST', 'supplier-payments/') != null) {
    final supplierId = request.id('supplier') ?? 0;
    final amount = request.field('amount');
    shop.recordSupplierPayment(
      supplierId: supplierId,
      amount: amount,
      purchaseOrderId: request.id('purchase_order'),
      method: request.body['method']?.toString() ?? 'cash',
    );
    return (
      201,
      {
        'id': nextPracticeId(),
        'supplier': supplierId,
        'amount': money(amount),
        'method': request.body['method']?.toString() ?? 'cash',
        'created_at': stamp(DateTime.now()),
      },
    );
  }
  return null;
}
