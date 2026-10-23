/// Official Select OAuth flow, free-tier tone lists and bounded A2 downloads.
/// No pedal writes here.
library;

import 'localization.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'model_kind.dart';
import 'nam_model.dart';

const toneCallback = 'fb200nam://oauth/callback';
const toneModelLimit = 8 * 1024 * 1024;

/// `/tones/search` is outside the non-commercial API tier and heavily
/// rate-limited. Builds made under a TONE3000 agreement can enable it.
const toneSearchEnabled = bool.fromEnvironment('TONE3000_SEARCH');

/// Stays below the documented default of 100 requests per minute.
const toneRequestInterval = Duration(milliseconds: 650);
typedef ToneBrowser = Future<Uri> Function(Uri authorizationUrl);

class ToneError implements Exception {
  final String message;
  const ToneError(this.message);
  @override
  String toString() => message;
}

class ToneCancelled implements Exception {}

/// The file is valid NAM but not the fixed 48 kHz A2-Lite shape.
class ToneIncompatible extends ToneError {
  const ToneIncompatible(super.message);
}

String validatePublishableKey(String value) {
  final key = value.trim();
  if (key.isEmpty || key.length > 512 || key.contains(RegExp(r'\s'))) {
    throw ToneError(tr("TONE3000のPublishable Keyを設定してください。"));
  }
  if (key.startsWith('t3k_cs_')) {
    throw ToneError(tr("Secret Keyは使用できません。Publishable Keyを指定してください。"));
  }
  return key;
}

String parsePublishableKeyQr(String value) {
  final key = validatePublishableKey(value);
  if (!RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(key)) {
    throw ToneError(tr("Publishable Keyの文字列を含むQRコードを読み取ってください。"));
  }
  return key;
}

class ToneAuthorization {
  final String clientId, verifier, state;
  bool _used = false;
  ToneAuthorization(String clientId, {Random? random})
    : clientId = validatePublishableKey(clientId),
      verifier = _randomToken(random ?? Random.secure(), 64),
      state = _randomToken(random ?? Random.secure(), 32);

  static String _randomToken(Random random, int length) => base64Url
      .encode(List.generate(length, (_) => random.nextInt(256)))
      .replaceAll('=', '');

  Uri get url => Uri.https('www.tone3000.com', '/api/v1/oauth/authorize', {
    'client_id': clientId,
    'redirect_uri': toneCallback,
    'response_type': 'code',
    'code_challenge': base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', ''),
    'code_challenge_method': 'S256',
    'state': state,
    'prompt': 'select_tone',
    'format': 'nam',
    'architecture': '2',
    'menubar': 'true',
    'preview': 'true',
  });

  ({String code, int toneId}) accept(Uri callback) {
    if (_used) throw ToneError(tr("このログインは完了済みです。もう一度選択してください。"));
    _used = true;
    if (callback.scheme != 'fb200nam' ||
        callback.host != 'oauth' ||
        callback.path != '/callback' ||
        callback.hasFragment ||
        callback.userInfo.isNotEmpty ||
        callback.hasPort ||
        callback.queryParametersAll.values.any((v) => v.length != 1) ||
        callback.queryParameters['state'] != state) {
      throw ToneError(tr("ログインの応答を確認できませんでした。最初からやり直してください。"));
    }
    final query = callback.queryParameters;
    if (query['canceled'] == 'true' || query['error'] == 'access_denied') {
      throw ToneCancelled();
    }
    if (query.containsKey('error')) {
      throw ToneError(tr("TONE3000のログインに失敗しました。もう一度お試しください。"));
    }
    final code = query['code'], id = int.tryParse(query['tone_id'] ?? '');
    if (code == null || code.isEmpty || id == null || id <= 0) {
      throw ToneError(tr("選択したトーンを取得できませんでした。"));
    }
    return (code: code, toneId: id);
  }
}

Uri? _image(Object? value) {
  final uri = value is String ? Uri.tryParse(value) : null;
  return uri?.scheme == 'https' && uri!.host.isNotEmpty && uri.userInfo.isEmpty
      ? uri
      : null;
}

class ToneCreator {
  final String username;
  final Uri? avatar;
  ToneCreator(this.username, this.avatar);
  factory ToneCreator.parse(Map<String, dynamic> json) =>
      ToneCreator(json['username'] as String, _image(json['avatar_url']));
}

class TonePack {
  final int id;
  final String title, gear, description;
  final ToneCreator creator;
  final Uri? image;

