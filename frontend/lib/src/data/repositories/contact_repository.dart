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
    return Result.guard(
      () => _service.fetchCustomers(query: query, page: page),
    );
  }

  Future<Result<SupplierPage>> loadSuppliers({
    required ContactQuery query,
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchSuppliers(query: query, page: page),
    );
  }

  Future<Result<SupplierContact>> loadSupplier(int supplierId) async {
    return Result.guard(() => _service.fetchSupplier(supplierId));
  }

  Future<Result<Customer>> createCustomer(CustomerDraft draft) async {
    return Result.guard(() => _service.createCustomer(draft));
  }

  Future<Result<SupplierContact>> createSupplier(SupplierDraft draft) async {
    return Result.guard(() => _service.createSupplier(draft));
  }
}
