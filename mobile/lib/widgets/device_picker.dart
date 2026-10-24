import '../localization.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../ble_link.dart';
import '../known_devices.dart';

class DevicePicker extends StatefulWidget {
  final BleConnector connector;
  final KnownDevices known;
  const DevicePicker({
    super.key,
    required this.connector,
    this.known = const KnownDevices(),
  });
  @override
  State<DevicePicker> createState() => _DevicePickerState();
}

class _DevicePickerState extends State<DevicePicker> {
  final _devices = <String, DiscoveredDevice>{};
  var _known = <PedalDevice>[];
  StreamSubscription<DiscoveredDevice>? _scan;
  StreamSubscription<BleStatus>? _status;
  Timer? _timer;
  String _error = '';
  bool _scanning = true, _poweredOff = false;
  @override
  void initState() {
    super.initState();
    unawaited(_loadKnown());
    unawaited(_watchAdapter());
  }

  Future<void> _loadKnown() async {
    final known = await widget.known.load();
    if (mounted) setState(() => _known = known);
  }

  /// Scans while the adapter is on; turning it off shows a warning instead,
  /// and turning it back on restarts the scan.
  Future<void> _watchAdapter() async {
    try {
      await widget.connector.authorize();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _scanning = false;
        });
      }
      return;
    }
    if (!mounted) return;
    _status = widget.connector.statusStream.listen((status) {
      if (!mounted) return;
      if (status == BleStatus.poweredOff) {
        _stopScan();
        setState(() {
          _poweredOff = true;
          _error = '';
        });
      } else if (status == BleStatus.ready && (_poweredOff || _scan == null)) {
        setState(() {
          _poweredOff = false;
          _error = '';
        });
        _start();
      }
    });
  }

  void _start() {
    setState(() => _scanning = true);
    _scan = widget.connector.scan().listen(
      (device) {
        if (mounted) setState(() => _devices[device.id] = device);
      },
      onError: (Object error) {
        if (mounted && !_poweredOff) {
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

  void _stopScan() {
    _timer?.cancel();
    unawaited(_scan?.cancel());
    _scanning = false;
  }

  Future<void> _enable() async {
    if (!await widget.connector.requestEnable() && mounted) {
      setState(() => _error = tr("Bluetoothの設定を開けませんでした。"));
    }
  }

  Future<void> _forget(PedalDevice device) async {
    await widget.known.forget(device.id);
    await _loadKnown();
  }

  Future<void> _pick(PedalDevice device) async {
    _stopScan();
    if (mounted) Navigator.pop(context, device);
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_scan?.cancel());
    unawaited(_status?.cancel());
    super.dispose();
  }

  String _name(String name) => name.isEmpty ? tr("名前のない機器") : name;

  Widget _knownTile(PedalDevice device) {
    final found = _devices[device.id];
    final name = found == null || found.name.isEmpty ? device.name : found.name;
    final where = found != null
        ? '${found.rssi} dBm'
        : _scanning
        ? tr("検索中")
        : tr("近くに見つかりません。タップすると接続を試みます。");
    return ListTile(
      leading: Icon(found != null ? Icons.bluetooth_connected : Icons.history),
      title: Text(_name(name)),
      subtitle: Text('${device.id}  ·  $where'),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        tooltip: tr("この機器を忘れる"),
        onPressed: () => _forget(device),
      ),
      onTap: _poweredOff ? null : () => _pick(PedalDevice(device.id, name)),
    );
  }

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Text(text, style: Theme.of(context).textTheme.labelLarge),
  );

  @override
  Widget build(BuildContext context) {
    final knownIds = {for (final d in _known) d.id};
    final others = [
      for (final d in _devices.values)
        if (!knownIds.contains(d.id)) d,
    ];
    return SafeArea(
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
              if (_poweredOff)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: ListTile(
                    leading: Icon(
                      Icons.bluetooth_disabled,
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                    title: Text(
                      tr("Bluetoothがオフになっています。オンにすると機器の検索を始めます。"),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                    trailing: widget.connector.canRequestEnable
                        ? FilledButton(
                            onPressed: _enable,
                            child: Text(tr("Bluetoothをオンにする")),
                          )
                        : null,
                  ),
                ),
              if (_scanning && !_poweredOff) const LinearProgressIndicator(),
              if (_error.isNotEmpty) Text(_error),
              if (!_scanning &&
                  !_poweredOff &&
                  _devices.isEmpty &&
                  _known.isEmpty)
                Text(tr("機器が見つかりません。Bluetoothと本体の電源を確認してください。")),
              Expanded(
                child: ListView(
                  children: [
                    if (_known.isNotEmpty) ...[
                      _header(tr("前回接続した機器")),
                      for (final device in _known) _knownTile(device),
                      if (others.isNotEmpty) _header(tr("その他の機器")),
                    ],
                    for (final device in others)
                      ListTile(
                        leading: const Icon(Icons.bluetooth),
                        title: Text(_name(device.name)),
                        subtitle: Text('${device.id}  ·  ${device.rssi} dBm'),
                        onTap: () => _pick(PedalDevice(device.id, device.name)),
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
}
