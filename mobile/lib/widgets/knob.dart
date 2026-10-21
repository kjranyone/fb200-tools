import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show
        Drag,
        DragEndDetails,
        DragUpdateDetails,
        ImmediateMultiDragGestureRecognizer;
import 'package:flutter/material.dart';

/// Drag vertically to adjust; move sideways for finer control, release
/// to commit. Values are accumulated as doubles so small movements are retained. A flat 270° arc and a numeric entry show the current value.
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
  final int? defaultValue;
  final String Function(int)? format;
  final ValueChanged<int> onChanged; // committed on release
  final bool enabled;
  final Color? accent;
  final double? size;

  const Knob({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 1,
    this.defaultValue,
    this.format,
    this.enabled = true,
    this.accent,
    this.size,
  });

  @override
  State<Knob> createState() => _KnobState();
}

class _KnobState extends State<Knob> {
  final _dialKey = GlobalKey();
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
    _knobSize = widget.size ?? (h < 480 ? 56 : (h < 640 ? 66 : 76));
  }

  @override
  void didUpdateWidget(Knob old) {
    super.didUpdateWidget(old);
    if (widget.size != old.size) {
      final h = MediaQuery.sizeOf(context).height;
      _knobSize = widget.size ?? (h < 480 ? 56 : (h < 640 ? 66 : 76));
    }
    if (!_dragging) _draft = widget.value;
  }

  double get _fraction => (widget.max == widget.min)
      ? 0
      : (_draft - widget.min) / (widget.max - widget.min);

  Offset? _lastPosition;
  Offset _dragOrigin = Offset.zero;
  double _precise = 0;

  void _updateFromPosition(Offset local) {
    final last = _lastPosition;
    _lastPosition = local;
    if (last == null) return;
    final fine = (local.dx - _dragOrigin.dx).abs() >= 80 ? .25 : 1.0;
    _precise =
        (_precise -
                (local.dy - last.dy) * (widget.max - widget.min) / 200 * fine)
            .clamp(widget.min.toDouble(), widget.max.toDouble());
    final value =
        (widget.min +
                ((_precise - widget.min) / widget.step).round() * widget.step)
            .clamp(widget.min, widget.max);
    if (value != _draft) setState(() => _draft = value);
  }

  Future<void> _enterValue() async {
    final controller = TextEditingController(text: '$_draft');
    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) {
          final parsed = int.tryParse(controller.text);
          final valid =
              parsed != null && parsed >= widget.min && parsed <= widget.max;
          return AlertDialog(
            title: Text(widget.label),
            content: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              decoration: InputDecoration(
                labelText: '${widget.min}–${widget.max}',
                helperText: widget.format == null
                    ? 'プリセット値を直接入力'
                    : '表示：${valid ? widget.format!(parsed) : '—'}',
                errorText: valid
                    ? null
                    : '${widget.min}〜${widget.max}の整数を入力してください',
              ),
              onChanged: (_) => setDialog(() {}),
              onSubmitted: (text) {
                final value = int.tryParse(text);
                if (value != null &&
                    value >= widget.min &&
                    value <= widget.max) {
                  Navigator.pop(context, value);
                }
              },
            ),
            actions: [
              if (widget.defaultValue != null)
                TextButton(
                  onPressed: () => Navigator.pop(context, widget.defaultValue),
                  child: const Text('標準に戻す'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: !valid
                    ? null
                    : () {
                        final value = int.tryParse(controller.text);
                        if (value != null &&
                            value >= widget.min &&
                            value <= widget.max) {
                          Navigator.pop(context, value);
                        }
                      },
                child: const Text('適用'),
              ),
            ],
          );
        },
      ),
    );
    // Keep the controller alive for the dialog's outgoing animation.
    Future<void>.delayed(const Duration(milliseconds: 500), controller.dispose);
    if (!mounted || !widget.enabled || result == null) return;
    final value =
        (widget.min +
                ((result - widget.min) / widget.step).round() * widget.step)
            .clamp(widget.min, widget.max);
    setState(() => _draft = value);
    if (value != widget.value) widget.onChanged(value);
  }

  Drag? _startDrag(Offset position) {
    if (!widget.enabled) return null;
    // MultiDrag's Drag.update only fills globalPosition (localPosition
    // defaults to it), so convert through this render box before tracking.
    final box = _dialKey.currentContext?.findRenderObject() as RenderBox?;
    Offset toLocal(Offset global) =>
        box == null ? global : box.globalToLocal(global);
    _lastPosition = _dragOrigin = toLocal(position);
    _precise = _draft.toDouble();
    setState(() => _dragging = true);
    return _KnobDrag(
      onMove: (details) {
        if (!mounted) return;
        _updateFromPosition(toLocal(details.globalPosition));
      },
      onDone: () {
        if (!mounted) return;
        _lastPosition = null;
        setState(() => _dragging = false);
        if (widget.enabled && _draft != widget.value) widget.onChanged(_draft);
      },
      onCancel: () {
        if (!mounted) return;
        _lastPosition = null;
        setState(() {
          _dragging = false;
          _draft = widget.value;
        });
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
          increasedValue:
              widget.format?.call(
                (_draft + widget.step).clamp(widget.min, widget.max),
              ) ??
              '${(_draft + widget.step).clamp(widget.min, widget.max)}',
          decreasedValue:
              widget.format?.call(
                (_draft - widget.step).clamp(widget.min, widget.max),
              ) ??
              '${(_draft - widget.step).clamp(widget.min, widget.max)}',
          enabled: widget.enabled,
          onIncrease: widget.enabled
              ? () => widget.onChanged(
                  (_draft + widget.step).clamp(widget.min, widget.max),
                )
              : null,
          onDecrease: widget.enabled
              ? () => widget.onChanged(
                  (_draft - widget.step).clamp(widget.min, widget.max),
                )
              : null,
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            gestures: {
              ImmediateMultiDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    ImmediateMultiDragGestureRecognizer
                  >(() => ImmediateMultiDragGestureRecognizer(), (
                    ImmediateMultiDragGestureRecognizer instance,
                  ) {
                    instance.onStart = _startDrag;
                  }),
            },
            child: SizedBox(
              key: _dialKey,
              width: _knobSize,
              height: _knobSize,
              child: CustomPaint(
                painter: _KnobPainter(
                  fraction: _fraction,
                  accent: widget.enabled
                      ? widget.accent ?? scheme.primary
                      : scheme.outline,
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
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            color: widget.enabled ? scheme.onSurfaceVariant : scheme.outline,
          ),
        ),
        InkWell(
          onTap: widget.enabled ? _enterValue : null,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Text(
              _text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: widget.enabled
                    ? (active
                          ? widget.accent ?? scheme.primary
                          : scheme.onSurface)
                    : scheme.outline,
              ),
            ),
          ),
        ),
      ],
    );
  }

  String get _text => widget.format?.call(_draft) ?? _draft.toString();
}

class _KnobDrag extends Drag {
  _KnobDrag({
    required this.onMove,
    required this.onDone,
    required this.onCancel,
  });
  final void Function(DragUpdateDetails) onMove;
  final void Function() onDone;
  final VoidCallback onCancel;

  @override
  void update(DragUpdateDetails details) => onMove(details);

  @override
  void end(DragEndDetails details) => onDone();

  @override
  void cancel() => onCancel();
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

    final angle = _start + _sweep * fraction;
    if (fraction > 0) {
      canvas.drawArc(
        rect,
        _start,
        _sweep * fraction,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..color = accent.withValues(alpha: active ? 1 : .45),
      );
    }
    canvas.drawCircle(
      Offset(
        center.dx + math.cos(angle) * radius,
        center.dy + math.sin(angle) * radius,
      ),
      dragging ? 5 : 4,
      Paint()..color = active ? const Color(0xffe7eef7) : accent,
    );
  }

  @override
  bool shouldRepaint(_KnobPainter old) =>
      old.fraction != fraction ||
      old.active != active ||
      old.dragging != dragging ||
      old.accent != accent ||
      old.track != track;
}
