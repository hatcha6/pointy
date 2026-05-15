import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/product.dart';
import '../models/product_page.dart';
import '../models/query.dart';

class PosApiService {
  PosApiService({
    http.Client? client,
    this.baseUrl = 'http://127.0.0.1:8000/api',
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;

  Future<ProductPage> fetchProducts({
    required ModelQuery query,
    int page = 1,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/products/',
    ).replace(queryParameters: query.toQueryParameters(page: page));
    final response = await _client.get(uri);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Product request failed with status ${response.statusCode}',
      );
    }

    return ProductPage.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
    );
  }

  Future<Product> createProduct(ProductDraft draft) async {
    final uri = Uri.parse('$baseUrl/products/');
    final response = await _client.post(
      uri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(draft.toJson()),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Product create failed with status ${response.statusCode}',
      );
    }

    return Product.fromJson(jsonDecode(response.body) as Map<String, Object?>);
  }
}
