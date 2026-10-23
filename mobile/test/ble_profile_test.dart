import 'package:fb200_nam/ble_profile.dart';
import 'package:flutter_test/flutter_test.dart';

String uuid(String short) => '0000$short-0000-1000-8000-00805f9b34fb';

BleEndpoint<String> endpoint(
  String characteristic, {
  String service = 'fff0',
  bool writable = false,
  bool notifiable = false,
}) => BleEndpoint(
  handle: '$service/$characteristic',
  service: uuid(service),
  characteristic: uuid(characteristic),
  writable: writable,
  notifiable: notifiable,
);

void main() {
  final measured = [
    endpoint('fff1', writable: true, notifiable: true),
    endpoint('fff2', notifiable: true),
    endpoint('fff3', writable: true),
  ];

  test('measured FB200 inventory selects UART, excluding module control', () {
    expect(selectFb200Uart(measured.reversed), (
      writer: 'fff0/fff1',
      reader: 'fff0/fff2',
    ));
  });

  test('FFF1 notifications cannot substitute for FFF2', () {
    expect(selectFb200Uart([measured.first, measured.last]), isNull);
  });

  test('FFF3 cannot substitute for the UART writer', () {
    expect(selectFb200Uart(measured.skip(1)), isNull);
  });

  test('refuses unrelated service even with matching characteristic IDs', () {
    expect(
      selectFb200Uart([
        endpoint('fff1', service: '1234', writable: true),
        endpoint('fff2', service: '1234', notifiable: true),
      ]),
      isNull,
    );
  });

  test('requires UART properties and unambiguous instances', () {
    expect(selectFb200Uart([endpoint('fff1'), measured[1]]), isNull);
    expect(selectFb200Uart([measured[0], endpoint('fff2')]), isNull);
    expect(selectFb200Uart([...measured, measured.first]), isNull);
    expect(selectFb200Uart([...measured, measured[1]]), isNull);
  });

  test('UUID comparison accepts uppercase platform values', () {
    expect(
      selectFb200Uart([
        for (final e in measured)
          BleEndpoint(
            handle: e.handle,
            service: e.service.toUpperCase(),
            characteristic: e.characteristic.toUpperCase(),
            writable: e.writable,
            notifiable: e.notifiable,
          ),
      ])?.reader,
      'fff0/fff2',
    );
  });
}
