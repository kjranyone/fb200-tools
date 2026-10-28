import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

/// A neighbouring module that a swipe would move to.
typedef SwipeTarget = ({String label, IconData icon, Color color});

/// The module card follows a sideways drag on its empty space and reveals
/// the neighbour it would move to; past the threshold the hint lights up and
/// a release commits. Knobs claim their pointer on touch, so they keep it.
class ModuleSwipe extends StatefulWidget {
  final Widget child;
  final SwipeTarget? previous, next;
  final bool enabled;

  /// +1 for the next module, -1 for the previous one.
  final ValueChanged<int> onStep;

  const ModuleSwipe({
    super.key,
    required this.child,
    required this.onStep,
    this.previous,
    this.next,
    this.enabled = true,
  });

  @override
  State<ModuleSwipe> createState() => _ModuleSwipeState();
}

class _ModuleSwipeState extends State<ModuleSwipe>
    with SingleTickerProviderStateMixin {
  /// The card's horizontal offset.
  late final _offset = AnimationController.unbounded(vsync: this);

  /// The finger's travel; [_offset] lags it where there is no neighbour.
  double _travel = 0;
  bool _armed = false, _settling = false;

  /// The card's width at the last layout.
  double _width = 360;
  double get _threshold => (_width * .2).clamp(56.0, 96.0);
  bool get _still => MediaQuery.disableAnimationsOf(context);

  SwipeTarget? _towards(double dx) => dx < 0 ? widget.next : widget.previous;

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  void _start(DragStartDetails _) {
    if (_settling) return;
    _offset.stop();
    _travel = _offset.value;
  }

  void _update(DragUpdateDetails d) {
    if (_settling) return;
    _travel += d.primaryDelta ?? 0;
    final open = _towards(_travel) != null;
    // The chain's ends give a little and then hold.
    _offset.value = open ? _travel : _travel * .25;
    final armed = open && _travel.abs() >= _threshold;
    if (armed != _armed) {
      setState(() => _armed = armed);
      if (armed) HapticFeedback.selectionClick();
    }
  }

  Future<void> _end(DragEndDetails d) async {
    if (_settling) return;
    final velocity = d.primaryVelocity ?? 0;
    // A fling commits in its own direction, a slow release only when armed.
    final fling = velocity.abs() >= 400 && velocity.sign == _travel.sign;
    final step = _travel < 0 ? 1 : -1;
    final commit =
        widget.enabled && _towards(_travel) != null && (_armed || fling);
    setState(() => _armed = false);
    _travel = 0;
    if (!commit) {
      await _settle(0, const Duration(milliseconds: 240), Curves.easeOutBack);
      return;
    }
    _settling = true;
    try {
      await _settle(
        -step * _width,
        const Duration(milliseconds: 140),
        Curves.easeIn,
      );
      if (!mounted) return;
      widget.onStep(step);
      // The new module comes in from the side the finger pulled it from.
      _offset.value = step * _width * .3;
      await _settle(0, const Duration(milliseconds: 220), Curves.easeOutCubic);
    } finally {
      _settling = false;
    }
  }

  Future<void> _settle(double to, Duration duration, Curve curve) async {
    if (!mounted) return;
    if (_still) {
      _offset.value = to;
      return;
    }
    await _offset.animateTo(to, duration: duration, curve: curve);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (box.hasBoundedWidth) _width = box.maxWidth;
      return _swipeable();
    },
  );

  Widget _swipeable() => ClipRect(
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: widget.enabled ? _start : null,
      onHorizontalDragUpdate: widget.enabled ? _update : null,
      onHorizontalDragEnd: widget.enabled ? _end : null,
      child: AnimatedBuilder(
        animation: _offset,
        builder: (context, child) {
          final dx = _offset.value;
          final target = dx == 0 ? null : _towards(dx);
          return Stack(
            children: [
              if (target != null)
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: dx > 0 ? 0 : null,
                  right: dx < 0 ? 0 : null,
                  width: _threshold,
                  child: _Hint(
                    key: ValueKey(dx < 0 ? 'swipe-next' : 'swipe-previous'),
                    target: target,
                    forward: dx < 0,
                    progress: (dx.abs() / _threshold).clamp(0.0, 1.0),
                    armed: _armed || _settling,
                  ),
                ),
              Transform.translate(offset: Offset(dx, 0), child: child),
            ],
          );
        },
        child: widget.child,
      ),
    ),
  );
}

/// The neighbour behind the card: faint while pulling, filled when a
/// release would move to it.
class _Hint extends StatelessWidget {
  final SwipeTarget target;
  final bool forward, armed;
  final double progress;

  const _Hint({
    super.key,
    required this.target,
    required this.forward,
    required this.progress,
    required this.armed,
  });

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: armed ? 1 : .25 + progress * .5,
    child: Center(
      child: AnimatedScale(
        scale: armed ? 1 : .85,
        duration: const Duration(milliseconds: 120),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: armed
                    ? target.color.withValues(alpha: .22)
                    : Colors.transparent,
                border: Border.all(color: target.color, width: armed ? 2 : 1),
              ),
              child: Icon(target.icon, size: 20, color: target.color),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!forward)
                  Icon(Icons.chevron_left, size: 14, color: target.color),
                Text(
                  target.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .5,
                    color: target.color,
                  ),
                ),
                if (forward)
                  Icon(Icons.chevron_right, size: 14, color: target.color),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
