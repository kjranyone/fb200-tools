import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fb200_nam/nam_model.dart';
import 'package:fb200_nam/protocol.dart';

Map<String, dynamic> sample() =>
    jsonDecode(File('test/fixtures/synthetic.nam').readAsStringSync())
        as Map<String, dynamic>;
NamModel parse(Map<String, dynamic> value) => NamModel.parse(
  Uint8List.fromList(utf8.encode(jsonEncode(value))),
  'synthetic.nam',
);
void main() {
  test(
    'Python and Dart produce byte-identical FBNM, including float32 and CRCs',
    () {
      final model = parse(sample());
      expect(model.name, 'synthetic');
      expect(
        model.packet,
        File('test/fixtures/synthetic.fbnm').readAsBytesSync(),
      );
      expect(model.packet.length, packetBytes);
      expect(read32(model.packet, 16), crc32(model.packet.sublist(64)));
      expect(read32(model.packet, 60), crc32(model.packet.sublist(0, 60)));
    },
  );
  test('packed A2 container extracts only the unique 3-channel model and inherits rate', () {
    final m = sample()..remove('sample_rate');
    expect(
      parse({
        'architecture': 'SlimmableContainer',
        'sample_rate': 48000,
        'config': {
          'submodels': [
            {'model': m},
          ],
        },
      }).packet,
      parse(sample()).packet,
    );
    expect(
      () => parse({
        'architecture': 'SlimmableContainer',
        'sample_rate': 48000,
        'config': {
          'submodels': [
            {'model': m},
            {'model': m},
          ],
        },
      }),
      throwsFormatException,
    );
    m['sample_rate'] = 44100;
    expect(
      () => parse({
        'architecture': 'SlimmableContainer',
        'sample_rate': 48000,
        'config': {
          'submodels': [
            {'model': m},
          ],
        },
      }),
      throwsFormatException,
    );
  });
  final invalid = <String, void Function(Map<String, dynamic>)>{
    'wrong rate': (m) => m['sample_rate'] = 44100,
    'missing rate': (m) => m.remove('sample_rate'),
    'wrong architecture': (m) => m['architecture'] = 'LSTM',
    'wrong count': (m) => (m['weights'] as List).removeLast(),
    'oversized float': (m) => m['weights'][0] = 1e100,
    'non-number weight': (m) => m['weights'][0] = true,
    'unknown config': (m) => m['config']['new_feature'] = true,
    'wrong shape': (m) => m['config']['layers'][0]['channels'] = 4,
    'wrong kernel': (m) => m['config']['layers'][0]['kernel_sizes'][0] = 3,
    'wrong activation': (m) =>
        m['config']['layers'][0]['activation'][0]['type'] = 'Tanh',
    'gating': (m) => m['config']['layers'][0]['gated'] = true,
    'FiLM': (m) => m['config']['layers'][0]['conv_pre_film'] = {'active': true},
    'wrong head': (m) => m['config']['layers'][0]['head']['kernel_size'] = 1,
    'grouped residual': (m) =>
        m['config']['layers'][0]['layer1x1']['groups'] = 3,
  };
  for (final entry in invalid.entries) {
    test('rejects ${entry.key} before any connection or transfer', () {
      final m = sample();
      entry.value(m);
      expect(() => parse(m), throwsFormatException);
    });
  }
  test('bounds file size, malformed JSON, filename length and Unicode', () {
    expect(
      () => NamModel.parse(Uint8List(8 * 1024 * 1024 + 1), 'x.nam'),
      throwsFormatException,
    );
    expect(
      () => NamModel.parse(Uint8List.fromList([0xff]), 'x.nam'),
      throwsFormatException,
    );
    final data = File('test/fixtures/synthetic.nam').readAsBytesSync();
    final m = NamModel.parse(data, '日本語 too long 12345678901234567890.NAM');
    expect(m.name.length, 23);
    expect(m.name.startsWith('____too_long'), isTrue);
    expect(m.packet[47], 0);
  });
}
