/// WAV → FB200 user-IR conversion: a Dart port of `src/fb200/wav.py`.
///
/// Matches the official editor: decode any WAV to 44.1 kHz, take channel 0,
/// truncate or zero-pad to exactly 1024 float32 samples. The firmware plays
/// the first 512 of them (CAB_TAPS).
library;

import 'localization.dart';

import 'dart:math' as math;
import 'dart:typed_data';

class WavError implements Exception {
  final String message;
  WavError(this.message);
  @override
  String toString() => message;
}

const irLength = 1024;
const irSampleRate = 44100;

// Kaiser windowed-sinc resampler: 48 zero crossings per side, beta 9 (about
// 90 dB stopband), cutoff at 92 % of the lower Nyquist.
const _sincZeros = 48;
const _kaiserBeta = 9.0;
const _cutoff = 0.92;

class _WavHead {
  final int audioFormat;
  final int channels;
  final int rate;
  final int bits;
  final Uint8List data;
  const _WavHead(
    this.audioFormat,
    this.channels,
    this.rate,
    this.bits,
    this.data,
  );
}

_WavHead _readWav(Uint8List raw) {
  if (raw.length < 12 ||
      raw[0] != 0x52 ||
      raw[1] != 0x49 ||
      raw[2] != 0x46 ||
      raw[3] != 0x46 ||
      raw[8] != 0x57 ||
      raw[9] != 0x41 ||
      raw[10] != 0x56 ||
      raw[11] != 0x45) {
    throw WavError(tr("WAVファイルではありません。"));
  }
  final view = ByteData.sublistView(raw);
  Uint8List? fmt, data;
  var pos = 12;
  while (pos + 8 <= raw.length) {
    final size = view.getUint32(pos + 4, Endian.little);
    if (pos + 8 + size > raw.length) {
      throw WavError(tr("WAVファイルが壊れています。"));
    }
    final id = raw.sublist(pos, pos + 4);
    if (id[0] == 0x66 && id[1] == 0x6d && id[2] == 0x74 && id[3] == 0x20) {
      fmt = raw.sublist(pos + 8, pos + 8 + size);
    } else if (id[0] == 0x64 &&
        id[1] == 0x61 &&
        id[2] == 0x74 &&
        id[3] == 0x61) {
      data = raw.sublist(pos + 8, pos + 8 + size);
    }
    pos += 8 + size + (size & 1);
  }
  if (fmt == null || data == null) {
    throw WavError(tr("WAVファイルに音声データがありません。"));
  }
  if (fmt.length < 16) {
    throw WavError(tr("WAVファイルが壊れています。"));
  }
  final f = ByteData.sublistView(fmt);
  var audioFormat = f.getUint16(0, Endian.little);
  final channels = f.getUint16(2, Endian.little);
  final rate = f.getUint32(4, Endian.little);
  final bits = f.getUint16(14, Endian.little);
  // WAVE_FORMAT_EXTENSIBLE carries the real format in the sub-format GUID.
  if (audioFormat == 0xfffe && fmt.length >= 26) {
    audioFormat = f.getUint16(24, Endian.little);
  }
  if (channels < 1) throw WavError(tr("WAVのチャンネル数が不正です。"));
  if (rate <= 0) throw WavError(tr("WAVのサンプルレートが不正です。"));
  if (bits <= 0) throw WavError(tr("WAVのビット深度が不正です。"));
  if (data.isEmpty) throw WavError(tr("WAVファイルに音声データがありません。"));
  return _WavHead(audioFormat, channels, rate, bits, data);
}

double _besselI0(double x) {
  var total = 1.0, term = 1.0;
  var k = 0;
  while (term > 1e-17 * total) {
    k++;
    term *= (x / (2 * k)) * (x / (2 * k));
    total += term;
  }
  return total;
}

/// Exact round-half-to-even of `n * dst / src` for non-negative integers.
int _roundRatio(int n, int dst, int src) {
  final product = n * dst;
  final q = product ~/ src, r = product % src;
  if (2 * r > src || (2 * r == src && q.isOdd)) return q + 1;
  return q;
}

int _gcd(int a, int b) {
  while (b != 0) {
    final t = a % b;
    a = b;
    b = t;
  }
  return a;
}

/// Neumaier compensated summation (matches Python `math.fsum` rounding for
/// these short dot products).
double _fsum(Iterable<double> values) {
  var sum = 0.0, c = 0.0;
  for (final v in values) {
    final t = sum + v;
    if (sum.abs() >= v.abs()) {
      c += (sum - t) + v;
    } else {
      c += (v - t) + sum;
    }
    sum = t;
  }
  return sum + c;
}

