import '../localization.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../ble_link.dart';

class DevicePicker extends StatefulWidget {
  final BleConnector connector;
  const DevicePicker({super.key, required this.connector});
  @override
  State<DevicePicker> createState() => _DevicePickerState();
}

class _DevicePickerState extends State<DevicePicker> {
  final _devices = <String, DiscoveredDevice>{};
  StreamSubscription<DiscoveredDevice>? _scan;
  Timer? _timer;
  String _error = '';
  bool _scanning = true;
  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _scan = widget.connector.scan().listen(
      (device) {
        if (mounted) setState(() => _devices[device.id] = device);
      },
      onError: (Object error) {
        if (mounted) {
          setState(() {
            _error = error.toString();
            _scanning = false;
          });
        }
      },
    );
    _timer = Timer(const Duration(seconds: 15), () {
      unawaited(_scan?.cancel());
      if (mounted) setState(() => _scanning = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_scan?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .7,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr("近くのBluetooth機器"),
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(tr("FB200を選んでください。名前は本体のBluetooth設定により異なります。")),
            const SizedBox(height: 16),
            if (_scanning) const LinearProgressIndicator(),
            if (_error.isNotEmpty) Text(_error),
            if (!_scanning && _devices.isEmpty)
              Text(tr("機器が見つかりません。Bluetoothと本体の電源を確認してください。")),
            Expanded(
              child: ListView(
                children: [
                  for (final device in _devices.values)
                    ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(
                        device.name.isEmpty ? tr("名前のない機器") : device.name,
                      ),
                      subtitle: Text('${device.id}  ·  ${device.rssi} dBm'),
                      onTap: () async {
                        await _scan?.cancel();
                        if (context.mounted) Navigator.pop(context, device);
                      },
                    ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr("閉じる")),
            ),
          ],
        ),
      ),
    ),
  );
}
