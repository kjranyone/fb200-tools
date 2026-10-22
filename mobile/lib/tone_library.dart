/// Device-local TONE3000 model library and the paced bulk downloader.
/// Only FB200-compatible files are kept. No pedal writes here.
library;

import 'localization.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'tone3000.dart';

/// Android Keystore / iOS Keychain backed refresh-token storage.
class SecureToneSessionStore implements ToneSessionStore {
  static const _key = 'tone3000_session';
  final FlutterSecureStorage _storage;
  const SecureToneSessionStore([this._storage = const FlutterSecureStorage()]);

  @override
  Future<String?> read(String clientId) async {
    try {
      // A stuck keystore must not hold the page; it only costs a sign-in.
      final value = await _storage
          .read(key: _key)
          .timeout(const Duration(seconds: 3));
      if (value == null) return null;
      final json = jsonDecode(value) as Map<String, dynamic>;
      return json['client_id'] == clientId ? json['refresh'] as String? : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String clientId, String refreshToken) => _storage.write(
    key: _key,
    value: jsonEncode({'client_id': clientId, 'refresh': refreshToken}),
  );

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      // Keystore errors leave nothing usable behind.
    }
  }
}

class LibraryEntry {
  final TonePack tone;
  final ToneModel variant;
  final DateTime added;
  LibraryEntry(this.tone, this.variant, this.added);

  factory LibraryEntry.parse(Map<String, dynamic> json) {
    final tone = TonePack.stored(json['tone'] as Map<String, dynamic>);
    return LibraryEntry(
      tone,
      ToneModel(
        json['model_id'] as int,
        tone.id,
        json['name'] as String,
        Uri.parse(json['model_url'] as String),
      ),
      DateTime.parse(json['added'] as String),
    );
  }
  Map<String, Object?> toJson() => {
    'model_id': variant.id,
    'name': variant.name,
    'model_url': variant.url.toString(),
    'added': added.toUtc().toIso8601String(),
    'tone': tone.toStored(),
  };

  /// Every word must appear in the model, tone, gear or creator name.
  bool matches(String query) {
    final text =
        '${variant.name} ${tone.title} ${tone.gearLabel} '
                '@${tone.creator.username}'
            .toLowerCase();
    return query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .every(text.contains);
  }
}

abstract class LibraryStorage {
  Future<String?> readIndex();
  Future<void> writeIndex(String json);
  Future<Uint8List> readModel(int id);
  Future<void> writeModel(int id, Uint8List bytes);
  Future<void> deleteModel(int id);
}

/// Original `.nam` files are kept gzip-compressed so later app versions can
/// parse them again. Each write lands in a temporary file and is renamed.
class FileLibraryStorage implements LibraryStorage {
  final Future<Directory> Function() root;
  FileLibraryStorage(this.root);

  Future<File> _model(int id) async =>
      File('${(await root()).path}/models/$id.nam.gz');
  Future<File> get _index async => File('${(await root()).path}/index.json');

  Future<void> _replace(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final partial = File('${file.path}.part');
    await partial.writeAsBytes(bytes, flush: true);
    await partial.rename(file.path);
  }

  @override
  Future<String?> readIndex() async {
    final file = await _index;
    return await file.exists() ? file.readAsString() : null;
  }

  @override
  Future<void> writeIndex(String json) async =>
      _replace(await _index, utf8.encode(json));
  @override
  Future<Uint8List> readModel(int id) async =>
      Uint8List.fromList(gzip.decode(await (await _model(id)).readAsBytes()));
  @override
  Future<void> writeModel(int id, Uint8List bytes) async =>
      _replace(await _model(id), gzip.encode(bytes));
  @override
  Future<void> deleteModel(int id) async {
    final file = await _model(id);
    if (await file.exists()) await file.delete();
  }
}

/// Session-only storage for the web demo and tests.
class MemoryLibraryStorage implements LibraryStorage {
  String? index;
  final models = <int, Uint8List>{};
  @override
  Future<String?> readIndex() async => index;
  @override
  Future<void> writeIndex(String json) async => index = json;
  @override
  Future<Uint8List> readModel(int id) async =>
      models[id] ?? (throw StateError('missing model $id'));
  @override
  Future<void> writeModel(int id, Uint8List bytes) async => models[id] = bytes;
  @override
  Future<void> deleteModel(int id) async => models.remove(id);
}

/// Downloaded models with their TONE3000 attribution.
class ToneLibrary extends ChangeNotifier {
  final LibraryStorage storage;
  final _entries = <int, LibraryEntry>{};
  Future<void>? _loading;
  Future<void> _saving = Future<void>.value();
  ToneLibrary(this.storage);

  static ToneLibrary? _app;
  static ToneLibrary get app => _app ??= ToneLibrary(
    kIsWeb
        ? MemoryLibraryStorage()
        : FileLibraryStorage(
            () async => Directory(
              '${(await getApplicationSupportDirectory()).path}/tone3000',
            ),
          ),
  );

  /// Newest download first.
  List<LibraryEntry> get entries =>
      _entries.values.toList()..sort((a, b) => b.added.compareTo(a.added));
  bool has(int modelId) => _entries.containsKey(modelId);
  int storedFor(int toneId) =>
      _entries.values.where((e) => e.tone.id == toneId).length;

