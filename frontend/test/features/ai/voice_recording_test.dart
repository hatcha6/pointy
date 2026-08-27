import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/ai_chat.dart';
import 'package:pointy_frontend/src/features/ai/voice_recording.dart';

void main() {
  group('buildWavFile', () {
    test('prepends a 44-byte canonical RIFF/WAVE header', () {
      final pcm = Uint8List.fromList(List<int>.generate(64, (i) => i % 256));
      final wav = buildWavFile(pcm);

      expect(wav.length, 44 + pcm.length);
      expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
      expect(ascii.decode(wav.sublist(8, 12)), 'WAVE');
      expect(ascii.decode(wav.sublist(12, 16)), 'fmt ');
      expect(ascii.decode(wav.sublist(36, 40)), 'data');

      final header = ByteData.sublistView(wav);
      expect(header.getUint16(22, Endian.little), kVoiceNumChannels);
      expect(header.getUint32(24, Endian.little), kVoiceSampleRate);
      expect(header.getUint16(34, Endian.little), kVoiceBitsPerSample);
      // The data chunk length matches the PCM payload.
      expect(header.getUint32(40, Endian.little), pcm.length);
      // PCM bytes are appended verbatim after the header.
      expect(wav.sublist(44), pcm);
    });
  });

  group('pcm16PeakAmplitude', () {
    test('returns 0 for silence and for sub-sample chunks', () {
      expect(pcm16PeakAmplitude(Uint8List.fromList([0, 0, 0, 0])), 0);
      expect(pcm16PeakAmplitude(Uint8List.fromList([7])), 0);
      expect(pcm16PeakAmplitude(Uint8List(0)), 0);
    });

    test('peaks near 1.0 for a full-scale sample', () {
      // Int16 32767 little-endian = [0xFF, 0x7F].
      final amp = pcm16PeakAmplitude(
        Uint8List.fromList([0x00, 0x00, 0xFF, 0x7F]),
      );
      expect(amp, greaterThan(0.99));
      expect(amp, lessThanOrEqualTo(1.0));
    });

    test('reads negative samples by magnitude', () {
      // Int16 -32768 little-endian = [0x00, 0x80].
      final amp = pcm16PeakAmplitude(Uint8List.fromList([0x00, 0x80]));
      expect(amp, 1.0);
    });
  });

  group('formatRecordingDuration', () {
    test('formats as m:ss with zero-padded seconds', () {
      expect(formatRecordingDuration(0), '0:00');
      expect(formatRecordingDuration(5000), '0:05');
      expect(formatRecordingDuration(75000), '1:15');
      expect(formatRecordingDuration(600000), '10:00');
    });

    test('clamps negative input to 0:00', () {
      expect(formatRecordingDuration(-1), '0:00');
    });
  });

  group('AiAttachment audio kind', () {
    test('isAudio is set and serializes kind "audio"', () {
      final attachment = AiAttachment(
        kind: AiAttachmentKind.audio,
        dataUri: 'data:audio/wav;base64,QUJD',
        name: 'voice-message.wav',
        mime: 'audio/wav',
        durationMs: 12000,
      );
      expect(attachment.isAudio, isTrue);
      expect(attachment.isImage, isFalse);
      expect(attachment.toJson()['kind'], 'audio');
      expect(attachment.durationMs, 12000);
    });

    test('fromMetadata maps the "audio" kind (and unknown -> file)', () {
      final audio = AiAttachment.fromMetadata({
        'kind': 'audio',
        'name': 'voice-message.wav',
        'mime': 'audio/wav',
      });
      expect(audio.kind, AiAttachmentKind.audio);

      final unknown = AiAttachment.fromMetadata({'kind': 'mystery'});
      expect(unknown.kind, AiAttachmentKind.file);
    });
  });
}
