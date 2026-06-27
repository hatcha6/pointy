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
  bool _isLoadingMoreCustomers = false;
  bool _isLoadingMoreSuppliers = false;
  bool _isSaving = false;
  bool _hasError = false;
  bool _hasMoreCustomers = true;
  bool _hasMoreSuppliers = true;
  int _nextCustomerPage = 1;
  int _nextSupplierPage = 1;

  ContactQuery get query => _query;
  List<Customer> get customers => List.unmodifiable(_customers);
  List<SupplierContact> get suppliers => List.unmodifiable(_suppliers);
  bool get isLoading => _isLoading;
  bool get isLoadingMoreCustomers => _isLoadingMoreCustomers;
  bool get isLoadingMoreSuppliers => _isLoadingMoreSuppliers;
  bool get isSaving => _isSaving;
  bool get hasError => _hasError;
  bool get hasMoreCustomers => _hasMoreCustomers;
  bool get hasMoreSuppliers => _hasMoreSuppliers;

  Future<void> loadContacts() async {
    _isLoading = true;
    _hasError = false;
    _hasMoreCustomers = true;
    _hasMoreSuppliers = true;
    _nextCustomerPage = 1;
    _nextSupplierPage = 1;
    notifyListeners();

    final customerResult = await _repository.loadCustomers(
      query: _query,
      page: _nextCustomerPage,
    );
    final supplierResult = await _repository.loadSuppliers(
      query: _query,
      page: _nextSupplierPage,
    );

    switch (customerResult) {
      case Ok<CustomerPage>():
        _customers = customerResult.value.customers;
        _hasMoreCustomers = customerResult.value.hasMore;
        _nextCustomerPage = 2;
      case Error<CustomerPage>():
        _customers = [];
        _hasMoreCustomers = false;
        _hasError = true;
    }
    switch (supplierResult) {
      case Ok<SupplierPage>():
        _suppliers = supplierResult.value.suppliers;
        _hasMoreSuppliers = supplierResult.value.hasMore;
        _nextSupplierPage = 2;
      case Error<SupplierPage>():
        _suppliers = [];
        _hasMoreSuppliers = false;
        _hasError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadMoreCustomers() async {
    if (_isLoading || _isLoadingMoreCustomers || !_hasMoreCustomers) {
      return;
    }

    _isLoadingMoreCustomers = true;
    notifyListeners();

    final result = await _repository.loadCustomers(
      query: _query,
      page: _nextCustomerPage,
    );
    switch (result) {
      case Ok<CustomerPage>():
        _customers = [..._customers, ...result.value.customers];
        _hasMoreCustomers = result.value.hasMore;
        _nextCustomerPage += 1;
      case Error<CustomerPage>():
        _hasMoreCustomers = false;
        _hasError = true;
    }

    _isLoadingMoreCustomers = false;
    notifyListeners();
  }

  Future<void> loadMoreSuppliers() async {
    if (_isLoading || _isLoadingMoreSuppliers || !_hasMoreSuppliers) {
      return;
    }

    _isLoadingMoreSuppliers = true;
    notifyListeners();

    final result = await _repository.loadSuppliers(
      query: _query,
      page: _nextSupplierPage,
    );
    switch (result) {
      case Ok<SupplierPage>():
        _suppliers = [..._suppliers, ...result.value.suppliers];
        _hasMoreSuppliers = result.value.hasMore;
        _nextSupplierPage += 1;
      case Error<SupplierPage>():
        _hasMoreSuppliers = false;
        _hasError = true;
    }

    _isLoadingMoreSuppliers = false;
    notifyListeners();
  }

  Future<void> updateSearch(String search) async {
    if (search == _query.search) {
      return;
    }
    _query = _query.copyWith(search: search);
    await loadContacts();
  }

  Future<void> updateStatus(ContactStatusFilter status) async {
    if (status == _query.status) {
      return;
    }
    _query = _query.copyWith(status: status);
    await loadContacts();
  }

  Future<void> updateRank(CustomerRankFilter rank) async {
    if (rank == _query.rank) {
      return;
    }
    _query = _query.copyWith(rank: rank);
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
