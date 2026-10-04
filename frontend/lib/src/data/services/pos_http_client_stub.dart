import 'package:http/http.dart' as http;

/// A platform with neither `dart:io` nor `dart:html` (a wasm web build):
/// `package:http` picks the client itself.
http.Client createPlatformHttpClient() => http.Client();
