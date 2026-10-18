/// Official Select OAuth flow and bounded A2 downloads. No pedal writes here.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'nam_model.dart';

const toneCallback = 'fb200nam://oauth/callback';
const toneModelLimit = 8 * 1024 * 1024;
typedef ToneBrowser = Future<Uri> Function(Uri authorizationUrl);

class ToneError implements Exception {
  final String message;
  const ToneError(this.message);
  @override
  String toString() => message;
}

class ToneCancelled implements Exception {}

String validatePublishableKey(String value) {
  final key = value.trim();
  if (key.isEmpty || key.length > 512 || key.contains(RegExp(r'\s'))) {
    throw const ToneError('TONE3000のPublishable Keyを設定してください。');
  }
  if (key.startsWith('t3k_cs_')) {
    throw const ToneError('Secret Keyは使用できません。Publishable Keyを指定してください。');
  }
  return key;
}

String parsePublishableKeyQr(String value) {
  final key = validatePublishableKey(value);
  if (!RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(key)) {
    throw const ToneError('Publishable Keyの文字列を含むQRコードを読み取ってください。');
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
    if (_used) throw const ToneError('このログインは完了済みです。もう一度選択してください。');
    _used = true;
    if (callback.scheme != 'fb200nam' ||
        callback.host != 'oauth' ||
        callback.path != '/callback' ||
        callback.hasFragment ||
        callback.userInfo.isNotEmpty ||
        callback.hasPort ||
        callback.queryParametersAll.values.any((v) => v.length != 1) ||
        callback.queryParameters['state'] != state) {
      throw const ToneError('ログインの応答を確認できませんでした。最初からやり直してください。');
    }
    final query = callback.queryParameters;
    if (query['canceled'] == 'true' || query['error'] == 'access_denied') {
      throw ToneCancelled();
    }
    if (query.containsKey('error')) {
      throw const ToneError('TONE3000のログインに失敗しました。もう一度お試しください。');
    }
    final code = query['code'], id = int.tryParse(query['tone_id'] ?? '');
    if (code == null || code.isEmpty || id == null || id <= 0) {
      throw const ToneError('選択したトーンを取得できませんでした。');
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
  TonePack({
    required this.id,
    required this.title,
    required this.gear,
    required this.creator,
    required this.image,
    this.description = '',
  });
  factory TonePack.parse(Map<String, dynamic> json) {
    if (json['format'] != 'nam') throw const ToneError('NAM形式のトーンを選択してください。');
    final images = json['images'];
    return TonePack(
      id: json['id'] as int,
      title: json['title'] as String,
      gear: json['gear'] as String,
      creator: ToneCreator.parse(_object(json['user'])),
      image: images is List && images.isNotEmpty ? _image(images.first) : null,
      description: json['description'] as String? ?? '',
    );
  }
  String get gearLabel =>
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
    throw const ToneError('TONE3000からの応答形式を確認できませんでした。');
  }
  return json;
}

class _Session {
  final String access, refresh;
  final DateTime expires;
  _Session(Map<String, dynamic> json)
    : access = json['access_token'] as String,
      refresh = json['refresh_token'] as String,
      expires = DateTime.now().add(
        Duration(seconds: (json['expires_in'] as num).toInt()),
      ) {
    if (access.isEmpty || refresh.isEmpty || !expires.isAfter(DateTime.now())) {
      throw const ToneError('ログインの有効期限を確認できませんでした。');
    }
  }
}

class Tone3000Api {
  final String clientId;
  final http.Client _client;
  _Session? _session;
  bool _closed = false;
  Tone3000Api(String clientId, {http.Client? client})
    : clientId = validatePublishableKey(clientId),
      _client = client ?? http.Client();

  static bool _apiOrigin(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'www.tone3000.com' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty;
  Uri _endpoint(String path, [Map<String, String>? query]) =>
      Uri.https('www.tone3000.com', '/api/v1/$path', query);

  Future<ToneSelection> select(ToneBrowser browser) async {
    _session = null;
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
    final tone = TonePack.parse(
      await _json(_endpoint('tones/${result.toneId}')),
    );
    if (tone.id != result.toneId) throw const ToneError('トーンのIDが一致しません。');
    final account = ToneCreator.parse(await _json(_endpoint('user')));
    return ToneSelection(tone, account, await listModels(tone.id));
  }

  Future<Map<String, dynamic>> _token(Map<String, String> fields) async {
    final request = http.Request('POST', _endpoint('oauth/token'))
      ..followRedirects = false
      ..bodyFields = {...fields, 'client_id': clientId};
    final response = await _send(request);
    final bytes = await _read(response, 64 * 1024);
    if (response.statusCode != 200) {
      _session = null;
      throw const ToneError('ログインの有効期限が切れました。TONE3000から選択し直してください。');
    }
    return _decode(bytes);
  }

  Future<void> _refresh() async {
    final session = _session;
    if (session == null) throw const ToneError('TONE3000にログインしてください。');
    _session = _Session(
      await _token({
        'grant_type': 'refresh_token',
        'refresh_token': session.refresh,
      }),
    );
  }

  Future<http.StreamedResponse> _get(Uri uri, {bool retry = true}) async {
    if (_session == null) throw const ToneError('TONE3000にログインしてください。');
    if (_session!.expires.isBefore(
      DateTime.now().add(const Duration(seconds: 30)),
    )) {
      await _refresh();
    }
    final request = http.Request('GET', uri)..followRedirects = false;
    // Bearer credentials never follow a redirect onto a CDN or another origin.
    if (_apiOrigin(uri)) {
      request.headers['Authorization'] = 'Bearer ${_session!.access}';
    }
    final response = await _send(request);
    if (response.statusCode == 401 && retry && _apiOrigin(uri)) {
      await response.stream.listen((_) {}).cancel();
      await _refresh();
      return _get(uri, retry: false);
    }
    return response;
  }

  Future<http.StreamedResponse> _send(http.BaseRequest request) async {
    if (_closed) throw ToneCancelled();
    try {
      return await _client.send(request).timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw const ToneError('通信がタイムアウトしました。接続を確認して再試行してください。');
    } on http.ClientException {
      if (_closed) throw ToneCancelled();
      throw const ToneError('TONE3000に接続できません。インターネット接続を確認してください。');
    }
  }

  Future<Uint8List> _read(http.StreamedResponse response, int limit) async {
    if ((response.contentLength ?? 0) > limit) {
      await response.stream.listen((_) {}).cancel();
      throw const ToneError('ファイルが大きすぎます。8 MB以下のモデルを選択してください。');
    }
    Future<Uint8List> collect() async {
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (_closed) throw ToneCancelled();
        if (bytes.length + chunk.length > limit) {
          throw const ToneError('ファイルが大きすぎます。8 MB以下のモデルを選択してください。');
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
          throw const ToneError('ダウンロードがタイムアウトしました。');
        },
      );
    } on http.ClientException {
      if (_closed) throw ToneCancelled();
      throw const ToneError('ダウンロードが中断されました。もう一度お試しください。');
    }
  }

  Map<String, dynamic> _decode(Uint8List bytes) {
    try {
      return _object(jsonDecode(utf8.decode(bytes)));
    } on FormatException {
      throw const ToneError('TONE3000の応答を読み取れませんでした。');
    }
  }

  void _checkStatus(int status) {
    if (status == 200) return;
    throw ToneError(switch (status) {
      401 => 'ログインの有効期限が切れました。選択し直してください。',
      403 => 'このモデルへのアクセスが許可されていません。',
      404 => 'このモデルは見つかりません。別のモデルを選択してください。',
      429 => 'アクセスが集中しています。少し待ってから再試行してください。',
      _ => 'TONE3000から取得できませんでした（HTTP $status）。',
    });
  }

  Future<Map<String, dynamic>> _json(Uri uri) async {
    final response = await _get(uri);
    final bytes = await _read(response, 1024 * 1024);
    _checkStatus(response.statusCode);
    return _decode(bytes);
  }

  Future<ToneModelPage> listModels(int toneId, {int page = 1}) async {
    final json = await _json(
      _endpoint('models', {
        'tone_id': '$toneId',
        'architecture': '2',
        'page': '$page',
        'page_size': '50',
      }),
    );
    final entries = json['data'];
    if (entries is! List) throw const ToneError('モデル一覧を読み取れませんでした。');
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

  Future<ImportedTone> download(TonePack tone, ToneModel model) async {
    var uri = _endpoint('').resolveUri(model.url);
    if (model.toneId != tone.id ||
        !_apiOrigin(uri) ||
        !uri.path.startsWith('/api/v1/models/')) {
      throw const ToneError('モデルのダウンロード先を確認できませんでした。');
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
          throw const ToneError('安全なダウンロード先を確認できませんでした。');
        }
        uri = next;
        continue;
      }
      final bytes = await _read(response, toneModelLimit);
      _checkStatus(response.statusCode);
      try {
        return ImportedTone(
          tone,
          model,
          NamModel.parse(bytes, '${model.name}.nam'),
        );
      } on FormatException catch (e) {
        throw ToneError('このモデルはFB200で使用できません。${e.message}');
      }
    }
    throw const ToneError('ダウンロード先の転送が多すぎます。');
  }

  void close() {
    _closed = true;
    _session = null;
    _client.close();
  }
}
