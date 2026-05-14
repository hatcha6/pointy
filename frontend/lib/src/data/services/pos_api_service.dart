import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/product.dart';

class PosApiService {
  PosApiService({
    http.Client? client,
    this.baseUrl = 'http://127.0.0.1:8000/api',
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;

  Future<List<Product>> fetchProducts() async {
    final uri = Uri.parse('$baseUrl/products/?is_active=true&ordering=name');
    final response = await _client.get(uri);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Product request failed with status ${response.statusCode}',
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, Object?>;
    final results = decoded['results'] as List<Object?>;
    return results
        .cast<Map<String, Object?>>()
        .map(Product.fromJson)
        .toList(growable: false);
  }
}
