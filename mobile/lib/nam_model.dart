import 'localization.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'model_kind.dart';
import 'protocol.dart';

const kernels = [
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  15,
  15,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
];
const dilations = [
  1,
  3,
  7,
  17,
  41,
  101,
  239,
  1,
  3,
  7,
  17,
  41,
  101,
  239,
  1,
  13,
  1,
  3,
  7,
  17,
  41,
  101,
  239,
];
const weightCount = 1871, packetBytes = 7548;

void require(bool ok, String message) {
  if (!ok) throw FormatException(message);
}

Map<String, dynamic> object(Object? value) {
  require(value is Map<String, dynamic>, tr("モデルの構造が正しくありません。"));
  return value as Map<String, dynamic>;
}

bool sameList(Object? a, List<Object?> b) =>
    a is List &&
    a.length == b.length &&
    List.generate(b.length, (i) => a[i] == b[i]).every((v) => v);
bool finite(Object? value) => value is num && value.isFinite;

class NamModel {
  final String name;
  final Uint8List packet;
  NamModel(this.name, this.packet);

  /// Header byte 52 (firmware capability bit 12); older firmware needs 0.
  ModelKind get kind => ModelKind.fromCode(packet[52]);

  /// The same capture with another kind byte; weights and their CRC stay.
  NamModel withKind(ModelKind kind) {
    if (packet[52] == kind.code) return this;
    final copy = Uint8List.fromList(packet);
    copy[52] = kind.code;
    _seal(copy);
    return NamModel(name, copy);
  }

  static void _seal(Uint8List packet) => ByteData.sublistView(
    packet,
  ).setUint32(60, crc32(Uint8List.sublistView(packet, 0, 60)), Endian.little);