/// Kaiser windowed-sinc resampler, a port of `fb200.wav.resample`.
List<double> resample(
  List<double> samples,
  int srcRate,
  int dstRate, {
  int? maxOut,
}) {
  if (srcRate <= 0 || dstRate <= 0) {
    throw WavError(tr("サンプルレートが不正です。"));
  }
  final n = samples.length;
  var outLen = _roundRatio(n, dstRate, srcRate);
  if (maxOut != null && outLen > maxOut) outLen = maxOut;
  if (srcRate == dstRate || n == 0) {
    return samples.sublist(0, outLen);
  }
  final g = _gcd(dstRate, srcRate);
  final up = dstRate ~/ g, down = srcRate ~/ g;
  final fc = _cutoff * math.min(1.0, dstRate / srcRate);
  final half = _sincZeros / fc;
  final i0Beta = _besselI0(_kaiserBeta);
  final pad = half.ceil() + 2;
  final x = List<double>.filled(n + 2 * pad, 0.0);
  x.setRange(pad, pad + n, samples);
  final kernels = <int, MapEntry<int, List<double>>>{};
  final out = List<double>.filled(outLen, 0.0);
  for (var i = 0; i < outLen; i++) {
    final base = (i * down) ~/ up, rem = (i * down) % up;
    final cached = kernels[rem];
    final entry = cached ?? _buildKernel(rem, up, fc, half, i0Beta);
    if (cached == null) kernels[rem] = entry;
    final lo = entry.key, weights = entry.value;
    final start = base + lo + pad;
    out[i] = _fsum([
      for (var j = 0; j < weights.length; j++) weights[j] * x[start + j],
    ]);
  }
  return out;
}

MapEntry<int, List<double>> _buildKernel(
  int rem,
  int up,
  double fc,
  double half,
  double i0Beta,
) {
  final frac = rem / up;
  final lo = (frac - half).ceil(), hi = (frac + half).floor();
  final weights = <double>[];
  for (var j = lo; j <= hi; j++) {
    final u = frac - j;
    final arg = fc * u;
    final s = arg == 0 ? 1.0 : math.sin(math.pi * arg) / (math.pi * arg);
    final r = u / half;
    final w =
        _besselI0(_kaiserBeta * math.sqrt(math.max(0.0, 1.0 - r * r))) / i0Beta;
    weights.add(s * w);
  }
  final norm = 1.0 / _fsum(weights);
  return MapEntry(lo, [for (final w in weights) w * norm]);
}

/// Decode a WAV into one float list per channel and its sample rate.
class WavData {
  final List<List<double>> channels;
  final int rate;
  const WavData(this.channels, this.rate);
}

WavData readWav(Uint8List bytes) {
  final head = _readWav(bytes);
  final decoded = _decodeAll(head);
  return WavData([
    for (var c = 0; c < head.channels; c++)
      [for (var i = c; i < decoded.length; i += head.channels) decoded[i]],
  ], head.rate);
}

List<double> _decodeAll(_WavHead head) {
  final data = head.data;
  final view = ByteData.sublistView(data);
  final audioFormat = head.audioFormat, bits = head.bits;
  if (audioFormat == 3 && bits == 32) {
    return [
      for (var i = 0; i < data.length ~/ 4; i++)
        view.getFloat32(i * 4, Endian.little),
    ];
  }
  if (audioFormat != 1) {
    throw WavError(tr("対応していないWAV形式です (format {0})。", [audioFormat]));
  }
  switch (bits) {
    case 8:
      return [for (var i = 0; i < data.length; i++) (data[i] - 128) / 128.0];
    case 16:
      return [
        for (var i = 0; i < data.length ~/ 2; i++)
          view.getInt16(i * 2, Endian.little) / 32768.0,
      ];
    case 24:
      return [
        for (var i = 0; i + 2 < data.length; i += 3)
          _intFrom3Bytes(data[i], data[i + 1], data[i + 2]) / 8388608.0,
      ];
    case 32:
      return [
        for (var i = 0; i < data.length ~/ 4; i++)
          view.getInt32(i * 4, Endian.little) / 2147483648.0,
      ];
    default:
      throw WavError(tr("対応していないビット深度です ({0} bit)。", [bits]));
  }
}

int _intFrom3Bytes(int b0, int b1, int b2) {
  var v = b0 | b1 << 8 | b2 << 16;
  if (v & 0x800000 != 0) v -= 0x1000000;
  return v;
}

/// Official-editor conversion: channel 0, resampled to 44.1 kHz, truncated or
/// zero-padded to exactly 1024 samples.
Float32List wavToIr(Uint8List bytes) {
  final head = _readWav(bytes);
  final mono = _decodeAll(head);
  final left = [for (var i = 0; i < mono.length; i += head.channels) mono[i]];
  final headSamples = resample(left, head.rate, irSampleRate, maxOut: irLength);
  final out = Float32List(irLength);
  for (var i = 0; i < headSamples.length && i < irLength; i++) {
    final v = headSamples[i];
    if (!v.isFinite) throw WavError(tr("WAVに異常な値が含まれています。"));
    out[i] = v;
  }
  return out;
}

/// Pack 1024 float32 samples little endian for the `61` upload frames.
Uint8List irBytes(Float32List samples) {
  final out = Uint8List(samples.length * 4);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < samples.length; i++) {
    view.setFloat32(i * 4, samples[i], Endian.little);
  }
  return out;
}
