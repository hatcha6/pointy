import 'dart:convert';
import 'dart:typed_data';

import 'package:record/record.dart';

/// Voice messages are captured as 16 kHz mono PCM16 and wrapped in a WAV
/// container. 16 kHz mono is ideal for speech and keeps the base64 payload small
/// enough to ride the existing attachment path; WAV is the one audio container
/// every audio-capable model on OpenRouter accepts as an `input_audio` part.
const int kVoiceSampleRate = 16000;
const int kVoiceNumChannels = 1;
const int kVoiceBitsPerSample = 16;

/// A thin seam over the `record` plugin so the recorder UI can be widget-tested
/// with a fake (there is no real microphone in the test VM). Implementations
/// stream little-endian PCM16 chunks while recording.
abstract class VoiceRecorder {
  /// Whether the app may record — requests the OS permission if not yet granted.
  Future<bool> hasPermission();

  /// Begin streaming PCM16 audio. Each event is a chunk of raw samples.
  Future<Stream<Uint8List>> start();

  /// Stop the current recording (the accumulated bytes are owned by the caller).
  Future<void> stop();

  /// Release native resources. Terminal — a new recorder is needed afterward.
  Future<void> dispose();
}

/// [VoiceRecorder] backed by the `record` package, streaming raw PCM16 so the
/// caller can both drive a live waveform and assemble a WAV file without any
/// file I/O (works the same on mobile, desktop, and web).
class RecordVoiceRecorder implements VoiceRecorder {
  RecordVoiceRecorder([AudioRecorder? recorder])
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start() => _recorder.startStream(
    const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: kVoiceSampleRate,
      numChannels: kVoiceNumChannels,
      // Speech-friendly cleanup where the platform supports it.
      echoCancel: true,
      noiseSuppress: true,
    ),
  );

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// Wraps raw little-endian PCM16 [pcm] samples in a canonical 44-byte RIFF/WAVE
/// header so the result is a self-describing `audio/wav` file.
Uint8List buildWavFile(
  Uint8List pcm, {
  int sampleRate = kVoiceSampleRate,
  int numChannels = kVoiceNumChannels,
}) {
  const bitsPerSample = kVoiceBitsPerSample;
  final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
  final blockAlign = numChannels * bitsPerSample ~/ 8;
  final dataLength = pcm.length;

  final out = BytesBuilder(copy: false);
  void putAscii(String s) => out.add(ascii.encode(s));
  void putU32(int v) =>
      out.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  void putU16(int v) => out.add([v & 0xff, (v >> 8) & 0xff]);

  putAscii('RIFF');
  putU32(36 + dataLength); // file size minus the leading 8 bytes
  putAscii('WAVE');
  putAscii('fmt ');
  putU32(16); // PCM fmt chunk size
  putU16(1); // audio format = PCM
  putU16(numChannels);
  putU32(sampleRate);
  putU32(byteRate);
  putU16(blockAlign);
  putU16(bitsPerSample);
  putAscii('data');
  putU32(dataLength);
  out.add(pcm);
  return out.toBytes();
}

/// Peak amplitude (0..1) of a little-endian PCM16 [chunk], driving the live
/// waveform. Peak (rather than RMS) gives the bars a lively, responsive feel.
double pcm16PeakAmplitude(Uint8List chunk) {
  if (chunk.length < 2) {
    return 0;
  }
  final data = ByteData.sublistView(chunk);
  var peak = 0;
  for (var i = 0; i + 1 < chunk.length; i += 2) {
    final sample = data.getInt16(i, Endian.little).abs();
    if (sample > peak) {
      peak = sample;
    }
  }
  return (peak / 32768).clamp(0.0, 1.0);
}

/// Formats a recording length as `m:ss` (e.g. 75000ms -> "1:15").
String formatRecordingDuration(int milliseconds) {
  final totalSeconds = (milliseconds < 0 ? 0 : milliseconds) ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
