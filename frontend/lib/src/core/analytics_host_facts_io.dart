import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// What the machine underneath is: two maps, ready to be merged into an event.
typedef AnalyticsHostFacts = ({
  Map<String, Object?> attributes,
  Map<String, num> metrics,
});

/// Reads the machine this app is running on.
///
/// The point of collecting this is that "the till is slow" and "the till is a
/// two-core box with 2 GB of RAM" are the same finding, and the export could
/// not tell them apart: every device in the fleet was described by a random
/// installation id and nothing else, so a slow shop and slow software looked
/// identical. There is a whole branch of this app (`compat/win8`) that exists
/// because some of these machines are a decade old, and no telemetry said which
/// ones they were.
///
/// Deliberately built out of the SDK and one small `kernel32` call rather than
/// a device-info plugin: nothing here changes a native build, so it ships
/// unchanged on the frozen compat branch, where adding a plugin would not.
///
/// Every block is guarded on its own. A launch must not be held up, and must
/// certainly not fail, because the app was curious about its host — so a lookup
/// that throws costs that one field and nothing else.
Future<AnalyticsHostFacts> readHostFacts() async {
  final attributes = <String, Object?>{};
  final metrics = <String, num>{};

  _guard(() {
    attributes['os'] = Platform.operatingSystem;
    attributes['os_version'] = _truncate(Platform.operatingSystemVersion, 120);
    attributes['host_locale'] = Platform.localeName;
    // Which physical machine this is. The installation id is a random UUID by
    // design, so without this nobody can walk to the till a finding is about.
    attributes['host_name'] = _truncate(Platform.localHostname, 80);
    // Separates a compat build from a mainline one outright: the two branches
    // are frozen at different SDKs, and that is otherwise invisible.
    attributes['dart_runtime'] = Platform.version.split(' ').first;
    metrics['cpu_cores'] = Platform.numberOfProcessors;
  });

  _guard(() {
    // What this app is costing the machine. Paired with total RAM below, it is
    // the difference between "the till is short of memory" and "we are the
    // reason it is".
    metrics['app_rss_mb'] = _megabytes(ProcessInfo.currentRss);
    metrics['app_peak_rss_mb'] = _megabytes(ProcessInfo.maxRss);
  });

  if (Platform.isWindows) {
    _guard(() => _readWindowsCpu(attributes));
    _guard(() => _readWindowsMemory(metrics));
  } else if (Platform.isLinux || Platform.isAndroid) {
    await _guardAsync(() => _readProcMemory(metrics));
    await _guardAsync(() => _readProcCpu(attributes));
  }

  return (attributes: attributes, metrics: metrics);
}

// -- Windows ----------------------------------------------------------------

/// Windows publishes the processor in the environment, so this costs nothing:
/// `PROCESSOR_IDENTIFIER` is a string like
/// "Intel64 Family 6 Model 142 Stepping 10, GenuineIntel".
void _readWindowsCpu(Map<String, Object?> attributes) {
  final environment = Platform.environment;
  final identifier = environment['PROCESSOR_IDENTIFIER']?.trim() ?? '';
  final architecture = environment['PROCESSOR_ARCHITECTURE']?.trim() ?? '';
  if (identifier.isNotEmpty) {
    attributes['cpu_model'] = _truncate(identifier, 120);
  }
  if (architecture.isNotEmpty) {
    attributes['cpu_arch'] = architecture;
  }
}

/// `MEMORYSTATUSEX`, as `GlobalMemoryStatusEx` fills it in.
///
/// `dwLength` must be set to the struct's own size before the call, which is
/// how the API versions itself; it returns 0 and sets no fields otherwise.
final class _MemoryStatusEx extends Struct {
  @Uint32()
  external int length;
  @Uint32()
  external int memoryLoad;
  @Uint64()
  external int totalPhys;
  @Uint64()
  external int availPhys;
  @Uint64()
  external int totalPageFile;
  @Uint64()
  external int availPageFile;
  @Uint64()
  external int totalVirtual;
  @Uint64()
  external int availVirtual;
  @Uint64()
  external int availExtendedVirtual;
}

typedef _GlobalMemoryStatusExNative = Int32 Function(Pointer<_MemoryStatusEx>);
typedef _GlobalMemoryStatusExDart = int Function(Pointer<_MemoryStatusEx>);

void _readWindowsMemory(Map<String, num> metrics) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final globalMemoryStatusEx = kernel32
      .lookupFunction<_GlobalMemoryStatusExNative, _GlobalMemoryStatusExDart>(
        'GlobalMemoryStatusEx',
      );
  final status = calloc<_MemoryStatusEx>();
  try {
    status.ref.length = sizeOf<_MemoryStatusEx>();
    if (globalMemoryStatusEx(status) == 0) {
      return;
    }
    final total = status.ref.totalPhys;
    final available = status.ref.availPhys;
    if (total > 0) {
      metrics['ram_total_mb'] = _megabytes(total);
    }
    if (available > 0) {
      metrics['ram_available_mb'] = _megabytes(available);
    }
    metrics['ram_load_percent'] = status.ref.memoryLoad;
  } finally {
    calloc.free(status);
  }
}

// -- Linux and Android ------------------------------------------------------

Future<void> _readProcMemory(Map<String, num> metrics) async {
  final meminfo = File('/proc/meminfo');
  if (!await meminfo.exists()) {
    return;
  }
  for (final line in await meminfo.readAsLines()) {
    // Lines read "MemTotal:       16324812 kB".
    if (line.startsWith('MemTotal:')) {
      final kilobytes = _firstInteger(line);
      if (kilobytes != null) {
        metrics['ram_total_mb'] = (kilobytes / 1024).round();
      }
    } else if (line.startsWith('MemAvailable:')) {
      final kilobytes = _firstInteger(line);
      if (kilobytes != null) {
        metrics['ram_available_mb'] = (kilobytes / 1024).round();
      }
    }
  }
}

Future<void> _readProcCpu(Map<String, Object?> attributes) async {
  final cpuinfo = File('/proc/cpuinfo');
  if (!await cpuinfo.exists()) {
    return;
  }
  for (final line in await cpuinfo.readAsLines()) {
    // "model name" on x86; ARM boards and most Android devices answer to
    // "Hardware" instead, and newer Android redacts both — hence no fallback
    // beyond leaving the field out.
    if (!line.startsWith('model name') && !line.startsWith('Hardware')) {
      continue;
    }
    final value = line.split(':').skip(1).join(':').trim();
    if (value.isNotEmpty) {
      attributes['cpu_model'] = _truncate(value, 120);
      return;
    }
  }
}

// -- helpers ----------------------------------------------------------------

void _guard(void Function() body) {
  try {
    body();
  } catch (_) {
    return;
  }
}

Future<void> _guardAsync(Future<void> Function() body) async {
  try {
    await body();
  } catch (_) {
    return;
  }
}

int? _firstInteger(String line) {
  final match = RegExp(r'\d+').firstMatch(line);
  return match == null ? null : int.tryParse(match.group(0)!);
}

int _megabytes(int bytes) => (bytes / (1024 * 1024)).round();

String _truncate(String value, int maxLength) {
  if (value.length <= maxLength) {
    return value;
  }
  return value.substring(0, maxLength);
}
