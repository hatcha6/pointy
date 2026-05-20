import '../../core/result.dart';
import '../models/contact.dart';
import '../services/pos_api_service.dart';

class ContactRepository {
  const ContactRepository(this._service);

  final PosApiService _service;

  Future<Result<CustomerPage>> loadCustomers({
    required ContactQuery query,
    int page = 1,
  }) async {
    try {
      return Ok(await _service.fetchCustomers(query: query, page: page));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<SupplierPage>> loadSuppliers({
    required ContactQuery query,
    int page = 1,
  }) async {
    try {
      return Ok(await _service.fetchSuppliers(query: query, page: page));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<SupplierContact>> loadSupplier(int supplierId) async {
    try {
      return Ok(await _service.fetchSupplier(supplierId));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<Customer>> createCustomer(CustomerDraft draft) async {
    try {
      return Ok(await _service.createCustomer(draft));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<SupplierContact>> createSupplier(SupplierDraft draft) async {
    try {
      return Ok(await _service.createSupplier(draft));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }
}
