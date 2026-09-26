import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/services/gemini_token_cache.dart';

/// Fake `/voice/gemini-token`: every call returns a pending fetch the test
/// completes by hand, minting tokens t1, t2, ... in call order.
class _FakeEndpoint {
  _FakeEndpoint(this.clock);

  final DateTime Function() clock;
  final List<Completer<GeminiToken>> pending = [];
  int calls = 0;

  Future<GeminiToken> fetch() {
    calls++;
    final completer = Completer<GeminiToken>();
    pending.add(completer);
    return completer.future;
  }

  /// Completes the oldest pending fetch with a token usable for [window].
  Future<void> respond({Duration window = const Duration(minutes: 10)}) async {
    final completer = pending.removeAt(0);
    completer.complete(GeminiToken('t${calls - pending.length}', clock().add(window)));
    await Future<void>.microtask(() {});
  }

  Future<void> fail() async {
    pending.removeAt(0).completeError(StateError('gemini-token request failed (502)'));
    await Future<void>.microtask(() {});
  }
}

void main() {
  late DateTime now;
  late _FakeEndpoint endpoint;
  late GeminiTokenCache cache;

  setUp(() {
    now = DateTime(2026, 9, 25, 9);
    endpoint = _FakeEndpoint(() => now);
    cache = GeminiTokenCache(fetch: endpoint.fetch, now: () => now);
  });

  tearDown(() => cache.deactivate());

  test('nothing is fetched until voice is live on a job', () {
    cache.prefetch();
    expect(endpoint.calls, 0);
  });

  test('a valid pre-fetched token is handed out without a network call', () async {
    cache.activate();
    await endpoint.respond();
    expect(cache.hasUsableSpare, isTrue);

    expect(await cache.take(), 't1');
    expect(endpoint.calls, 1, reason: 'take() used the spare, no second fetch');
  });

  test('a token is never handed out twice (single-use)', () async {
    cache.activate();
    await endpoint.respond();
    expect(await cache.take(), 't1');

    final second = cache.take();
    expect(endpoint.calls, 2, reason: 'the spare was consumed, so this fetches');
    await endpoint.respond();
    expect(await second, 't2');
  });

  test('an expired or nearly-expired spare is not used; falls back to fetching', () async {
    cache.activate();
    await endpoint.respond(window: const Duration(minutes: 10));

    // 15s of start window left, under the 20s minimum needed to connect.
    now = now.add(const Duration(minutes: 9, seconds: 45));
    expect(cache.hasUsableSpare, isFalse);

    final token = cache.take();
    expect(endpoint.calls, 2);
    await endpoint.respond();
    expect(await token, 't2');
  });

  test('overlapping requests share one in-flight fetch', () async {
    cache.activate(); // starts fetch #1
    cache.prefetch(); // e.g. a rapid screen swap re-entering job scope
    cache.activate();
    expect(endpoint.calls, 1);

    final token = cache.take(); // wake word while #1 is still in flight
    expect(endpoint.calls, 1, reason: 'take() joins the in-flight fetch');
    await endpoint.respond();
    expect(await token, 't1');
    expect(cache.hasUsableSpare, isFalse, reason: 'the joined result went to the session, not the cache');
  });

  test('a second session while the first is still waiting fetches its own token', () async {
    cache.activate();
    final first = cache.take();
    final second = cache.take();
    expect(endpoint.calls, 2);
    await endpoint.respond();
    await endpoint.respond();
    expect({await first, await second}, {'t1', 't2'});
  });

  test('clearing (logout / leaving the job) drops the spare and ignores a late fetch', () async {
    cache.activate();
    await endpoint.respond();
    cache.prefetch();
    cache.deactivate();
    expect(cache.hasUsableSpare, isFalse);

    cache.activate(); // starts fetch #2
    cache.deactivate(); // ...then leave before it returns
    await endpoint.respond();
    expect(cache.hasUsableSpare, isFalse, reason: 'a fetch from before the clear must not repopulate it');
  });

  test('a failed background prefetch degrades to fetching on demand', () async {
    cache.activate();
    await endpoint.fail();
    expect(cache.hasUsableSpare, isFalse);
    expect(cache.hasFetchInFlight, isFalse);

    final token = cache.take();
    expect(endpoint.calls, 2);
    await endpoint.respond();
    expect(await token, 't2');
  });

  test('an on-demand fetch failure reaches the session as an error, same as before', () async {
    final token = cache.take();
    final expectation = expectLater(token, throwsStateError);
    await endpoint.fail();
    await expectation;
  });

  testWidgets('the spare is replaced a minute before its start window closes', (tester) async {
    cache.activate();
    await endpoint.respond(window: const Duration(minutes: 10));
    expect(endpoint.calls, 1);

    now = now.add(const Duration(minutes: 8, seconds: 59));
    await tester.pump(const Duration(minutes: 8, seconds: 59));
    expect(endpoint.calls, 1, reason: 'not yet');

    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(endpoint.calls, 2, reason: 'refresh fires at window - 60s');
    expect(cache.hasUsableSpare, isTrue, reason: 'old spare stays usable until the new one lands');

    await endpoint.respond();
    expect(await cache.take(), 't2');
  });

  testWidgets('a short-window token (old backend) is fetched once, not refreshed in a loop', (tester) async {
    cache.activate();
    await endpoint.respond(window: const Duration(seconds: 50));
    now = now.add(const Duration(minutes: 5));
    await tester.pump(const Duration(minutes: 5));
    expect(endpoint.calls, 1);
  });

  testWidgets('no refresh keeps running after deactivate', (tester) async {
    cache.activate();
    await endpoint.respond();
    cache.deactivate();
    now = now.add(const Duration(minutes: 30));
    await tester.pump(const Duration(minutes: 30));
    expect(endpoint.calls, 1);
  });
}
