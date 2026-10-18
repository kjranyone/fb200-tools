/// A discovered GATT endpoint, retaining its platform handle.
class BleEndpoint<T> {
  final T handle;
  final String service, characteristic;
  final bool writable, notifiable;
  const BleEndpoint({
    required this.handle,
    required this.service,
    required this.characteristic,
    required this.writable,
    required this.notifiable,
  });
}

/// BT201 UART route measured on the FB200. FFF3 controls the Bluetooth module
/// itself and must never be probed with pedal protocol frames.
({T writer, T reader})? selectFb200Uart<T>(Iterable<BleEndpoint<T>> endpoints) {
  const service = '0000fff0-0000-1000-8000-00805f9b34fb';
  const tx = '0000fff1-0000-1000-8000-00805f9b34fb';
  const rx = '0000fff2-0000-1000-8000-00805f9b34fb';
  final uart = endpoints.where((e) => e.service.toLowerCase() == service);
  final writers = uart.where(
    (e) => e.characteristic.toLowerCase() == tx && e.writable,
  );
  final readers = uart.where(
    (e) => e.characteristic.toLowerCase() == rx && e.notifiable,
  );
  if (writers.length != 1 || readers.length != 1) return null;
  return (writer: writers.single.handle, reader: readers.single.handle);
}