  /// A2 variant count when TONE3000 reports it; null when unknown.
  final int? a2Count;
  TonePack({
    required this.id,
    required this.title,
    required this.gear,
    required this.creator,
    required this.image,
    this.description = '',
    this.a2Count,
  });
  factory TonePack.parse(Map<String, dynamic> json) {
    if (json['format'] != 'nam') throw ToneError(tr("NAM形式のトーンを選択してください。"));
    final images = json['images'];
    return TonePack(
      id: json['id'] as int,
      title: json['title'] as String,
      gear: json['gear'] as String? ?? '',
      creator: ToneCreator.parse(_object(json['user'])),
      image: images is List && images.isNotEmpty ? _image(images.first) : null,
      description: json['description'] as String? ?? '',
      a2Count: (json['a2_models_count'] as num?)?.toInt(),
    );
  }

  /// Library records keep only display metadata, never account data.
  factory TonePack.stored(Map<String, dynamic> json) => TonePack(
    id: json['id'] as int,
    title: json['title'] as String,
    gear: json['gear'] as String,
    creator: ToneCreator(
      json['creator'] as String,
      _image(json['creator_avatar']),
    ),
    image: _image(json['image']),
    description: json['description'] as String? ?? '',
  );
  Map<String, Object?> toStored() => {
    'id': id,
    'title': title,
    'gear': gear,
    'creator': creator.username,
    'creator_avatar': creator.avatar?.toString(),
    'image': image?.toString(),
    'description': description,
  };
  String get gearLabel => gearName(gear);
  static String gearName(String gear) =>
      const {
        'amp': 'Amp',
        'amp-cab': 'Amp + Cab',
        'pedal': 'Pedal',
        'cab': 'Cabinet',
        'outboard': 'Outboard',
        'space': 'Space',
        'experimental': 'Experimental',
      }[gear] ??
      gear;
}

class ToneModel {
  final int id, toneId;
  final String name;
  final Uri url;
  ToneModel(this.id, this.toneId, this.name, this.url);
  factory ToneModel.parse(Map<String, dynamic> json) => ToneModel(
    json['id'] as int,
    json['tone_id'] as int,
    json['name'] as String,
    Uri.parse(json['model_url'] as String),
  );
}

enum ToneShelf {
  favorited('tones/favorited', true),
  downloaded('tones/downloaded', true),
  created('tones/created', true),
  trending('tones/trending', false),
  latest('tones/latest', false),
  search('tones/search', true);

  final String path;
  final bool paginated;
  const ToneShelf(this.path, this.paginated);
}

class ToneListPage {
  final List<TonePack> tones;
  final int page, totalPages;
  ToneListPage(this.tones, this.page, this.totalPages);
}

class ToneModelPage {
  final List<ToneModel> models;
  final int page, totalPages;
  ToneModelPage(this.models, this.page, this.totalPages);
}

class ToneSelection {
  final TonePack tone;
  final ToneCreator account;
  final ToneModelPage firstPage;
  ToneSelection(this.tone, this.account, this.firstPage);
}

class ImportedTone {
  final TonePack tone;
  final ToneModel variant;
  final NamModel model;
  ImportedTone(this.tone, this.variant, this.model);
}

Map<String, dynamic> _object(Object? json) {
  if (json is! Map<String, dynamic>) {
    throw ToneError(tr("TONE3000からの応答形式を確認できませんでした。"));
  }
  return json;
}

class _Session {
  final String access, refresh;
  final DateTime expires;
  _Session(Map<String, dynamic> json, {String? previousRefresh})
    : access = json['access_token'] as String,
      refresh = json['refresh_token'] as String? ?? previousRefresh ?? '',
      expires = DateTime.now().add(
        Duration(seconds: (json['expires_in'] as num).toInt()),
      ) {
    if (access.isEmpty || refresh.isEmpty || !expires.isAfter(DateTime.now())) {
      throw ToneError(tr("ログインの有効期限を確認できませんでした。"));
    }
  }

  /// A restored session has no access token; the first request refreshes.
  _Session.restored(this.refresh)
    : access = '',
      expires = DateTime.fromMillisecondsSinceEpoch(0);
}

/// Persists only the refresh token, bound to the publishable key.
abstract class ToneSessionStore {
  Future<String?> read(String clientId);
  Future<void> write(String clientId, String refreshToken);
  Future<void> clear();
}

