import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fb200_nam/model_kind.dart';
import 'package:fb200_nam/nam_client.dart';
import 'package:fb200_nam/nam_model.dart';
import 'package:fb200_nam/protocol.dart';
import 'package:fb200_nam/studio_theme.dart';
import 'package:fb200_nam/tone3000.dart';
import 'package:fb200_nam/widgets/nam_model_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'studio_test.dart' show studio;
import 'support/studio_harness.dart';

/// Demo firmware without flags bit 12; records the uploaded packet.
class OldFirmware implements RpcTransport {
  final demo = DemoTransport();
  final uploaded = <int>[];
  final operations = <int>[];
  @override
  Future<Uint8List> request(int op, List<int> args) async {
    operations.add(op);
    if (op == 3) uploaded.addAll(args.sublist(6));
    final reply = await demo.request(op, args);
    if (op == 0) reply[11] &= ~(4096 >> 8);
    return reply;
  }

  @override
  Future<void> close() => demo.close();
}

Uint8List fixture({String? gear}) {
  final document = jsonDecode(
    File('test/fixtures/synthetic.nam').readAsStringSync(),
  ) as Map<String, dynamic>;
  if (gear != null) document['metadata'] = {'gear_type': gear};
  return Uint8List.fromList(utf8.encode(jsonEncode(document)));
}

bool sealed(List<int> packet) =>
    read32(packet, 60) == crc32(packet.sublist(0, 60));

Future<void> upload(NamClient client, int slot, NamModel model) =>
    client.upload(slot, model, progress: (_) {}, cancelled: () => false);

