import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/product.dart';
import '../models/product_page.dart';
import '../models/pos_user.dart';
import '../models/query.dart';
import '../models/register_session.dart';
import '../models/register_session_page.dart';
import '../models/sale_order.dart';
import 'pos_http_client.dart';

class PosApiService {
  PosApiService({
    http.Client? client,
    this.baseUrl = 'http://127.0.0.1:8000/api',
  }) : _client = client ?? createPosHttpClient();

  final http.Client _client;
  final String baseUrl;
  final Map<String, String> _cookies = {};
  String? _csrfToken;

  Future<PosUser> login({
    required String username,
    required String password,
  }) async {
    final uri = Uri.parse('$baseUrl/auth/login/');
    final response = await _client.post(
      uri,
      headers: _requestHeaders(),
      body: jsonEncode({'username': username, 'password': password}),
    );
    _captureResponseState(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Login failed with status ${response.statusCode}');
    }

    return _decodeUserResponse(_decodeBody(response));
  }

  Future<void> logout() async {
    final uri = Uri.parse('$baseUrl/auth/logout/');
    final response = await _client.post(
      uri,
      headers: _requestHeaders(includeCsrf: true),
    );
    _captureResponseState(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Logout failed with status ${response.statusCode}');
    }

    _cookies.clear();
    _csrfToken = null;
  }

  Future<PosUser?> fetchCurrentUser() async {
    final uri = Uri.parse('$baseUrl/auth/me/');
    final response = await _client.get(uri, headers: _requestHeaders());
    _captureResponseState(response);

    if (response.statusCode == 401 || response.statusCode == 403) {
      return null;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Current user request failed with status ${response.statusCode}',
      );
    }

