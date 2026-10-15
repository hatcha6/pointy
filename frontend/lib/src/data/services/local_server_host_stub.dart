import 'local_server_host.dart';

/// Web: a browser is never the shop's WSL server PC.
LocalServerHostPlatform createLocalServerHostPlatform() =>
    const NoLocalServerHost();
