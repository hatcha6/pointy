import 'dart:convert';

import 'package:http/http.dart' as http;

import 'handlers/boot_handlers.dart';
import 'handlers/catalog_handlers.dart';
import 'handlers/contacts_handlers.dart';
import 'handlers/purchasing_handlers.dart';
import 'handlers/register_handlers.dart';
import 'handlers/selling_handlers.dart';
import 'sandbox_request.dart';
import 'sandbox_shop.dart';

/// An [http.Client] that answers as the shop's backend would.
///
/// This is the seam the plan chose over faking `PosApiService`: every request
/// still goes through the app's real repositories, view models and serializers,
/// so a lesson breaks when the API contract breaks — which is exactly when we
/// want to hear about it.
///
/// **Unimplemented routes return a loud 501**, never an empty list and never a
/// silent success. A blank screen in a tutorial teaches the learner the
/// software is broken.
class SandboxClient extends http.BaseClient {
  SandboxClient(this.shop);

  final SandboxShop shop;

  /// One handler per API area, in the order a request is most likely to match.
  /// Each returns null for "not mine", so adding an area is adding a line.
  late final List<SandboxReply Function(SandboxShop, SandboxRequest)>
  _handlers = [
    handleBoot,
    handleCatalog,
    handleRegister,
    handleSelling,
    handleContacts,
    handlePurchasing,
  ];

  /// Every (method, path) this client was asked for, in order. The lesson
  /// tests assert against it, and it is how an unimplemented route is found.
  final List<String> requestLog = [];

  /// Routes that answered 501, so a lesson run can fail naming them.
  final List<String> unhandled = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = _routeOf(request.url);
    final sandboxRequest = SandboxRequest(
      method: request.method,
      path: path,
      url: request.url,
      rawBody: request is http.Request ? request.body : '',
    );
    requestLog.add('${request.method} $path');

    for (final handler in _handlers) {
      final response = handler(shop, sandboxRequest);
      if (response != null) {
        return _json(request, response.$1, response.$2);
      }
    }

    unhandled.add('${request.method} $path');
    return _json(request, 501, {
      'detail': 'خارج نطاق متجر التدريب: ${request.method} $path',
    });
  }

  /// Strips the `/api` prefix so handlers match the paths the API clients use.
  String _routeOf(Uri url) {
    var path = url.path;
    final marker = path.indexOf('/api/');
    if (marker >= 0) {
      path = path.substring(marker + 5);
    } else if (path.startsWith('/')) {
      path = path.substring(1);
    }
    return path;
  }

  http.StreamedResponse _json(
    http.BaseRequest request,
    int status,
    Object? body,
  ) {
    // 204 carries no body at all; encoding "null" here would make the app's
    // decoder choke on a response it is entitled to ignore.
    final encoded = status == 204 || body == null
        ? const <int>[]
        : utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream.value(encoded),
      status,
      request: request,
      contentLength: encoded.length,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'x-pointy-state': 'catalog=${shop.stateVersion}',
      },
    );
  }
}
