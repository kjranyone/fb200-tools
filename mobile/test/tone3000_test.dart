import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fb200_nam/tone3000.dart';

final toneFixture = <String, dynamic>{
  'id': 7,
  'title': 'Bass Full Rig',
  'gear': 'amp-cab',
  'format': 'nam',
  'description': 'A bass capture',
  'images': <String>[],
  'user': {'username': 'creator', 'avatar_url': null},
};
final modelFixture = <String, dynamic>{
  'id': 11,
  'tone_id': 7,
  'name': 'Bass Clean',
  'architecture_version': 2,
  'model_url':
      'https://www.tone3000.com/api/v1/models/11/download?architecture=2',
};

Uint8List modelBytes() => File('test/fixtures/synthetic.nam').readAsBytesSync();
Future<Uri> acceptBrowser(Uri url) async => Uri.parse(toneCallback).replace(
  queryParameters: {
    'state': url.queryParameters['state']!,
    'code': 'test-code',
    'tone_id': '7',
  },
);

class ToneHarness {
  final requests = <http.Request>[];
  Uint8List bytes = modelBytes();
  int downloads = 0, refreshes = 0, downloadStatus = 200;
  bool rejectOnce = false, rejectAlways = false, advertiseOversize = false;
  String? redirect;
  Map<String, dynamic> metadata = Map.of(modelFixture);
  late final Tone3000Api api = Tone3000Api(
    'publishable-test',
    client: MockClient.streaming((request, body) async {
      final req = http.Request(request.method, request.url)
        ..headers.addAll(request.headers)
        ..bodyBytes = await body.toBytes();
      requests.add(req);
      http.StreamedResponse result(
        Object data, {
        int status = 200,
        Map<String, String>? headers,
      }) => http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(data))),
        status,
        headers: headers ?? {},
      );
      final path = request.url.path;
      if (path.endsWith('/oauth/token')) {
        final fields = Uri.splitQueryString(req.body);
        expect(fields['client_id'], 'publishable-test');
        if (fields['grant_type'] == 'refresh_token') {
          refreshes++;
          expect(fields['refresh_token'], 'refresh-test');
        } else {
          expect(fields['grant_type'], 'authorization_code');
          expect(fields['code_verifier']!.length, inInclusiveRange(43, 128));
          expect(fields['redirect_uri'], toneCallback);
        }
        return result({
          'access_token': refreshes == 0 ? 'access-test' : 'access-new',
          'refresh_token': 'refresh-test',
          'expires_in': 3600,
        });
      }
      if (request.url.host != 'cdn.example') {
        expect(request.headers['Authorization'], startsWith('Bearer access-'));
      }
      if (path.endsWith('/tones/7')) return result(toneFixture);
      if (path.endsWith('/user')) {
        return result({'username': 'listener', 'avatar_url': null});
      }
      if (path.endsWith('/models')) {
        if (rejectAlways || rejectOnce) {
          rejectOnce = false;
          return result({'error': 'do not display raw errors'}, status: 401);
        }
        expect(request.url.queryParameters['architecture'], '2');
        return result({
          'page': int.parse(request.url.queryParameters['page']!),
          'total_pages': 2,
          'data': [
            metadata,
            {...metadata, 'id': 12, 'architecture_version': 1},
          ],
        });
      }
      if (path.contains('/download') || request.url.host == 'cdn.example') {
        downloads++;
        if (redirect != null && request.url.host != 'cdn.example') {
          return http.StreamedResponse(
            const Stream.empty(),
            302,
            headers: {'location': redirect!},
          );
        }
        return http.StreamedResponse(
          Stream.value(bytes),
          downloadStatus,
          contentLength: advertiseOversize ? toneModelLimit + 1 : bytes.length,
        );
      }
      throw StateError('Unexpected endpoint: ${request.url}');
    }),
  );
}

