import '../localization.dart';

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../studio_theme.dart';

/// Taps of the firmware's level peaks (NAM RPC op 10), in reply order.
enum LevelTap { input, nam, output }

/// Peak ballistics for polled peaks: instant rise, steady fall, a held peak
/// and a held clip warning. Peaks are full scale 1.0.
class LevelMeters {
  static const floorDb = -60.0;
  static const _fallDbPerSecond = 24.0;
  static const _hold = Duration(milliseconds: 1500);
  static const _clipHold = Duration(seconds: 2);

  /// The output clips at +-0.95 (engine.c); the input is the ADC's full scale.
  static const _clipAt = [0.99, 0.99, 0.95];

  final level = List.filled(LevelTap.values.length, floorDb);
  final peak = List.filled(LevelTap.values.length, floorDb);
  final _peakAt = List<DateTime?>.filled(LevelTap.values.length, null);
  final _clipAtTime = List<DateTime?>.filled(LevelTap.values.length, null);
  DateTime? _last;

  static double toDb(double value) => value <= 0
      ? floorDb
      : math.max(floorDb, 20 * math.log(value) / math.ln10);

  /// Three little-endian float32 peaks; null for a malformed reply.
  static List<double>? parse(Uint8List reply) {
    if (reply.length != 12) return null;
    final data = ByteData.sublistView(reply);
    final peaks = [
      for (var i = 0; i < 3; i++) data.getFloat32(i * 4, Endian.little),
    ];
    return peaks.every((p) => p.isFinite && p >= 0) ? peaks : null;
  }

  /// True when anything drawn changed; a steady signal needs no redraw.
  bool update(List<double> peaks, DateTime now) {
    final before = [...level, ...peak];
    final clippedBefore = [for (final t in LevelTap.values) clipped(t, now)];
    final elapsed = _last == null
        ? 0.0
        : now.difference(_last!).inMicroseconds / 1e6;
    _last = now;
    for (var i = 0; i < level.length; i++) {
      final db = toDb(peaks[i]);
      level[i] = math.max(db, level[i] - _fallDbPerSecond * elapsed);
      final heldSince = _peakAt[i];
      if (db >= peak[i] || heldSince == null) {
        peak[i] = db;
        _peakAt[i] = now;
      } else if (now.difference(heldSince) > _hold) {
        peak[i] = math.max(level[i], peak[i] - _fallDbPerSecond * elapsed);
      }
      if (peaks[i] >= _clipAt[i]) _clipAtTime[i] = now;
    }
    final after = [...level, ...peak];
    for (var i = 0; i < after.length; i++) {
      if (after[i] != before[i]) return true;
    }
    return [for (final t in LevelTap.values) clipped(t, now)].indexed
        .any((e) => e.$2 != clippedBefore[e.$1]);
  }

  bool clipped(LevelTap tap, DateTime now) {
    final at = _clipAtTime[tap.index];
    return at != null && now.difference(at) < _clipHold;
  }
}

/// IN / NAM / OUT peak meters on one line for the controller sidebar. Each
/// meter's tooltip and semantics carry the exact level and clip state.
class LevelMeterPanel extends StatelessWidget {
  final LevelMeters meters;

  /// Taps to draw, left to right.
  final List<LevelTap> taps;
  const LevelMeterPanel({super.key, required this.meters, required this.taps});

  static String label(LevelTap tap) => switch (tap) {
    LevelTap.input => 'IN',
    LevelTap.nam => 'NAM',
    LevelTap.output => 'OUT',
  };

  static String describe(LevelTap tap) => switch (tap) {
    LevelTap.input => tr("ギター入力（入力ゲイン前）"),
    LevelTap.nam => tr("NAMモデルへの入力（入力ゲイン・GAIN後）"),
    LevelTap.output => tr("本体の出力"),
  };

  static String reading(double db) =>
      db <= LevelMeters.floorDb ? '−∞ dBFS' : '${db.toStringAsFixed(1)} dBFS';

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Row(
      children: [
        for (final (i, tap) in taps.indexed) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(child: _meter(tap, now)),
        ],
      ],
    );
  }

  Widget _meter(LevelTap tap, DateTime now) {
    final level = meters.level[tap.index];
    final clipped = meters.clipped(tap, now);
    final value = reading(level);
    return Tooltip(
      message: '${describe(tap)}: $value',
      child: Semantics(
        label: label(tap),
        value: clipped ? '$value, ${tr("クリップ")}' : value,
        child: ExcludeSemantics(
          child: Row(
            children: [
              Text(
                label(tap),
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: .6,
                  color: clipped ? _clipColor : const Color(0xff9daaba),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: SizedBox(
                  height: 8,
                  child: CustomPaint(
                    painter: _MeterPainter(
                      level,
                      meters.peak[tap.index],
                      clipped,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _clipColor = Color(0xffff5a5a);

class _MeterPainter extends CustomPainter {
  final double level, peak;
  final bool clipped;
  _MeterPainter(this.level, this.peak, this.clipped);

  static double _x(double db, double width) =>
      width * ((db - LevelMeters.floorDb) / -LevelMeters.floorDb).clamp(0, 1);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, r),
      Paint()..color = StudioTheme.line,
    );
    // -18 dBFS and -6 dBFS mark where the colour changes.
    final segments = [
      (LevelMeters.floorDb, -18.0, StudioTheme.ready),
      (-18.0, -6.0, const Color(0xffe4bd69)),
      (-6.0, 0.0, _clipColor),
    ];
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(Offset.zero & size, r));
    for (final (from, to, color) in segments) {
      if (level <= from) break;
      final left = _x(from, size.width);
      final right = _x(math.min(level, to), size.width);
      canvas.drawRect(
        Rect.fromLTRB(left, 0, right, size.height),
        Paint()..color = color,
      );
    }
    canvas.restore();
    if (peak > LevelMeters.floorDb) {
      final x = _x(peak, size.width);
      canvas.drawRect(
        Rect.fromLTWH(math.max(0, x - 2), 0, 2, size.height),
        Paint()..color = Colors.white70,
      );
    }
    if (clipped) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(size.width - 4, 0, 4, size.height),
          r,
        ),
        Paint()..color = _clipColor,
      );
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) =>
      old.level != level || old.peak != peak || old.clipped != clipped;
}
