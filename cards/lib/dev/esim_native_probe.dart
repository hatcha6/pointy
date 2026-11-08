// Dev-only (safe to delete): calls the real native eSIM channel and shows what it
// answers, on a simulator, an emulator or a phone. Never imported by main.dart.
//
//   flutter run -t lib/dev/esim_native_probe.dart
//
// The links carry Airalo Sandbox's dummy eSIM: the system's screen opens, and no
// real plan can be added with it.
import 'package:flutter/material.dart';

import '../src/core/esim/esim_device.dart';

const _lpa = r'LPA:1$lpa.airalo.com$DUMMY-2611020919-FqXvg-04269';
const _apple =
    'https://esimsetup.apple.com/esim_qrcode_provisioning?carddata=$_lpa';
const _android =
    'https://esimsetup.android.com/esim_qrcode_provisioning?carddata=$_lpa';

void main() => runApp(const MaterialApp(home: _Probe()));

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with WidgetsBindingObserver {
  static const _device = EsimDevice();
  EsimDeviceFacts? _facts;
  final _log = <String>[];

  void _note(String line) => setState(() => _log.add(line));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _device.facts().then((facts) => setState(() => _facts = facts));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _note('lifecycle: ${state.name}');

  Future<void> _open(String label, String url) async =>
      _note('$label -> ${await _device.install(url)}');

  @override
  Widget build(BuildContext context) {
    final facts = _facts;
    final link = facts?.isAndroid == true ? _android : _apple;
    return Scaffold(
      appBar: AppBar(title: const Text('eSIM native probe')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            facts == null
                ? 'reading…'
                : 'platform ${facts.platform}\nmodel ${facts.model}\n'
                      'os ${facts.osVersion}\nsupports_esim ${facts.supportsEsim}\n'
                      'simulator ${facts.simulator}\n'
                      'direct_install ${facts.directInstall}',
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => _open('install', link),
            child: const Text('Install link'),
          ),
          OutlinedButton(
            onPressed: () => _open('foreign', 'https://example.com/x'),
            child: const Text('Foreign link (must be refused)'),
          ),
          const SizedBox(height: 12),
          for (final line in _log) Text(line),
        ],
      ),
    );
  }
}
