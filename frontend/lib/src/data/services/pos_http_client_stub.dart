import 'package:http/http.dart' as http;

/// A platform with neither `dart:io` nor JavaScript interop:
/// `package:http` picks the client itself.
http.Client createPlatformHttpClient() => http.Client();