class MemoryToneSessionStore implements ToneSessionStore {
  String? clientId, refreshToken;
  @override
  Future<String?> read(String clientId) async =>
      clientId == this.clientId ? refreshToken : null;
  @override
  Future<void> write(String clientId, String refreshToken) async {
    this.clientId = clientId;
    this.refreshToken = refreshToken;
  }

  @override
  Future<void> clear() async => clientId = refreshToken = null;
}

class Tone3000Api {
  final String clientId;
  final http.Client _client;
  final ToneSessionStore sessions;
  final Duration requestInterval;
  _Session? _session;
  Future<void>? _refreshing;
  DateTime _nextRequest = DateTime.fromMillisecondsSinceEpoch(0);
  bool _closed = false;
  ToneCreator? account;
  Tone3000Api(
    String clientId, {
    http.Client? client,
    ToneSessionStore? sessions,
    this.requestInterval = toneRequestInterval,
  }) : clientId = validatePublishableKey(clientId),
       _client = client ?? http.Client(),
       sessions = sessions ?? MemoryToneSessionStore();

  bool get signedIn => _session != null;

  static bool _apiOrigin(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'www.tone3000.com' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty;
  Uri _endpoint(String path, [Map<String, String>? query]) =>
      Uri.https('www.tone3000.com', '/api/v1/$path', query);

  /// The official Select flow is both sign-in and full-catalog browsing.
  Future<ToneSelection> select(ToneBrowser browser) async {
    final request = ToneAuthorization(clientId);
    final result = request.accept(await browser(request.url));
    _session = _Session(
      await _token({
        'grant_type': 'authorization_code',
        'code': result.code,
        'code_verifier': request.verifier,
        'redirect_uri': toneCallback,
      }),
    );
    await _persist();
    final tone = await getTone(result.toneId);
    final user = account = ToneCreator.parse(await _json(_endpoint('user')));
    return ToneSelection(tone, user, await listModels(tone.id));
  }

  /// Resumes a stored session. Returns null when the user must sign in again;
  /// network failures propagate and keep the stored token.
  Future<ToneCreator?> restore() async {
    final refresh = await sessions.read(clientId);
    if (refresh == null || refresh.isEmpty) return null;
    _session = _Session.restored(refresh);
    try {
      return account = ToneCreator.parse(await _json(_endpoint('user')));
    } on ToneError {
      if (_session != null) rethrow;
      return null;
    }
  }

  Future<void> signOut() async {
    _session = null;
    account = null;
    await sessions.clear();
  }

  Future<TonePack> getTone(int id) async {
    final tone = TonePack.parse(await _json(_endpoint('tones/$id')));
    if (tone.id != id) throw ToneError(tr("トーンのIDが一致しません。"));
    return tone;
  }

  Future<void> _persist() async {
    final session = _session;
    if (session == null) return;
    try {
      await sessions.write(clientId, session.refresh);
    } catch (_) {
      // Storage failure only costs a later sign-in.
    }
  }

  Future<Map<String, dynamic>> _token(Map<String, String> fields) async {
    final request = http.Request('POST', _endpoint('oauth/token'))
      ..followRedirects = false
      ..bodyFields = {...fields, 'client_id': clientId};
    final response = await _send(request);
    final bytes = await _read(response, 64 * 1024);
    // Only a rejected grant ends the stored session; outages keep it.
    if (response.statusCode == 400 || response.statusCode == 401) {
      _session = null;
      account = null;
      await sessions.clear();
      throw ToneError(tr("ログインの有効期限が切れました。TONE3000から選択し直してください。"));
    }
    _checkStatus(response.statusCode);
    return _decode(bytes);
  }

  /// Concurrent downloads share one refresh so a rotated token is not reused.
  /// `whenComplete` runs after the assignment even if the refresh fails
  /// synchronously, so a failed refresh is never cached.
  Future<void> _refresh() =>
      _refreshing ??= _refreshOnce().whenComplete(() => _refreshing = null);

  Future<void> _refreshOnce() async {
    final session = _session;
    if (session == null) throw ToneError(tr("TONE3000にログインしてください。"));
    _session = _Session(
      await _token({
        'grant_type': 'refresh_token',
        'refresh_token': session.refresh,
      }),
      previousRefresh: session.refresh,
    );
    await _persist();
  }

  Future<http.StreamedResponse> _get(
    Uri uri, {
    bool retry = true,
    bool wait = true,
  }) async {
    if (_session == null) throw ToneError(tr("TONE3000にログインしてください。"));
    if (_session!.expires.isBefore(
      DateTime.now().add(const Duration(seconds: 30)),
    )) {
      await _refresh();
    }
    final request = http.Request('GET', uri)..followRedirects = false;
    final access = _session!.access;
    // Bearer credentials never follow a redirect onto a CDN or another origin.
    if (_apiOrigin(uri)) request.headers['Authorization'] = 'Bearer $access';
    final response = await _send(request);
    if (response.statusCode == 401 && retry && _apiOrigin(uri)) {
      await response.stream.listen((_) {}).cancel();
      // A parallel download may already have refreshed the token.
      if (_session?.access == access) await _refresh();
      return _get(uri, retry: false, wait: wait);
    }
    final after = int.tryParse(response.headers['retry-after'] ?? '');
    if (response.statusCode == 429 && wait && after != null && after <= 30) {
      await response.stream.listen((_) {}).cancel();
      await Future<void>.delayed(Duration(seconds: after));
      return _get(uri, retry: retry, wait: false);
    }
    return response;
  }

  Future<void> _pace() async {
    final now = DateTime.now();
    final start = _nextRequest.isAfter(now) ? _nextRequest : now;
    _nextRequest = start.add(requestInterval);
    if (start.isAfter(now)) await Future<void>.delayed(start.difference(now));
  }

  Future<http.StreamedResponse> _send(http.BaseRequest request) async {
    if (_closed) throw ToneCancelled();
    if (_apiOrigin(request.url)) await _pace();
    if (_closed) throw ToneCancelled();
    try {
      return await _client.send(request).timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw ToneError(tr("通信がタイムアウトしました。接続を確認して再試行してください。"));
    } on http.ClientException {
      if (_closed) throw ToneCancelled();
      throw ToneError(tr("TONE3000に接続できません。インターネット接続を確認してください。"));
    }
  }

  Future<Uint8List> _read(http.StreamedResponse response, int limit) async {
    if ((response.contentLength ?? 0) > limit) {
      await response.stream.listen((_) {}).cancel();
      throw ToneError(tr("ファイルが大きすぎます。8 MB以下のモデルを選択してください。"));
    }
    Future<Uint8List> collect() async {
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (_closed) throw ToneCancelled();
        if (bytes.length + chunk.length > limit) {
          throw ToneError(tr("ファイルが大きすぎます。8 MB以下のモデルを選択してください。"));
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    }

    try {
      return await collect().timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          close();
          throw ToneError(tr("ダウンロードがタイムアウトしました。"));
        },
      );
    } on http.ClientException {
      if (_closed) throw ToneCancelled();
      throw ToneError(tr("ダウンロードが中断されました。もう一度お試しください。"));
    }
  }

