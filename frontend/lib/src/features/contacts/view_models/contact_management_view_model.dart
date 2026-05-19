import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/contact.dart';
import '../../../data/repositories/contact_repository.dart';

class ContactManagementViewModel extends ChangeNotifier {
  ContactManagementViewModel(this._repository) {
    loadContacts();
  }

  final ContactRepository _repository;

  ContactRepository get repository => _repository;
  ContactQuery _query = const ContactQuery();
  List<Customer> _customers = [];
  List<SupplierContact> _suppliers = [];
  bool _isLoading = false;
  bool _isSaving = false;
  bool _hasError = false;

  ContactQuery get query => _query;
  List<Customer> get customers => List.unmodifiable(_customers);
  List<SupplierContact> get suppliers => List.unmodifiable(_suppliers);
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  bool get hasError => _hasError;

  Future<void> loadContacts() async {
    _isLoading = true;
    _hasError = false;
    notifyListeners();

    final customerResult = await _repository.loadCustomers(query: _query);
    final supplierResult = await _repository.loadSuppliers(query: _query);

    switch (customerResult) {
      case Ok<CustomerPage>():
        _customers = customerResult.value.customers;
      case Error<CustomerPage>():
        _customers = [];
        _hasError = true;
    }
    switch (supplierResult) {
      case Ok<SupplierPage>():
        _suppliers = supplierResult.value.suppliers;
      case Error<SupplierPage>():
        _suppliers = [];
        _hasError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> updateSearch(String search) async {
    if (search == _query.search) {
      return;
    }
    _query = _query.copyWith(search: search);
    await loadContacts();
  }

  Future<bool> createCustomer(CustomerDraft draft) async {
    if (_isSaving) {
      return false;
    }
    _isSaving = true;
    notifyListeners();

    final result = await _repository.createCustomer(draft);
    final created = result is Ok<Customer>;
    if (created) {
      await loadContacts();
    }

    _isSaving = false;
    notifyListeners();
    return created;
  }

  Future<bool> createSupplier(SupplierDraft draft) async {
    if (_isSaving) {
      return false;
    }
    _isSaving = true;
    notifyListeners();

    final result = await _repository.createSupplier(draft);
    final created = result is Ok<SupplierContact>;
    if (created) {
      await loadContacts();
    }

    _isSaving = false;
    notifyListeners();
    return created;
  }
}