  factory NamModel.parse(Uint8List bytes, String filename) {
    require(bytes.length <= 8 * 1024 * 1024, tr("ファイルが大きすぎます（上限8 MB）。"));
    final document = object(jsonDecode(utf8.decode(bytes)));
    var model = document;
    if (document['architecture'] == 'SlimmableContainer') {
      final submodels = object(document['config'])['submodels'];
      require(submodels is List, tr("A2モデルの構造が正しくありません。"));
      final candidates = <Map<String, dynamic>>[];
      for (final entry in submodels as List) {
        final m = object(object(entry)['model']);
        final layers = object(m['config'])['layers'];
        if (m['architecture'] == 'WaveNet' &&
            layers is List &&
            layers.isNotEmpty &&
            object(layers.first)['channels'] == 3) {
          candidates.add(m);
        }
      }
      require(candidates.length == 1, tr("A2-Liteモデルを一意に選択できません。"));
      model = candidates.single;
    }
    require(
      model['architecture'] == 'WaveNet',
      tr("48 kHzのA2-Liteモデルを選んでください。"),
    );
    final rate = model.containsKey('sample_rate')
        ? model['sample_rate']
        : document['sample_rate'];
    require(rate == 48000 && finite(rate), tr("48 kHzのモデルが必要です。"));
    if (!identical(model, document) && document.containsKey('sample_rate')) {
      require(document['sample_rate'] == rate, tr("モデルのサンプルレートが一致しません。"));
    }
    final config = object(model['config']);
    require(
      config.keys.every(
        {
          'layers',
          'head',
          'head_scale',
          'in_channels',
          'condition_dsp',
        }.contains,
      ),
      tr("未対応のモデル設定が含まれています。"),
    );
    require(
      config['head'] == null &&
          config['condition_dsp'] == null &&
          (config['in_channels'] ?? 1) == 1 &&
          finite(config['head_scale']),
      tr("未対応のモデル構造です。"),
    );
    final layers = config['layers'];
    require(layers is List && layers.length == 1, tr("固定A2-Liteモデルが必要です。"));
    final layer = object((layers as List).single);
    const films = {
      'conv_pre_film',
      'conv_post_film',
      'input_mixin_pre_film',
      'input_mixin_post_film',
      'activation_pre_film',
      'activation_post_film',
      'layer1x1_post_film',
      'head1x1_post_film',
    };
    require(
      layer.keys.every(
        {
          ...films,
          'input_size',
          'condition_size',
          'channels',
          'bottleneck',
          'kernel_sizes',
          'dilations',
          'activation',
          'gating_mode',
          'gated',
          'secondary_activation',
          'head',
          'head1x1',
          'layer1x1',
          'groups_input',
          'groups_input_mixin',
          'slimmable',
        }.contains,
      ),
      tr("未対応のモデル設定が含まれています。"),
    );
    require(
      layer['input_size'] == 1 &&
          layer['condition_size'] == 1 &&
          layer['channels'] == 3 &&
          layer['bottleneck'] == 3 &&
          sameList(layer['kernel_sizes'], kernels) &&
          sameList(layer['dilations'], dilations),
      tr("3チャンネルの固定A2-Liteモデルが必要です。"),
    );
    final activation = layer['activation'];
    require(
      activation is List &&
          activation.length == 23 &&
          activation.every(
            (a) =>
                a is Map &&
                a.length == 2 &&
                a['type'] == 'LeakyReLU' &&
                a['negative_slope'] == 0.01,
          ),
      tr("未対応の活性化関数です。"),
    );
    require(
      (layer['gating_mode'] == null ||
              sameList(layer['gating_mode'], List.filled(23, 'none'))) &&
          (layer['gated'] ?? false) == false &&
          (layer['secondary_activation'] == null ||
              sameList(layer['secondary_activation'], List.filled(23, null))),
      tr("未対応のゲート構造です。"),
    );
    for (final key in {...films, 'head1x1'}) {
      final v = layer[key];
      require(
        v == null ||
            v == false ||
            (v is Map && (v['active'] ?? false) == false),
        tr("未対応のモデル機能です。"),
      );
    }
    final linear = object(layer['layer1x1']), head = object(layer['head']);
    require(
      linear['active'] == true &&
          (linear['groups'] ?? 1) == 1 &&
          linear.keys.every({'active', 'groups'}.contains),
      tr("未対応の残差構造です。"),
    );
    require(
      head['out_channels'] == 1 &&
          head['kernel_size'] == 16 &&
          head['bias'] == true &&
          (head['head_dilation'] ?? 1) == 1 &&
          head.keys.every(
            {'out_channels', 'kernel_size', 'bias', 'head_dilation'}.contains,
          ),
      tr("未対応の出力構造です。"),
    );
    require(
      (layer['groups_input'] ?? 1) == 1 &&
          (layer['groups_input_mixin'] ?? 1) == 1 &&
          layer['slimmable'] == null,
      tr("固定A2-Liteモデルが必要です。"),
    );
    final weights = model['weights'];
    require(
      weights is List && weights.length == weightCount,
      tr("モデルの重み数が一致しません。"),
    );
    final packet = Uint8List(packetBytes);
    final view = ByteData.sublistView(packet);
    for (var i = 0; i < weightCount; i++) {
      final w = (weights as List)[i];
      require(
        finite(w) && (w as num).abs() <= 3.402823466e38,
        tr("不正なモデル重みが含まれています。"),
      );
      view.setFloat32(64 + i * 4, (w as num).toDouble(), Endian.little);
    }
    final stem = filename.replaceAll(
      RegExp(r'\.nam$', caseSensitive: false),
      '',
    );
    final safe = stem.codeUnits
        .map((c) => c >= 33 && c <= 126 ? c : 95)
        .take(23)
        .toList();
    final name = safe.isEmpty ? 'NAM' : String.fromCharCodes(safe);
    view.setUint32(0, 0x4d4e4246, Endian.little);
    view.setUint16(4, 1, Endian.little);
    view.setUint16(6, 2, Endian.little);
    view.setUint32(8, 48000, Endian.little);
    view.setUint32(12, weightCount, Endian.little);
    view.setUint32(16, crc32(Uint8List.sublistView(packet, 64)), Endian.little);
    packet.setRange(24, 24 + name.length, name.codeUnits);
    final metadata = document['metadata'];
    final gear = metadata is Map ? metadata['gear_type'] : null;
    packet[52] = ModelKind.fromGear(gear is String ? gear : null).code;
    _seal(packet);
    return NamModel(name, packet);
  }
}
