import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show rootBundle;

// BOOL PlaySoundW(LPCWSTR pszSound, HMODULE hmod, DWORD fdwSound) — with
// SND_MEMORY, pszSound is a pointer to a complete WAV image in memory.
typedef _PlaySoundWNative =
    Int32 Function(Pointer<Uint8> sound, IntPtr module, Uint32 flags);
typedef _PlaySoundWDart =
    int Function(Pointer<Uint8> sound, int module, int flags);

const int _sndAsync = 0x0001;
const int _sndNodefault = 0x0002;
const int _sndMemory = 0x0004;

_PlaySoundWDart? _playSoundW;

// WAV images copied to native memory once and kept alive for the app's
// lifetime: PlaySound(SND_ASYNC | SND_MEMORY) reads the buffer WHILE playing,
// so a freed (or GC-moved Dart) buffer would be a use-after-free.
final Map<String, Pointer<Uint8>> _nativeWavs = {};

/// Plays a bundled WAV through winmm.dll on Windows; silent elsewhere.
/// A new call interrupts the previous sound (latest outcome wins), which is
/// PlaySound's native behavior.
Future<void> playAsset(String asset) async {
  if (!Platform.isWindows) {
    return;
  }
  final playSound =
      _playSoundW ??= DynamicLibrary.open(
        'winmm.dll',
      ).lookupFunction<_PlaySoundWNative, _PlaySoundWDart>('PlaySoundW');

  var wav = _nativeWavs[asset];
  if (wav == null) {
    final bytes = await rootBundle.load(asset);
    final buffer = malloc.allocate<Uint8>(bytes.lengthInBytes);
    buffer
        .asTypedList(bytes.lengthInBytes)
        .setAll(0, bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
    wav = _nativeWavs[asset] = buffer;
  }

  playSound(wav, 0, _sndAsync | _sndMemory | _sndNodefault);
}
