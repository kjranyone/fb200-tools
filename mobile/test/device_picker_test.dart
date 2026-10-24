import 'dart:async';
import 'dart:typed_data';

import 'package:fb200_nam/ble_link.dart';
import 'package:fb200_nam/known_devices.dart';
import 'package:fb200_nam/widgets/device_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeConnector extends BleConnector {
  final status = StreamController<BleStatus>.broadcast();
  final found = StreamController<DiscoveredDevice>.broadcast();
  int scans = 0, enableRequests = 0;

  @override
  Future<void> authorize() async {}
  @override
  Stream<BleStatus> get statusStream => status.stream;
  @override
  bool get canRequestEnable => true;
  @override
  Future<bool> requestEnable() async {
    enableRequests++;
    return true;
  }

  @override
  Stream<DiscoveredDevice> scan() {
    scans++;
    return found.stream;
  }
}

DiscoveredDevice discovered(String id, String name) => DiscoveredDevice(
  id: id,
  name: name,
  serviceData: const {},
  manufacturerData: Uint8List(0),
  rssi: -50,
  serviceUuids: const [],
);

/// Opens the picker in a bottom sheet, as ModelPage does.
Future<void> openPicker(
  WidgetTester tester,
  FakeConnector connector, [
  void Function(PedalDevice?)? onPicked,
]) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final picked = await showModalBottomSheet<PedalDevice>(
              context: context,
              isScrollControlled: true,
              builder: (_) => DevicePicker(connector: connector),
            );
            onPicked?.call(picked);
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  // The sheet shows a progress bar until the adapter state arrives.
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  test(
    'known devices keep the most recent first, without duplicates',
    () async {
      const store = KnownDevices();
      await store.remember(const PedalDevice('A', 'FB200'));
      await store.remember(const PedalDevice('B', 'Other'));
      await store.remember(const PedalDevice('A', 'FB200 renamed'));
      expect(
        [for (final d in await store.load()) '${d.id}:${d.name}'],
        ['A:FB200 renamed', 'B:Other'],
      );
      await store.forget('A');
      expect([for (final d in await store.load()) d.id], ['B']);
    },
  );

  test('corrupt stored data loads as no known devices', () async {
    SharedPreferences.setMockInitialValues({KnownDevices.key: '{oops'});
    expect(await const KnownDevices().load(), isEmpty);
  });

  testWidgets('Bluetooth off shows a warning, turning it on starts the scan', (
    tester,
  ) async {
    final connector = FakeConnector();
    await openPicker(tester, connector);
    connector.status.add(BleStatus.poweredOff);
    await tester.pump();
    expect(find.text('Bluetoothがオフになっています。オンにすると機器の検索を始めます。'), findsOneWidget);
    expect(connector.scans, 0);

    await tester.tap(find.text('Bluetoothをオンにする'));
    await tester.pump();
    expect(connector.enableRequests, 1);

    connector.status.add(BleStatus.ready);
    await tester.pump();
    expect(find.text('Bluetoothがオフになっています。オンにすると機器の検索を始めます。'), findsNothing);
    expect(connector.scans, 1);
    await tester.pump(const Duration(seconds: 16));
  });

  testWidgets('a remembered device is listed first and can be picked unseen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      KnownDevices.key: '[{"id":"AA:BB","name":"My FB200"}]',
    });
    final connector = FakeConnector();
    PedalDevice? picked;
    await openPicker(tester, connector, (d) => picked = d);
    connector.status.add(BleStatus.ready);
    await tester.pump();
    connector.found.add(discovered('CC:DD', 'Speaker'));
    await tester.pump();

    expect(find.text('前回接続した機器'), findsOneWidget);
    expect(find.text('その他の機器'), findsOneWidget);
    final mine = tester.getTopLeft(find.text('My FB200')).dy;
    final other = tester.getTopLeft(find.text('Speaker')).dy;
    expect(mine, lessThan(other));

    await tester.tap(find.text('My FB200'));
    await tester.pumpAndSettle();
    expect(picked?.id, 'AA:BB');
    expect(picked?.name, 'My FB200');
  });
}