    return _decodeUserResponse(_decodeBody(response));
  }

  Future<List<PosUser>> fetchUsers() async {
    final uri = Uri.parse('$baseUrl/users/');
    final response = await _client.get(uri, headers: _requestHeaders());

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Users request failed with status ${response.statusCode}',
      );
    }

    return _decodeListResponse(_decodeBody(response), PosUser.fromJson);
  }

  Future<PosUser> createUser(UserCreateDraft draft) async {
    final uri = Uri.parse('$baseUrl/users/');
    final response = await _client.post(
      uri,
      headers: _requestHeaders(includeCsrf: true),
      body: jsonEncode(draft.toJson()),
    );
    _captureResponseState(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('User create failed with status ${response.statusCode}');
    }

    return PosUser.fromJson(
      jsonDecode(_decodeBody(response)) as Map<String, Object?>,
    );
  }

  Future<PosUser> updateUser({
    required int id,
    required UserUpdateDraft draft,
  }) async {
    final uri = Uri.parse('$baseUrl/users/$id/');
    final response = await _client.patch(
      uri,
      headers: _requestHeaders(includeCsrf: true),
      body: jsonEncode(draft.toJson()),
    );
    _captureResponseState(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('User update failed with status ${response.statusCode}');
    }

    return PosUser.fromJson(
      jsonDecode(_decodeBody(response)) as Map<String, Object?>,
    );
  }

  Future<ProductPage> fetchProducts({
    required ModelQuery query,
    int page = 1,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/products/',
    ).replace(queryParameters: query.toQueryParameters(page: page));
    final response = await _client.get(uri, headers: _requestHeaders());

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Product request failed with status ${response.statusCode}',
      );
    }

    return ProductPage.fromJson(
      jsonDecode(_decodeBody(response)) as Map<String, Object?>,
    );
  }

  Future<Product> createProduct(ProductDraft draft) async {
    final uri = Uri.parse('$baseUrl/products/');
    final response = await _client.post(
      uri,
      headers: _requestHeaders(includeCsrf: true),
      body: jsonEncode(draft.toJson()),
    );
    _captureResponseState(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Product create failed with status ${response.statusCode}',
      );
    }

    return Product.fromJson(
      jsonDecode(_decodeBody(response)) as Map<String, Object?>,
    );
  }

  Future<RegisterSession?> fetchCurrentRegisterSession() async {
    final uri = Uri.parse('$baseUrl/register-sessions/current/');
    final response = await _client.get(uri, headers: _requestHeaders());

    if (response.statusCode == 204) {
      return null;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Register session request failed with status ${response.statusCode}',
      );
    }

    return RegisterSession.fromJson(
      jsonDecode(_decodeBody(response)) as Map<String, Object?>,
    );
  }

  Future<RegisterSessionPage> fetchRegisterSessionHistory({
    int page = 1,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/register-sessions/',
    ).replace(queryParameters: {'page': '$page'});
    final response = await _client.get(uri, headers: _requestHeaders());

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Register session history request failed with status ${response.statusCode}',
      );
    }

    return RegisterSessionPage.fromJson(
      jsonDecode(_decodeBody(response)) as Map<String, Object?>,
    );
  }

  Future<List<SaleOrder>> fetchRegisterSessionOrders(int sessionId) async {
    final uri = Uri.parse('$baseUrl/register-sessions/$sessionId/orders/');
    final response = await _client.get(uri, headers: _requestHeaders());

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Register session orders request failed with status ${response.statusCode}',
      );
    }

    return _decodeListResponse(_decodeBody(response), SaleOrder.fromJson);
  }

  Future<RegisterSession> startRegisterSession({
    required double openingCash,
  }) async {
    final uri = Uri.parse('$baseUrl/register-sessions/start/');
    final response = await _client.post(
      uri,
      headers: _requestHeaders(includeCsrf: true),
      body: jsonEncode({'opening_cash': openingCash.toStringAsFixed(2)}),
    );
    _captureResponseState(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Register session start failed with status ${response.statusCode}',
      );
    }

    return RegisterSession.fromJson(
      jsonDecode(_decodeBody(response)) as Map<String, Object?>,
    );
  }

  Future<RegisterSession> closeRegisterSession({
    required int sessionId,
    required RegisterSessionCloseDraft draft,
  }) async {
    final uri = Uri.parse('$baseUrl/register-sessions/$sessionId/close/');
    final response = await _client.post(
      uri,
      headers: _requestHeaders(includeCsrf: true),
      body: jsonEncode(draft.toJson()),
    );
    _captureResponseState(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Register session close failed with status ${response.statusCode}',
      );
    }

    return RegisterSession.fromJson(
      jsonDecode(_decodeBody(response)) as Map<String, Object?>,
    );
  }

  Future<SaleOrder> checkout(SaleCheckoutDraft draft) async {
    final uri = Uri.parse('$baseUrl/orders/checkout/');
    final response = await _client.post(
      uri,
      headers: _requestHeaders(includeCsrf: true),
      body: jsonEncode(draft.toJson()),
    );
    _captureResponseState(response);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Checkout failed with status ${response.statusCode}');
    }

    return SaleOrder.fromJson(
      jsonDecode(_decodeBody(response)) as Map<String, Object?>,
    );
  }

  PosUser _decodeUserResponse(String body) {
    final decoded = jsonDecode(body) as Map<String, Object?>;
    _csrfToken = decoded['csrf_token']?.toString() ?? _csrfToken;
    final userJson = decoded['user'] is Map<String, Object?>
        ? decoded['user'] as Map<String, Object?>
        : decoded;
    return PosUser.fromJson(userJson);
  }

  Map<String, String> _requestHeaders({bool includeCsrf = false}) {
    return {
      'Content-Type': 'application/json',
      if (_cookies.isNotEmpty)
        'Cookie': _cookies.entries
            .map((entry) => '${entry.key}=${entry.value}')
            .join('; '),
      if (includeCsrf && _csrfToken != null) 'X-CSRFToken': _csrfToken!,
    };
  }

  void _captureResponseState(http.Response response) {
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null || setCookie.isEmpty) {
      return;
    }

    for (final cookie in setCookie.split(',')) {
      final firstPart = cookie.split(';').first.trim();
      final separator = firstPart.indexOf('=');
      if (separator <= 0) {
        continue;
      }
      final name = firstPart.substring(0, separator);
      final value = firstPart.substring(separator + 1);
      _cookies[name] = value;
      if (name == 'csrftoken') {
        _csrfToken = value;
      }
    }
  }

  String _decodeBody(http.Response response) {
    return utf8.decode(response.bodyBytes);
  }

  List<T> _decodeListResponse<T>(
    String body,
    T Function(Map<String, Object?> json) fromJson,
  ) {
    final decoded = jsonDecode(body);
    final items = decoded is Map<String, Object?> && decoded['results'] is List
        ? decoded['results'] as List<Object?>
        : decoded is List<Object?>
        ? decoded
        : const <Object?>[];

    return items
        .whereType<Map<String, Object?>>()
        .map(fromJson)
        .toList(growable: false);
  }
}
