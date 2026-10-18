import 'dart:io';
import 'dart:typed_data';

import 'package:fb200_nam/ir_wav.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _riff(
  int format,
  int channels,
  int rate,
  int bits, {
  List<int>? samples,
}) {
  final block = channels * bits ~/ 8;
  final body = BytesBuilder()
    ..add('WAVE'.codeUnits)
    ..add('fmt '.codeUnits)
    ..add([16, 0, 0, 0])
    ..add(_u16le(format))
    ..add(_u16le(channels))
    ..add(_u32le(rate))
    ..add(_u32le(rate * block))
    ..add(_u16le(block))
    ..add(_u16le(bits))
    ..add('data'.codeUnits)
    ..add(_u32le(samples?.length ?? 0))
    ..add(samples ?? []);
  return Uint8List.fromList([
    ...'RIFF'.codeUnits,
    ..._u32le(body.length),
    ...body.takeBytes(),
  ]);
}

List<int> _u16le(int n) => [n & 255, n >> 8 & 255];
List<int> _u32le(int n) => [
  n & 255,
  n >> 8 & 255,
  n >> 16 & 255,
  n >> 24 & 255,
];

List<int> _pcm16(double v) {
  final x = (v * 32768).round().clamp(-32768, 32767);
  return [x & 255, x >> 8 & 255];
}

void main() {
  test('16-bit mono at 44.1 kHz passes through and zero-pads to 1024', () {
    final samples = <int>[];
    for (var i = 0; i < 500; i++) {
      samples.addAll(_pcm16(i == 0 ? 0.75 : 0.5));
    }
    final ir = wavToIr(_riff(1, 1, 44100, 16, samples: samples));
    expect(ir.length, irLength);
    expect(ir[0], (0.75 * 32768).round() / 32768);
    expect(ir[1], 0.5);
    expect(ir[499], 0.5);
    expect(ir[500], 0.0);
    expect(ir[1023], 0.0);
  });

  test('stereo takes channel 0 only', () {
    final samples = <int>[
      ..._pcm16(0.25), ..._pcm16(-0.75), // frame 0: L, R
      ..._pcm16(0.5), ..._pcm16(-0.1), // frame 1: L, R
    ];
    final ir = wavToIr(_riff(1, 2, 44100, 16, samples: samples));
    expect(ir.sublist(0, 2), [0.25, 0.5]);
  });

  test('8-bit and 24-bit decode like the reference conversion', () {
    final ir8 = wavToIr(
      _riff(1, 1, 44100, 8, samples: [128 + 100, 128 - 100, 128]),
    );
    expect(ir8[0], closeTo(100 / 128, 1e-9));
    expect(ir8[1], closeTo(-100 / 128, 1e-9));
    expect(ir8[2], 0.0);
    final ir24 = wavToIr(
      _riff(1, 1, 44100, 24, samples: [1, 0, 0, 255, 255, 255]),
    );
    expect(ir24[0], 1.0 / 8388608);
    expect(ir24[1], -1.0 / 8388608);
  });

  test('WAVE_FORMAT_EXTENSIBLE uses the real sub-format', () {
    // fmt: 16 standard bytes + cbSize(22) + validBits(2) + mask(4) + GUID(16)
    final fmt = BytesBuilder()
      ..add(_u16le(0xfffe))
      ..add(_u16le(1))
      ..add(_u32le(44100))
      ..add(_u32le(88200))
      ..add(_u16le(2))
      ..add(_u16le(16))
      ..add(_u16le(22))
      ..add(_u16le(16))
      ..add(_u32le(0))
      // sub-format GUID {00000001-0000-0010-8000-00aa00389b71} (PCM)
      ..add([1, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71]);
    final body = BytesBuilder()
      ..add('WAVE'.codeUnits)
      ..add('fmt '.codeUnits)
      ..add(_u32le(fmt.length))
      ..add(fmt.takeBytes())
      ..add('data'.codeUnits)
      ..add(_u32le(2))
      ..add(_pcm16(0.5));
    final wavBytes = Uint8List.fromList([
      ...'RIFF'.codeUnits,
      ..._u32le(body.length),
      ...body.takeBytes(),
    ]);
    final ir = wavToIr(wavBytes);
    expect(ir[0], 0.5);
  });

  test('rejects broken inputs without touching anything', () {
    expect(() => wavToIr(Uint8List(4)), throwsA(isA<WavError>()));
    final notRiff = _riff(1, 1, 44100, 16, samples: _pcm16(0.1));
    notRiff[0] = 0x58;
    expect(() => wavToIr(notRiff), throwsA(isA<WavError>()));
    expect(
      () => wavToIr(_riff(2, 1, 44100, 16, samples: _pcm16(0.1))),
      throwsA(isA<WavError>()),
    );
    expect(
      () => wavToIr(_riff(1, 1, 44100, 12, samples: [1, 2])),
      throwsA(isA<WavError>()),
    );
    final truncated = _riff(1, 1, 44100, 16, samples: _pcm16(0.1));
    expect(
      () => wavToIr(Uint8List.sublistView(truncated, 0, truncated.length - 1)),
      throwsA(isA<WavError>()),
    );
  });

  test('resampler matches the shared Python fixture byte-for-byte', () {
    final wavBytes = File('test/fixtures/ir48k.wav').readAsBytesSync();
    final expected = File('test/fixtures/ir48k.f32').readAsBytesSync();
    final packed = irBytes(wavToIr(Uint8List.fromList(wavBytes)));
    expect(packed.length, 4096);
    expect(packed, expected);
  });

  test('44.1 kHz float32 mono fixture matches byte-for-byte', () {
    final wavBytes = File('test/fixtures/ir441_mono.wav').readAsBytesSync();
    final expected = File('test/fixtures/ir441_mono.f32').readAsBytesSync();
    expect(irBytes(wavToIr(Uint8List.fromList(wavBytes))), expected);
  });

  test('readWav splits channels and reports the rate', () {
    final samples = <int>[..._pcm16(0.25), ..._pcm16(-0.75)];
    final wavData = readWav(_riff(1, 2, 22050, 16, samples: samples));
    expect(wavData.rate, 22050);
    expect(wavData.channels.length, 2);
    expect(wavData.channels[0], [0.25]);
    expect(wavData.channels[1], [-0.75]);
  });
}
