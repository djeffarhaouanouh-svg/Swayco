import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/services/attribution.dart';

void main() {
  Future<void> run({
    required Future<bool> Function() claim,
    required void Function() send,
    required Future<void> Function() confirm,
  }) => Attribution.runEngagedCheck(claim: claim, send: send, confirm: confirm);

  test('claim granted: event sent once, then confirmed', () async {
    final log = <String>[];
    await run(
      claim: () async => true,
      send: () => log.add('send'),
      confirm: () async => log.add('confirm'),
    );
    expect(log, ['send', 'confirm']);
  });

  test('claim refused (conditions unmet or already sent): nothing sent',
      () async {
    final log = <String>[];
    await run(
      claim: () async => false,
      send: () => log.add('send'),
      confirm: () async => log.add('confirm'),
    );
    expect(log, isEmpty);
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
          send: () => sends++,
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
      send: () => sends++,
      confirm: () async {},
    );
    expect(sends, 0);
    await run(
      claim: () async => true,
      send: () => sends++,
      confirm: () async {},
    );
    expect(sends, 1);
  });

  test('confirm failure after send does not throw (lease expiry retries)',
      () async {
    var sends = 0;
    await run(
      claim: () async => true,
      send: () => sends++,
      confirm: () async => throw Exception('offline'),
    );
    expect(sends, 1);
  });
}
