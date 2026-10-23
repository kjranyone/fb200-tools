import 'localization.dart';

import 'package:flutter/material.dart';

/// What a capture is: header byte 52 of a stored model (firmware
/// namstore.h, capability bit 12). Codes are stable; unknown codes read as
/// [unknown].
enum ModelKind {
  unknown(0),
  fullRig(1),
  amp(2),
  cab(3),
  pedal(4),
  outboard(5),
  space(6),
  experimental(7);

  final int code;
  const ModelKind(this.code);

  static ModelKind fromCode(int code) =>
      values.firstWhere((k) => k.code == code, orElse: () => ModelKind.unknown);

  /// TONE3000 gear ids and the NAM trainer's metadata `gear_type`.
  static ModelKind fromGear(String? gear) => switch (gear) {
    'amp-cab' || 'full-rig' || 'amp_cab' || 'amp_pedal_cab' => fullRig,
    'amp' || 'pedal_amp' || 'preamp' => amp,
    'cab' || 'ir' => cab,
    'pedal' => pedal,
    'outboard' || 'studio' => outboard,
    'space' => space,
    'experimental' => experimental,
    _ => unknown,
  };

  String get label => switch (this) {
    unknown => tr("種類未設定"),
    fullRig => 'Amp + Cab',
    amp => 'Amp',
    cab => 'Cab',
    pedal => 'Pedal',
    outboard => 'Outboard',
    space => 'Space',
    experimental => 'Experimental',
  };

  /// How it fits the pedal's chain (NAM, then cabinet / IR).
  String get hint => switch (this) {
    unknown => tr("種類を設定すると、キャビネットの要否を表示します"),
    fullRig => tr("キャビ込みの音 · キャビネット/IRはオフ"),
    amp => tr("アンプのみ · キャビネット/IRと組み合わせ"),
    cab => tr("キャビのみ · 前段のアンプがないため単体では不完全"),
    pedal => tr("ペダルのみ · 後段のアンプがないため単体では不完全"),
    outboard => tr("スタジオ機材 · キャビネットの要否は機材次第"),
    space => tr("空間系のキャプチャ"),
    experimental => tr("実験的なキャプチャ"),
  };

  /// Whether the cabinet / IR stage should run after it; null when the
  /// kind does not say.
  bool? get wantsCab => switch (this) {
    fullRig => false,
    amp => true,
    _ => null,
  };

  Color get color => switch (this) {
    unknown => const Color(0xff9daaba),
    fullRig => const Color(0xff74e5bd),
    amp => const Color(0xffe4bd69),
    cab => const Color(0xff8fb8ff),
    pedal => const Color(0xffff9f6b),
    outboard => const Color(0xffc9a7ff),
    space => const Color(0xff6bd6ff),
    experimental => const Color(0xffff7ab8),
  };
}

/// A small outlined kind label; tappable when [onTap] is set.
class ModelKindBadge extends StatelessWidget {
  final ModelKind kind;
  final VoidCallback? onTap;
  const ModelKindBadge(this.kind, {super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: kind.color.withValues(alpha: .7)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Narrow cards shorten the label rather than overflow.
          Flexible(
            child: Text(
              kind.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: kind.color,
              ),
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 2),
            Icon(Icons.edit, size: 11, color: kind.color),
          ],
        ],
      ),
    );
    return Tooltip(
      message: kind.hint,
      child: onTap == null
          ? badge
          : InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: onTap,
              child: badge,
            ),
    );
  }
}

/// Asks for a kind; null on dismissal.
Future<ModelKind?> pickModelKind(
  BuildContext context,
  ModelKind current, {
  String? modelName,
}) => showDialog<ModelKind>(
  context: context,
  builder: (context) => SimpleDialog(
    title: Text(modelName == null ? tr("モデルの種類") : tr("「{0}」の種類", [modelName])),
    children: [
      for (final kind in ModelKind.values)
        ListTile(
          key: ValueKey('model-kind-${kind.name}'),
          leading: Icon(
            kind == current
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            color: kind.color,
          ),
          title: Text(kind.label),
          subtitle: Text(kind.hint),
          onTap: () => Navigator.pop(context, kind),
        ),
    ],
  ),
);
