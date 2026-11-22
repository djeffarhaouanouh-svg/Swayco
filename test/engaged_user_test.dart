import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/attribution.dart';

void main() {
  setUp(Attribution.resetEngagedForTest);

  Future<bool> run({
    required Future<bool> Function() claim,
    required Future<void> Function() send,
    required Future<void> Function() confirm,
  }) => Attribution.runEngagedCheck(claim: claim, send: send, confirm: confirm);

  test('claim granted: SDK send acknowledged, THEN confirmed', () async {
    final log = <String>[];
    final done = await run(
      claim: () async => true,
      send: () async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        log.add('send');
      },
      confirm: () async => log.add('confirm'),
    );
    expect(log, ['send', 'confirm']);
    expect(done, isTrue);
  });

  test('claim refused (conditions unmet or already sent): nothing sent',
      () async {
    final log = <String>[];
    final done = await run(
      claim: () async => false,
      send: () async => log.add('send'),
      confirm: () async => log.add('confirm'),
    );
    expect(log, isEmpty);
    expect(done, isFalse);
  });

  test('SDK send FAILS: server is NOT told "sent" (lease expires, retried)',
      () async {
    var confirms = 0;
    final done = await run(
      claim: () async => true,
      send: () async => throw Exception('AppsFlyer rejected'),
      confirm: () async => confirms++,
    );
    expect(confirms, 0);
    expect(done, isFalse);
  });

  test('SDK send times out: not confirmed, no hang afterwards', () async {
    var confirms = 0;
    final done = await run(
      claim: () async => true,
      send: () => Completer<void>()
          .future
          .timeout(const Duration(milliseconds: 20)),
      confirm: () async => confirms++,
    );
    expect(confirms, 0);
    expect(done, isFalse);
    // The in-flight latch is released: a later trigger can retry.
    var sends = 0;
    final retried = await run(
      claim: () async => true,
      send: () async => sends++,
      confirm: () async {},
    );
    expect(sends, 1);
    expect(retried, isTrue);
  });

  test('failed send, then a later trigger retries and succeeds once',
      () async {
    var attempts = 0;
    var confirms = 0;
    Future<bool> attempt() => run(
      claim: () async => true,
      send: () async {
        attempts++;
        if (attempts == 1) throw Exception('offline');
      },
      confirm: () async => confirms++,
    );
    expect(await attempt(), isFalse);
    expect(await attempt(), isTrue);
    expect(attempts, 2);
    expect(confirms, 1);
  });

  test('burst of triggers on one device: a single claim and a single send',
      () async {
    var claims = 0;
    var sends = 0;
    final gate = Completer<bool>();
    final runs = [
      for (var i = 0; i < 5; i++)
        run(
          claim: () {
            claims++;
            return gate.future;
          },
          send: () async => sends++,
          confirm: () async {},
        ),
    ];
    gate.complete(true);
    await Future.wait(runs);
    expect(claims, 1);
    expect(sends, 1);
  });

  test('claim error: no event, no crash, and a later check can retry',
      () async {
    var sends = 0;
    await run(
      claim: () async => throw Exception('network'),
      send: () async => sends++,
      confirm: () async {},
    );
    expect(sends, 0);
    await run(
      claim: () async => true,
      send: () async => sends++,
      confirm: () async {},
    );
    expect(sends, 1);
  });

  test('confirm failure after a successful send does not throw', () async {
    var sends = 0;
    final done = await run(
      claim: () async => true,
      send: () async => sends++,
      confirm: () async => throw Exception('offline'),
    );
    expect(sends, 1);
    expect(done, isFalse);
  });
}
