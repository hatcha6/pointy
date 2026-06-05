import 'dart:typed_data';

import 'order_document_action.dart';

class OrderDocumentWebDelivery {
  const OrderDocumentWebDelivery();

  String get deliveryChannel => 'file_save_dialog';

  Future<OrderDocumentActionStatus> deliverPdf({
    required Uint8List bytes,
    required String filename,
    String? subject,
  }) async {
    return OrderDocumentActionStatus.failed;
  }
}