void main() {
  test('Select uses PKCE S256 and explicitly requests A2 NAM', () {
    final flow = ToneAuthorization('publishable-test', random: Random(42));
    final q = flow.url.queryParameters;
    expect(q['prompt'], 'select_tone');
    expect(q['architecture'], '2');
    expect(q['format'], 'nam');
    expect(q['redirect_uri'], toneCallback);
    expect(q['code_challenge_method'], 'S256');
    expect(
      q['code_challenge'],
      base64Url
          .encode(sha256.convert(ascii.encode(flow.verifier)).bytes)
          .replaceAll('=', ''),
    );
    expect(flow.verifier.length, inInclusiveRange(43, 128));
    expect(flow.state.length, greaterThanOrEqualTo(32));
    expect(flow.url.toString(), isNot(contains(flow.verifier)));
  });

  for (final bad in [
    'fb200nam://other/callback',
    'fb200nam://oauth/other',
    'https://example.com/callback',
    'fb200nam://oauth/callback#fragment',
  ]) {
    test('reject callback outside the registered URI: $bad', () {
      final flow = ToneAuthorization('publishable-test');
      final uri = Uri.parse(bad).replace(
        queryParameters: {'state': flow.state, 'code': 'code', 'tone_id': '7'},
      );
      expect(() => flow.accept(uri), throwsA(isA<ToneError>()));
    });
  }

  test('state mismatch and duplicate state are rejected before any token exchange', () {
    final flow = ToneAuthorization('publishable-test');
    expect(
      () =>
          flow.accept(Uri.parse('$toneCallback?state=wrong&code=c&tone_id=7')),
      throwsA(isA<ToneError>()),
    );
    final other = ToneAuthorization('publishable-test');
    expect(
      () => other.accept(
        Uri.parse(
          '$toneCallback?state=${other.state}&state=${other.state}&code=c&tone_id=7',
        ),
      ),
      throwsA(isA<ToneError>()),
    );
  });

  test('callbacks are single-use and cancellation remains distinct', () {
    final flow = ToneAuthorization('publishable-test');
    final callback = Uri.parse(toneCallback).replace(
      queryParameters: {'state': flow.state, 'code': 'c', 'tone_id': '7'},
    );
    expect(flow.accept(callback).toneId, 7);
    expect(() => flow.accept(callback), throwsA(isA<ToneError>()));
    final cancel = ToneAuthorization('publishable-test');
    expect(
      () => cancel.accept(
        Uri.parse('$toneCallback?state=${cancel.state}&canceled=true'),
      ),
      throwsA(isA<ToneCancelled>()),
    );
  });

  test(
    'secret keys are refused and no HTTP call is made on cancelled selection',
    () async {
      expect(() => Tone3000Api('t3k_cs_secret'), throwsA(isA<ToneError>()));
      final h = ToneHarness();
      addTearDown(h.api.close);
      await expectLater(
        h.api.select(
          (url) async => Uri.parse(toneCallback).replace(
            queryParameters: {
              'state': url.queryParameters['state']!,
              'canceled': 'true',
            },
          ),
        ),
        throwsA(isA<ToneCancelled>()),
      );
      expect(h.requests, isEmpty);
    },
  );

  test('choose, list A2 variants, explicitly download and validate the real parser', () async {
    final h = ToneHarness();
    addTearDown(h.api.close);
    final selection = await h.api.select(acceptBrowser);
    expect(selection.tone.creator.username, 'creator');
    expect(selection.account.username, 'listener');
    expect(selection.firstPage.models.map((m) => m.id), [11]);
    expect(h.downloads, 0);
    final imported = await h.api.download(
      selection.tone,
      selection.firstPage.models.single,
    );
    expect(imported.model.packet.length, 7548);
    expect(imported.model.name, 'Bass_Clean');
    expect(h.downloads, 1);
    final next = await h.api.listModels(7, page: 2);
    expect(next.page, 2);
  });

  test('a 401 refreshes once and retries with the new access token', () async {
    final h = ToneHarness()..rejectOnce = true;
    addTearDown(h.api.close);
    await h.api.select(acceptBrowser);
    expect(h.refreshes, 1);
    expect(h.requests.last.headers['Authorization'], 'Bearer access-new');
    h.rejectAlways = true;
    await expectLater(h.api.listModels(7), throwsA(isA<ToneError>()));
    expect(h.refreshes, 2); // One retry for the second operation, never a loop.
  });

  test(
    'non-A2-Lite or wrong sample rate never produces an imported model',
    () async {
      final h = ToneHarness();
      addTearDown(h.api.close);
      final selection = await h.api.select(acceptBrowser);
      final json = jsonDecode(utf8.decode(h.bytes)) as Map<String, dynamic>;
      json['sample_rate'] = 44100;
      h.bytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));
      await expectLater(
        h.api.download(selection.tone, selection.firstPage.models.single),
        throwsA(
          isA<ToneError>().having(
            (e) => e.message,
            'compatibility',
            contains('使用できません'),
          ),
        ),
      );
    },
  );

  test('oversized download is refused even before model parsing', () async {
    final h = ToneHarness()..advertiseOversize = true;
    addTearDown(h.api.close);
    final selection = await h.api.select(acceptBrowser);
    await expectLater(
      h.api.download(selection.tone, selection.firstPage.models.single),
      throwsA(
        isA<ToneError>().having((e) => e.message, 'limit', contains('8 MB')),
      ),
    );
  });

  test(
    'signed CDN redirect is followed without leaking the bearer credential',
    () async {
      final h = ToneHarness()
        ..redirect = 'https://cdn.example/model.nam?signature=test';
      addTearDown(h.api.close);
      final selection = await h.api.select(acceptBrowser);
      await h.api.download(selection.tone, selection.firstPage.models.single);
      expect(h.requests.last.url.host, 'cdn.example');
      expect(h.requests.last.headers.containsKey('Authorization'), isFalse);
    },
  );

  test('insecure redirect and arbitrary model_url are refused', () async {
    final h = ToneHarness()..redirect = 'http://cdn.example/model.nam';
    addTearDown(h.api.close);
    final selection = await h.api.select(acceptBrowser);
    await expectLater(
      h.api.download(selection.tone, selection.firstPage.models.single),
      throwsA(isA<ToneError>()),
    );
    final calls = h.requests.length;
    await expectLater(
      h.api.download(
        selection.tone,
        ToneModel(1, 7, 'bad', Uri.parse('https://other.example/model.nam')),
      ),
      throwsA(isA<ToneError>()),
    );
    expect(h.requests.length, calls);
  });

  test('HTTP permission and rate errors have actionable messages', () async {
    final h = ToneHarness()..downloadStatus = 429;
    addTearDown(h.api.close);
    final selection = await h.api.select(acceptBrowser);
    await expectLater(
      h.api.download(selection.tone, selection.firstPage.models.single),
      throwsA(
        isA<ToneError>().having(
          (e) => e.message,
          'rate limit',
          contains('少し待って'),
        ),
      ),
    );
  });
}