void main() {
  test(
    'kinds map TONE3000 gear and NAM metadata; unknown codes read as unknown',
    () {
      expect(ModelKind.fromGear('amp-cab'), ModelKind.fullRig);
      expect(ModelKind.fromGear('amp_pedal_cab'), ModelKind.fullRig);
      expect(ModelKind.fromGear('amp'), ModelKind.amp);
      expect(ModelKind.fromGear('preamp'), ModelKind.amp);
      expect(ModelKind.fromGear('cab'), ModelKind.cab);
      expect(ModelKind.fromGear('pedal'), ModelKind.pedal);
      expect(ModelKind.fromGear('studio'), ModelKind.outboard);
      expect(ModelKind.fromGear('experimental'), ModelKind.experimental);
      expect(ModelKind.fromGear(null), ModelKind.unknown);
      expect(ModelKind.fromCode(200), ModelKind.unknown);
      expect(ModelKind.fullRig.wantsCab, isFalse);
      expect(ModelKind.amp.wantsCab, isTrue);
      expect(ModelKind.pedal.wantsCab, isNull);
    },
  );

  test('the kind byte is header byte 52 and keeps the weights', () {
    final plain = NamModel.parse(fixture(), 'synthetic.nam');
    expect(plain.kind, ModelKind.unknown);
    expect(
      plain.packet,
      File('test/fixtures/synthetic.fbnm').readAsBytesSync(),
    );
    final rig = NamModel.parse(fixture(gear: 'amp_cab'), 'synthetic.nam');
    expect(rig.kind, ModelKind.fullRig);
    expect(rig.packet[52], 1);
    expect(sealed(rig.packet), isTrue);
    final amp = rig.withKind(ModelKind.amp);
    expect(amp.packet[52], 2);
    expect(sealed(amp.packet), isTrue);
    expect(amp.packet.sublist(0, 52), rig.packet.sublist(0, 52));
    expect(amp.packet.sublist(64), rig.packet.sublist(64));
    expect(rig.packet[52], 1, reason: 'withKind copies');
    expect(amp.withKind(ModelKind.unknown).packet, plain.packet);
  });

  test('a TONE3000 import takes its kind from the tone gear', () {
    TonePack tone(String gear) => TonePack(
      id: 1,
      title: 'Rig',
      gear: gear,
      creator: ToneCreator('someone', null),
      image: null,
    );
    final model = ToneModel(2, 1, 'Rig A2', Uri.parse('/api/v1/models/2'));
    final bytes = fixture(gear: 'pedal');
    expect(
      Tone3000Api.importBytes(tone('amp-cab'), model, bytes).model.kind,
      ModelKind.fullRig,
    );
    // Without a known gear the file's metadata decides.
    expect(
      Tone3000Api.importBytes(tone(''), model, bytes).model.kind,
      ModelKind.pedal,
    );
  });

  test('the client lists, uploads and changes kinds', () async {
    final client = NamClient(DemoTransport());
    await client.handshake();
    expect(client.canStoreKind, isTrue);
    var state = await client.readState();
    expect(state.slots.map((s) => s.kind), [
      ModelKind.fullRig,
      ModelKind.amp,
      ModelKind.unknown,
    ]);
    final model = NamModel.parse(fixture(gear: 'pedal'), 'fuzz.nam');
    await upload(client, 3, model);
    state = await client.readState();
    expect(state.slots[2].kind, ModelKind.pedal);
    await client.setKind(3, ModelKind.cab);
    state = await client.readState();
    expect(state.slots[2].kind, ModelKind.cab);
    expect(state.slots[2].name, 'fuzz');
  });

  test('older firmware gets kind 0 and no kind requests', () async {
    final transport = OldFirmware();
    final client = NamClient(transport);
    await client.handshake();
    expect(client.canStoreKind, isFalse);
    final model = NamModel.parse(fixture(gear: 'amp_cab'), 'rig.nam');
    await upload(client, 3, model);
    expect(transport.uploaded[52], 0);
    expect(sealed(transport.uploaded), isTrue);
    final state = await client.readState();
    expect(state.slots.every((s) => s.kind == ModelKind.unknown), isTrue);
    expect(transport.operations, isNot(contains(11)));
    await expectLater(
      client.setKind(1, ModelKind.amp),
      throwsA(isA<DeviceError>()),
    );
    expect(transport.operations, isNot(contains(12)));
  });

  testWidgets('the loaded model shows its kind and a doubled cabinet', (
    tester,
  ) async {
    final h = StudioHarness()..kinds[1] = ModelKind.fullRig.code;
    h.addFlags(4096);
    await tester.pumpWidget(studio(h));
    await tester.pumpAndSettle();
    expect(find.text('Amp + Cab'), findsOneWidget);
    // The harness preset runs the cabinet, which a full rig already has.
    expect(find.text('キャビ込みのモデルに、キャビネット/IRが重なっています'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nam-model-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('model-kind-amp')));
    await tester.pumpAndSettle();
    expect(h.kindWrites, [
      [1, ModelKind.amp.code],
    ]);
    expect(find.text('Amp'), findsOneWidget);
    expect(find.text('キャビ込みのモデルに、キャビネット/IRが重なっています'), findsNothing);
    expect(find.text('アンプのみのモデルです。キャビネット/IRをオンにしてください'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
  });

  testWidgets('older firmware shows no kind badge', (tester) async {
    final h = StudioHarness()..kinds[1] = ModelKind.fullRig.code;
    await tester.pumpWidget(studio(h));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nam-model-kind')), findsNothing);
    expect(find.text('Amp + Cab'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
  });

  testWidgets('the model picker labels and filters by kind', (tester) async {
    final state = DeviceState(1, [
      const ModelSlot(1, 'Plexi Rig', 0, ModelKind.fullRig),
      const ModelSlot(2, 'Plexi Head', 0, ModelKind.amp),
      const ModelSlot(3, 'Klone', 0, ModelKind.pedal),
      const ModelSlot(4, null),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: StudioTheme.theme,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => pickNamModel(context, state),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Pedal'), findsNWidgets(2)); // badge and filter
    await tester.tap(find.byKey(const ValueKey('nam-kind-filter-amp')));
    await tester.pumpAndSettle();
    expect(find.text('Plexi Head'), findsOneWidget);
    expect(find.text('Plexi Rig'), findsNothing);
    expect(find.text('Klone'), findsNothing);
    expect(find.text('BYPASS'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nam-kind-filter-all')));
    await tester.enterText(
      find.byKey(const ValueKey('nam-model-search')),
      'pedal',
    );
    await tester.pumpAndSettle();
    expect(find.text('Klone'), findsOneWidget);
    expect(find.text('Plexi Head'), findsNothing);
  });
}