  Future<void> load() => _loading ??= () async {
    try {
      final index = await storage.readIndex();
      if (index == null) return;
      final json = jsonDecode(index) as Map<String, dynamic>;
      for (final item in json['models'] as List) {
        try {
          final entry = LibraryEntry.parse(item as Map<String, dynamic>);
          _entries[entry.variant.id] = entry;
        } catch (_) {
          // Skip a damaged record rather than losing the whole library.
        }
      }
    } catch (_) {
      // An unreadable index starts an empty library.
    } finally {
      notifyListeners();
    }
  }();

  /// Rejects models the FB200 cannot run before anything is written.
  Future<ImportedTone> store(
    TonePack tone,
    ToneModel model,
    Uint8List bytes,
  ) async {
    final imported = Tone3000Api.importBytes(tone, model, bytes);
    await load();
    await storage.writeModel(model.id, bytes);
    _entries[model.id] = LibraryEntry(tone, model, DateTime.now());
    await _save();
    notifyListeners();
    return imported;
  }

  Future<ImportedTone> open(LibraryEntry entry) async {
    final Uint8List bytes;
    try {
      bytes = await storage.readModel(entry.variant.id);
    } catch (_) {
      throw ToneError(tr("端末に保存したモデルを読み込めませんでした。もう一度ダウンロードしてください。"));
    }
    return Tone3000Api.importBytes(entry.tone, entry.variant, bytes);
  }

  Future<void> remove(Iterable<int> modelIds) async {
    await load();
    for (final id in modelIds.toList()) {
      if (_entries.remove(id) == null) continue;
      try {
        await storage.deleteModel(id);
      } catch (_) {
        // The index no longer refers to it; a stray file is harmless.
      }
    }
    await _save();
    notifyListeners();
  }

  /// Index writes are serialized; a failed write does not block later ones.
  Future<void> _save() {
    final json = jsonEncode({
      'version': 1,
      'models': [for (final e in _entries.values) e.toJson()],
    });
    return _saving = _saving
        .catchError((Object _) {})
        .then((_) => storage.writeIndex(json));
  }
}

class ToneDownloadJob {
  final TonePack tone;

  /// Null downloads every A2 variant of the tone.
  final List<ToneModel>? models;
  ToneDownloadJob(this.tone, [this.models]);
}

/// Bulk download with two parallel transfers. The API client paces requests
/// below the documented rate limit; an error on one model does not stop others.
class ToneDownloader extends ChangeNotifier {
  final ToneLibrary library;
  ToneDownloader(this.library);

  bool running = false, _cancel = false;
  int total = 0, saved = 0, existing = 0, incompatible = 0, failed = 0;
  String current = '', lastError = '';
  final _waiting = <Completer<void>>[];

  int get finished => saved + existing + incompatible + failed;
  bool get cancelling => running && _cancel;

  /// Stops after the transfers in flight; stored files stay valid.
  void cancel() {
    if (!running || _cancel) return;
    _cancel = true;
    _wake();
    notifyListeners();
  }

  void _wake() {
    for (final waiter in _waiting) {
      waiter.complete();
    }
    _waiting.clear();
  }

  Future<void> run(Tone3000Api api, List<ToneDownloadJob> jobs) async {
    if (running) return;
    running = true;
    _cancel = false;
    total = saved = existing = incompatible = failed = 0;
    current = lastError = '';
    notifyListeners();
    final queue = <(TonePack, ToneModel)>[];
    var listed = false;
    try {
      await library.load();
      // Listing runs ahead of the downloads so transfers start early.
      final listing = () async {
        try {
          for (final job in jobs) {
            if (_cancel) return;
            try {
              final models = job.models ?? await api.listAllModels(job.tone.id);
              for (final model in models) {
                total++;
                if (library.has(model.id)) {
                  existing++;
                } else {
                  queue.add((job.tone, model));
                }
              }
            } on ToneCancelled {
              return;
            } catch (e) {
              total++;
              failed++;
              lastError = e is ToneError ? e.message : tr("モデル一覧を読み取れませんでした。");
            }
            _wake();
            notifyListeners();
          }
        } finally {
          listed = true;
          _wake();
        }
      }();

      Future<void> worker() async {
        while (!_cancel) {
          if (queue.isEmpty) {
            if (listed) return;
            final waiter = Completer<void>();
            _waiting.add(waiter);
            await waiter.future;
            continue;
          }
          final (tone, model) = queue.removeAt(0);
          current = model.name;
          notifyListeners();
          try {
            final bytes = await api.downloadBytes(tone, model);
            await library.store(tone, model, bytes);
            saved++;
          } on ToneCancelled {
            return;
          } on ToneIncompatible {
            incompatible++;
          } on ToneError catch (e) {
            failed++;
            lastError = e.message;
          } catch (_) {
            failed++;
            lastError = tr("端末への保存に失敗しました。空き容量を確認してください。");
          }
          notifyListeners();
        }
      }

      await Future.wait([worker(), worker(), listing]);
    } finally {
      running = false;
      current = '';
      _wake();
      notifyListeners();
    }
  }
}