  Map<String, dynamic> _decode(Uint8List bytes) {
    try {
      return _object(jsonDecode(utf8.decode(bytes)));
    } on FormatException {
      throw ToneError(tr("TONE3000の応答を読み取れませんでした。"));
    }
  }

  void _checkStatus(int status) {
    if (status == 200) return;
    throw ToneError(switch (status) {
      401 => tr("ログインの有効期限が切れました。選択し直してください。"),
      403 => tr("このモデルへのアクセスが許可されていません。"),
      404 => tr("このモデルは見つかりません。別のモデルを選択してください。"),
      429 => tr("アクセスが集中しています。少し待ってから再試行してください。"),
      _ => tr("TONE3000から取得できませんでした（HTTP {0}）。", [status]),
    });
  }

  Future<Map<String, dynamic>> _json(Uri uri) async => _object(await _any(uri));

  Future<Object?> _any(Uri uri) async {
    final response = await _get(uri);
    final bytes = await _read(response, 1024 * 1024);
    _checkStatus(response.statusCode);
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw ToneError(tr("TONE3000の応答を読み取れませんでした。"));
    }
  }

  /// Lists NAM tones that have A2 variants. Only search filters by format
  /// server-side, so other formats are dropped here.
  Future<ToneListPage> listTones(
    ToneShelf shelf, {
    String query = '',
    String? gear,
    int page = 1,
  }) async {
    if (shelf == ToneShelf.search && !toneSearchEnabled) {
      throw ToneError(tr("この連携ではTONE3000の検索APIを利用できません。"));
    }
    final q = query.trim();
    final json = await _any(
      _endpoint(shelf.path, {
        if (shelf.paginated) ...{'page': '$page', 'page_size': '25'},
        if (q.isNotEmpty && shelf.paginated) 'query': q,
        if (gear != null && shelf != ToneShelf.latest)
          shelf == ToneShelf.search ? 'gears' : 'gear': gear,
        if (shelf == ToneShelf.search) ...{
          'format': 'nam',
          'architecture': '2',
        },
      }),
    );
    final entries = json is List
        ? json
        : json is Map<String, dynamic>
        ? json['data']
        : null;
    if (entries is! List) throw ToneError(tr("トーン一覧を読み取れませんでした。"));
    final tones = <TonePack>[];
    for (final entry in entries) {
      if (entry is! Map<String, dynamic> || entry['format'] != 'nam') continue;
      try {
        final tone = TonePack.parse(entry);
        if (tone.a2Count == 0 || (gear != null && tone.gear != gear)) continue;
        // Unpaginated shelves have no server-side query; filter locally.
        final text = '${tone.title} ${tone.creator.username}'.toLowerCase();
        if (!shelf.paginated && !text.contains(q.toLowerCase())) continue;
        tones.add(tone);
      } catch (_) {
        // One malformed entry must not hide the rest of the list.
      }
    }
    return json is Map<String, dynamic> && shelf.paginated
        ? ToneListPage(
            tones,
            (json['page'] as num?)?.toInt() ?? page,
            (json['total_pages'] as num?)?.toInt() ?? page,
          )
        : ToneListPage(tones, 1, 1);
  }

  /// One request covers almost every tone (the API allows 300 per page).
  Future<List<ToneModel>> listAllModels(int toneId) async {
    final models = <ToneModel>[];
    for (var page = 1, total = 1; page <= total && page <= 20; page++) {
      final result = await listModels(toneId, page: page, pageSize: 300);
      models.addAll(result.models);
      total = result.totalPages;
    }
    return models;
  }

  Future<ToneModelPage> listModels(
    int toneId, {
    int page = 1,
    int pageSize = 50,
  }) async {
    final json = await _json(
      _endpoint('models', {
        'tone_id': '$toneId',
        'architecture': '2',
        'page': '$page',
        'page_size': '$pageSize',
      }),
    );
    final entries = json['data'];
    if (entries is! List) throw ToneError(tr("モデル一覧を読み取れませんでした。"));
    final models = entries
        .map((entry) => _object(entry))
        .where((entry) => entry['architecture_version'].toString() == '2')
        .map(ToneModel.parse)
        .where((m) => m.toneId == toneId)
        .toList();
    return ToneModelPage(
      models,
      json['page'] as int,
      json['total_pages'] as int,
    );
  }

  Future<ImportedTone> download(TonePack tone, ToneModel model) async =>
      importBytes(tone, model, await downloadBytes(tone, model));

  static ImportedTone importBytes(
    TonePack tone,
    ToneModel model,
    Uint8List bytes,
  ) {
    try {
      final parsed = NamModel.parse(bytes, '${model.name}.nam');
      // The tone's gear wins over the file's own metadata.
      final kind = ModelKind.fromGear(tone.gear);
      return ImportedTone(
        tone,
        model,
        kind == ModelKind.unknown ? parsed : parsed.withKind(kind),
      );
    } on FormatException catch (e) {
      throw ToneIncompatible(tr("このモデルはFB200で使用できません。{0}", [e.message]));
    }
  }

  Future<Uint8List> downloadBytes(TonePack tone, ToneModel model) async {
    var uri = _endpoint('').resolveUri(model.url);
    if (model.toneId != tone.id ||
        !_apiOrigin(uri) ||
        !uri.path.startsWith('/api/v1/models/')) {
      throw ToneError(tr("モデルのダウンロード先を確認できませんでした。"));
    }
    for (var redirects = 0; redirects <= 5; redirects++) {
      final response = await _get(uri);
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers['location'];
        await response.stream.listen((_) {}).cancel();
        final next = location == null ? null : uri.resolve(location);
        if (next == null ||
            next.scheme != 'https' ||
            next.host.isEmpty ||
            next.userInfo.isNotEmpty ||
            next.hasFragment ||
            next.port != 443) {
          throw ToneError(tr("安全なダウンロード先を確認できませんでした。"));
        }
        uri = next;
        continue;
      }
      final bytes = await _read(response, toneModelLimit);
      _checkStatus(response.statusCode);
      return bytes;
    }
    throw ToneError(tr("ダウンロード先の転送が多すぎます。"));
  }

  void close() {
    _closed = true;
    _session = null;
    _client.close();
  }
}
