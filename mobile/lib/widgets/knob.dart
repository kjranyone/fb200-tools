import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show Drag, DragEndDetails, DragUpdateDetails, ImmediateMultiDragGestureRecognizer;
import 'package:flutter/material.dart';

/// A rotary control in the spirit of the Quad Cortex: drag around the knob
/// to change the value (the farther from the centre, the coarser), release
/// to commit. The arc fills over a 270° sweep with a soft accent glow.
///
/// Uses ImmediateMultiDragGestureRecognizer so the knob wins the gesture
/// arena against the surrounding ListView's scroll (a plain GestureDetector
/// pan always loses to the vertical drag recognizer of the ancestor
/// scrollable on a real device).
class Knob extends StatefulWidget {
  final String label;
  final int value;
  final int min;
  final int max;
  final int step;
  final String Function(int)? format;
  final ValueChanged<int> onChanged; // committed on release
  final bool enabled;

  const Knob({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 1,
    this.format,
    this.enabled = true,
  });

  @override
  State<Knob> createState() => _KnobState();
}

class _KnobState extends State<Knob> {
  bool _dragging = false;
  late int _draft;
  late double _knobSize;

  @override
  void initState() {
    super.initState();
    _draft = widget.value;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Adaptive sizing keeps the no-scroll layout usable on short screens
    // (landscape phones) while staying comfortable on tablets.
    final h = MediaQuery.sizeOf(context).height;
    _knobSize = h < 480 ? 56 : (h < 640 ? 66 : 76);
  }

  @override
  void didUpdateWidget(Knob old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_dragging) _draft = widget.value;
  }

  double get _fraction => (widget.max == widget.min)
      ? 0
      : (_draft - widget.min) / (widget.max - widget.min);

  void _updateFromPosition(Offset local) {
    final center = Offset(_knobSize / 2, _knobSize / 2);
    final angle = math.atan2(local.dy - center.dy, local.dx - center.dx);
    if (_lastAngle case final last?) {
      var delta = angle - last;
      if (delta > math.pi) delta -= 2 * math.pi;
      if (delta < -math.pi) delta += 2 * math.pi;
      final radius = (local - center).distance / (_knobSize / 2);
      final steps = (widget.max - widget.min) / widget.step;
      final next = (_draft - widget.min) / widget.step +
          delta / (2 * math.pi) * steps * (0.35 + 0.65 * radius.clamp(0.2, 1.4));
      final v = widget.min +
          (next.clamp(0.0, steps.toDouble()).round() * widget.step);
      if (v != _draft) setState(() => _draft = v);
    }
    _lastAngle = angle;
  }

  double? _lastAngle;

  Drag? _startDrag(Offset position) {
    if (!widget.enabled) return null;
    _lastAngle = null;
    setState(() => _dragging = true);
    return _KnobDrag(
      onMove: (details) {
        if (!mounted) return;
        _updateFromPosition(details.localPosition);
      },
      onDone: () {
        if (!mounted) return;
        _lastAngle = null;
        setState(() => _dragging = false);
        if (_draft != widget.value) widget.onChanged(_draft);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = widget.enabled && _draft > widget.min;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: widget.label,
          value: _text,
          enabled: widget.enabled,
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            gestures: {
              ImmediateMultiDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    ImmediateMultiDragGestureRecognizer
                  >(
                () => ImmediateMultiDragGestureRecognizer(),
                (ImmediateMultiDragGestureRecognizer instance) {
                  instance.onStart = _startDrag;
                },
              ),
            },
            child: SizedBox(
              width: _knobSize,
              height: _knobSize,
              child: CustomPaint(
                painter: _KnobPainter(
                  fraction: _fraction,
                  accent: scheme.primary,
                  track: scheme.outlineVariant.withValues(alpha: 0.35),
                  active: active,
                  dragging: _dragging,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          widget.label,
          style: TextStyle(
            fontSize: 11,
            color: widget.enabled ? scheme.onSurfaceVariant : scheme.outline,
          ),
        ),
        Text(
          _text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: widget.enabled
                ? (active ? scheme.primary : scheme.onSurface)
                : scheme.outline,
          ),
        ),
      ],
    );
  }

  String get _text => widget.format?.call(_draft) ?? _draft.toString();
}

class _KnobDrag extends Drag {
  _KnobDrag({required this.onMove, required this.onDone});
  final void Function(DragUpdateDetails) onMove;
  final void Function() onDone;

  @override
  void update(DragUpdateDetails details) => onMove(details);

  @override
  void end(DragEndDetails details) => onDone();

  @override
  void cancel() => onDone();
}

class _KnobPainter extends CustomPainter {
  final double fraction;
  final Color accent;
  final Color track;
  final bool active;
  final bool dragging;
  _KnobPainter({
    required this.fraction,
    required this.accent,
    required this.track,
    required this.active,
    required this.dragging,
  });

  static const _sweep = 3 * math.pi / 2; // 270 degrees
  static const _start = 3 * math.pi / 4; // 135 degrees

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 6;
    const stroke = 6.0;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawArc(rect, _start, _sweep, false, trackPaint);

    if (fraction > 0) {
      final fill = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = accent;
      if (active) {
        canvas.saveLayer(Offset.zero & size, Paint());
        canvas.drawArc(rect, _start, _sweep * fraction, false, fill);
        canvas.drawArc(
          rect,
          _start,
          _sweep * fraction,
          false,
          fill..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
        );
        canvas.restore();
      } else {
        canvas.drawArc(rect, _start, _sweep * fraction, false, fill);
      }
    }

    // knob body + pointer
    final bodyFill = Paint()
      ..color = accent.withValues(alpha: active ? 0.10 : 0.04);
    final bodyStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = accent.withValues(alpha: active ? 0.7 : 0.25);
    final bodyRadius = radius - stroke - 5;
    canvas.drawCircle(center, bodyRadius, bodyFill);
    canvas.drawCircle(center, bodyRadius, bodyStroke);
    final angle = _start + _sweep * fraction;
    final inner = Offset(
      center.dx + math.cos(angle) * bodyRadius * 0.2,
      center.dy + math.sin(angle) * bodyRadius * 0.2,
    );
    final outer = Offset(
      center.dx + math.cos(angle) * bodyRadius * 0.85,
      center.dy + math.sin(angle) * bodyRadius * 0.85,
    );
    canvas.drawLine(
      inner,
      outer,
      Paint()
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = accent.withValues(alpha: active ? (dragging ? 1.0 : 0.9) : 0.35),
    );
  }

  @override
  bool shouldRepaint(_KnobPainter old) =>
      old.fraction != fraction || old.active != active || old.dragging != dragging;
}
