import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fb200_nam/tone3000.dart';
import 'package:fb200_nam/tone_library.dart';

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

/// A second A2 variant of tone 7 for bulk downloads.
Map<String, dynamic> variant(int id, String name) => {
  ...modelFixture,
  'id': id,
  'name': name,
  'model_url':
      'https://www.tone3000.com/api/v1/models/$id/download?architecture=2',
};

/// Free-tier lists mix formats and A1-only packs; only A2 NAM may remain.
final shelfFixture = [
  {...toneFixture, 'a2_models_count': 2},
  {...toneFixture, 'id': 8, 'title': 'Spring IR', 'format': 'ir'},
  {...toneFixture, 'id': 9, 'title': 'Old A1 Amp', 'a2_models_count': 0},
  {'id': 10, 'format': 'nam'},
];

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
  final MemoryToneSessionStore sessions;
  Uint8List bytes = modelBytes();
  final bytesFor = <int, Uint8List>{};
  int downloads = 0, refreshes = 0, downloadStatus = 200;
  bool rejectOnce = false, rejectAlways = false, advertiseOversize = false;
  bool rejectRefresh = false, expireAccess = false;
  String? redirect, retryAfter;
  Map<String, dynamic> metadata = Map.of(modelFixture);
  List<Map<String, dynamic>> extraModels = [];

  /// Holds token responses until completed, to observe concurrent refreshes.
  Completer<void>? tokenGate;
  ToneHarness({MemoryToneSessionStore? sessions})
    : sessions = sessions ?? MemoryToneSessionStore();
  late final Tone3000Api api = Tone3000Api(
    'publishable-test',
    sessions: sessions,
    requestInterval: Duration.zero,
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
      final query = request.url.queryParameters;
      if (path.endsWith('/oauth/token')) {
        await tokenGate?.future;
        final fields = Uri.splitQueryString(req.body);
        expect(fields['client_id'], 'publishable-test');
        if (fields['grant_type'] == 'refresh_token') {
          refreshes++;
          expect(fields['refresh_token'], 'refresh-test');
          if (rejectRefresh) {
            return result({'error': 'invalid_grant'}, status: 400);
          }
        } else {
          expect(fields['grant_type'], 'authorization_code');
          expect(fields['code_verifier']!.length, inInclusiveRange(43, 128));
          expect(fields['redirect_uri'], toneCallback);
        }
        return result({
          'access_token': refreshes == 0 ? 'access-test' : 'access-new',
          'refresh_token': 'refresh-test',
          'expires_in': expireAccess ? 1 : 3600,
        });
      }
      if (request.url.host != 'cdn.example') {
        expect(request.headers['Authorization'], startsWith('Bearer access-'));
      }
      if (path.endsWith('/tones/7')) return result(toneFixture);
      if (path.endsWith('/user')) {
        return result({'username': 'listener', 'avatar_url': null});
      }
      if (RegExp(r'/tones/(favorited|downloaded|created)$').hasMatch(path)) {
        expect(query['page_size'], '25');
        return result({
          'page': int.parse(query['page']!),
          'total_pages': 1,
          'data': shelfFixture,
        });
      }
      if (RegExp(r'/tones/(trending|latest)$').hasMatch(path)) {
        expect(query.containsKey('page'), isFalse);
        return result(shelfFixture);
      }
      if (path.endsWith('/models')) {
        if (rejectAlways || rejectOnce) {
          rejectOnce = false;
          return result({'error': 'do not display raw errors'}, status: 401);
        }
        expect(query['architecture'], '2');
        return result({
          'page': int.parse(query['page']!),
          'total_pages': query['page_size'] == '300' ? 1 : 2,
          'data': [
            metadata,
            {...metadata, 'id': 12, 'architecture_version': 1},
            ...extraModels,
          ],
        });
      }
      if (path.contains('/download') || request.url.host == 'cdn.example') {
        downloads++;
        if (retryAfter != null) {
          final wait = retryAfter!;
          retryAfter = null;
          return result({}, status: 429, headers: {'retry-after': wait});
        }
        if (redirect != null && request.url.host != 'cdn.example') {
          return http.StreamedResponse(
            const Stream.empty(),
            302,
            headers: {'location': redirect!},
          );
        }
        final id = int.tryParse(path.split('/').reversed.elementAt(1));
        final data = bytesFor[id] ?? bytes;
        return http.StreamedResponse(
          Stream.value(data),
          downloadStatus,
          contentLength: advertiseOversize ? toneModelLimit + 1 : data.length,
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

  test(
    'sign-in persists only the refresh token and a new client resumes it',
    () async {
      final h = ToneHarness();
      addTearDown(h.api.close);
      await h.api.select(acceptBrowser);
      expect(h.sessions.clientId, 'publishable-test');
      expect(h.sessions.refreshToken, 'refresh-test');

      final resumed = ToneHarness(sessions: h.sessions);
      addTearDown(resumed.api.close);
      final account = await resumed.api.restore();
      expect(account?.username, 'listener');
      expect(resumed.refreshes, 1);
      expect(resumed.api.signedIn, isTrue);
      expect(
        resumed.requests
            .where((r) => r.url.path.endsWith('/user'))
            .single
            .headers['Authorization'],
        'Bearer access-new',
      );
    },
  );

  test('a stored session for another key is never sent', () async {
    final sessions = MemoryToneSessionStore()
      ..clientId = 'other-key'
      ..refreshToken = 'refresh-test';
    final h = ToneHarness(sessions: sessions);
    addTearDown(h.api.close);
    expect(await h.api.restore(), isNull);
    expect(h.requests, isEmpty);
  });

  test('a rejected refresh forgets the stored session', () async {
    final sessions = MemoryToneSessionStore()
      ..clientId = 'publishable-test'
      ..refreshToken = 'refresh-test';
    final h = ToneHarness(sessions: sessions)..rejectRefresh = true;
    addTearDown(h.api.close);
    expect(await h.api.restore(), isNull);
    expect(h.api.signedIn, isFalse);
    expect(sessions.refreshToken, isNull);
  });

  test('sign-out clears the stored session', () async {
    final h = ToneHarness();
    addTearDown(h.api.close);
    await h.api.select(acceptBrowser);
    await h.api.signOut();
    expect(h.api.signedIn, isFalse);
    expect(h.sessions.refreshToken, isNull);
  });

  test('parallel requests share one refresh of an expired token', () async {
    final sessions = MemoryToneSessionStore()
      ..clientId = 'publishable-test'
      ..refreshToken = 'refresh-test';
    final h = ToneHarness(sessions: sessions);
    addTearDown(h.api.close);
    h.tokenGate = Completer<void>();
    final restored = h.api.restore();
    await Future<void>.delayed(Duration.zero);
    final parallel = h.api.listModels(7);
    h.tokenGate!.complete();
    await Future.wait([restored, parallel]);
    expect(h.refreshes, 1);
  });

  test('free-tier lists keep only A2 NAM tones and pass filters', () async {
    final h = ToneHarness();
    addTearDown(h.api.close);
    await h.api.select(acceptBrowser);
    final page = await h.api.listTones(
      ToneShelf.favorited,
      query: ' bass ',
      gear: 'amp-cab',
    );
    expect(page.tones.map((t) => t.id), [7]);
    expect(page.tones.single.a2Count, 2);
    final q = h.requests.last.url.queryParameters;
    expect(q['query'], 'bass');
    expect(q['gear'], 'amp-cab');
    expect(q['page'], '1');

    final trending = await h.api.listTones(
      ToneShelf.trending,
      query: 'nomatch',
    );
    expect(trending.tones, isEmpty);
    expect(h.requests.last.url.queryParameters.containsKey('query'), isFalse);
    final latest = await h.api.listTones(ToneShelf.latest, gear: 'amp-cab');
    expect(latest.tones.map((t) => t.title), ['Bass Full Rig']);
    expect(h.requests.last.url.queryParameters.containsKey('gear'), isFalse);
  });

  test(
    'search API is not called unless enabled for an agreement build',
    () async {
      final h = ToneHarness();
      addTearDown(h.api.close);
      await h.api.select(acceptBrowser);
      final calls = h.requests.length;
      await expectLater(
        h.api.listTones(ToneShelf.search, query: 'bass'),
        throwsA(isA<ToneError>()),
      );
      expect(h.requests.length, calls);
    },
    skip: toneSearchEnabled,
  );

  test('a short Retry-After is honoured once', () async {
    final h = ToneHarness()..retryAfter = '0';
    addTearDown(h.api.close);
    final selection = await h.api.select(acceptBrowser);
    final imported = await h.api.download(
      selection.tone,
      selection.firstPage.models.single,
    );
    expect(imported.model.packet.length, 7548);
    expect(h.downloads, 2);
  });

  test('requests are paced below the documented rate limit', () async {
    final api = Tone3000Api(
      'publishable-test',
      requestInterval: const Duration(milliseconds: 40),
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'access_token': 'a',
            'refresh_token': 'r',
            'expires_in': 3600,
          }),
          400,
        ),
      ),
    );
    addTearDown(api.close);
    final watch = Stopwatch()..start();
    for (var i = 0; i < 3; i++) {
      await expectLater(
        api.select(
          (url) async => Uri.parse(toneCallback).replace(
            queryParameters: {
              'state': url.queryParameters['state']!,
              'code': 'c',
              'tone_id': '7',
            },
          ),
        ),
        throwsA(isA<ToneError>()),
      );
    }
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(80));
  });

  group('library', () {
    late ToneHarness h;
    late MemoryLibraryStorage storage;
    late ToneLibrary library;
    setUp(() async {
      h = ToneHarness()
        ..extraModels = [variant(13, 'Bass Drive'), variant(14, 'Bass Fuzz')]
        ..bytesFor[14] = File('test/fixtures/synthetic.fbnm').readAsBytesSync();
      storage = MemoryLibraryStorage();
      library = ToneLibrary(storage);
      await h.api.select(acceptBrowser);
    });
    tearDown(() => h.api.close());

    test('bulk download stores compatible A2 variants once', () async {
      final tone = TonePack.parse(toneFixture);
      final downloader = ToneDownloader(library);
      await downloader.run(h.api, [ToneDownloadJob(tone)]);
      expect(downloader.total, 3);
      expect(downloader.saved, 2);
      expect(downloader.incompatible, 1);
      expect(downloader.failed, 0);
      expect(library.entries.map((e) => e.variant.id).toSet(), {11, 13});
      expect(library.storedFor(7), 2);
      expect(storage.models.keys.toSet(), {11, 13});

      final before = h.downloads;
      await downloader.run(h.api, [ToneDownloadJob(tone)]);
      expect(downloader.existing, 2);
      expect(downloader.saved, 0);
      expect(h.downloads - before, 1); // Only the incompatible one again.
    });

    test('selected variants only, and the index survives a restart', () async {
      final tone = TonePack.parse(toneFixture);
      final models = await h.api.listAllModels(7);
      await ToneDownloader(library).run(h.api, [
        ToneDownloadJob(tone, models.where((m) => m.id == 13).toList()),
      ]);
      final reopened = ToneLibrary(storage);
      await reopened.load();
      final entry = reopened.entries.single;
      expect(entry.variant.name, 'Bass Drive');
      expect(entry.tone.creator.username, 'creator');
      expect(entry.matches('drive @creator'), isTrue);
      expect(entry.matches('fuzz'), isFalse);
      final imported = await reopened.open(entry);
      expect(imported.model.name, 'Bass_Drive');
      expect(imported.model.packet.length, 7548);
      await reopened.remove([13]);
      expect(reopened.entries, isEmpty);
      expect(storage.models, isEmpty);
    });

    test('cancel stops before the remaining downloads', () async {
      final tone = TonePack.parse(toneFixture);
      final downloader = ToneDownloader(library);
      downloader.addListener(() {
        if (downloader.saved == 1) downloader.cancel();
      });
      await downloader.run(h.api, [ToneDownloadJob(tone)]);
      expect(downloader.running, isFalse);
      expect(downloader.finished, lessThan(3));
    });
  });

  test('file storage keeps gzip models and an atomic index', () async {
    final dir = await Directory.systemTemp.createTemp('tone-library');
    addTearDown(() => dir.delete(recursive: true));
    final storage = FileLibraryStorage(() async => dir);
    final library = ToneLibrary(storage);
    final tone = TonePack.parse(toneFixture);
    final model = ToneModel.parse(modelFixture);
    await library.store(tone, model, modelBytes());
    expect(File('${dir.path}/models/11.nam.gz').existsSync(), isTrue);
    expect(File('${dir.path}/index.json').existsSync(), isTrue);
    expect(File('${dir.path}/index.json.part').existsSync(), isFalse);
    final reopened = ToneLibrary(FileLibraryStorage(() async => dir));
    await reopened.load();
    final imported = await reopened.open(reopened.entries.single);
    expect(imported.model.packet.length, 7548);
    await expectLater(
      library.store(
        tone,
        ToneModel.parse(variant(14, 'Bad')),
        File('test/fixtures/synthetic.fbnm').readAsBytesSync(),
      ),
      throwsA(isA<ToneIncompatible>()),
    );
    expect(File('${dir.path}/models/14.nam.gz').existsSync(), isFalse);
  });
}
