import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A Bluetooth device the picker can return or the app has connected to.
class PedalDevice {
  final String id, name;
  const PedalDevice(this.id, this.name);

  Map<String, String> toJson() => {'id': id, 'name': name};
}

/// Devices that connected successfully, most recent first. Storage failures
/// are swallowed: remembering a device must never block connecting to it.
class KnownDevices {
  static const key = 'known_ble_devices';
  static const limit = 5;
  const KnownDevices();

  Future<List<PedalDevice>> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(key);
      if (raw == null) return [];
      return [
        for (final entry in jsonDecode(raw) as List<dynamic>)
          if (entry case {'id': String id, 'name': String name})
            PedalDevice(id, name),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> remember(PedalDevice device) async {
    final devices = await load();
    devices.removeWhere((d) => d.id == device.id);
    devices.insert(0, device);
    await _save(devices.take(limit).toList());
  }

  Future<void> forget(String id) async {
    final devices = await load();
    devices.removeWhere((d) => d.id == id);
    await _save(devices);
  }

  Future<void> _save(List<PedalDevice> devices) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        key,
        jsonEncode([for (final d in devices) d.toJson()]),
      );
    } catch (_) {}
  }
}
