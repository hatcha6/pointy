import 'package:http/http.dart' as http;

import 'pos_http_client_stub.dart'
    if (dart.library.html) 'pos_http_client_web.dart';

http.Client createPosHttpClient() => createPlatformHttpClient();
