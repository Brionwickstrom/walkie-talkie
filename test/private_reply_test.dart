// v1.5.4: after private audio from a friend, the big talk button (and talk
// keys / toggle) reply privately to that friend, never the channel.
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/private_reply.dart';

void main() {
  late DateTime now;
  late PrivateReply reply;
  late List<String> sent;
  int? talkingTo;
  late bool refuse;
  late MainTalkRouter router;

  setUp(() {
    now = DateTime(2026, 10, 25, 19, 30);
    reply = PrivateReply(clock: () => now);
    sent = [];
    talkingTo = null;
    refuse = false;
    router = MainTalkRouter(
      reply: reply,
      talkPrivate: (id, down) async {
        if (down && refuse) return false;
        sent.add('private $id ${down ? 'down' : 'up'}');
        talkingTo = down ? id : null;
        return true;
      },
      talkChannel: (down) async => sent.add('channel ${down ? 'down' : 'up'}'),
      privateTalkTo: () => talkingTo,
    );
  });

  Future<void> hold() async {
    await router.talk(true);
    await router.talk(false);
  }

  test('no private audio: big button talks to the channel', () async {
    expect(reply.target, isNull);
    await hold();
    expect(sent, ['channel down', 'channel up']);
  });

  test('after private audio: big button replies privately', () async {
    reply.heard(7);
    now = now.add(const Duration(seconds: 5));
    expect(reply.target, 7);
    await hold();
    expect(sent, ['private 7 down', 'private 7 up']);
  });

  test('reply mode lasts 30 s after the last private audio', () async {
    reply.heard(7);
    now = now.add(const Duration(seconds: 29));
    expect(reply.target, 7);
    expect(reply.secondsLeft, 1);
    now = now.add(const Duration(seconds: 2));
    expect(reply.target, isNull);
    await hold();
    expect(sent, ['channel down', 'channel up']);
  });

  test('each private reply keeps the conversation private', () async {
    reply.heard(7);
    now = now.add(const Duration(seconds: 25));
    await hold(); // reply at 25 s renews the window
    now = now.add(const Duration(seconds: 25));
    expect(reply.target, 7);
  });

  test('"Talk to channel instead" goes back to the channel', () async {
    reply.heard(7);
    reply.dismiss();
    expect(reply.target, isNull);
    await hold();
    expect(sent, ['channel down', 'channel up']);
  });

  test('release after the window still stops the private talk', () async {
    reply.heard(7);
    await router.talk(true);
    now = now.add(const Duration(minutes: 1)); // held a long time
    await router.talk(false);
    expect(sent, ['private 7 down', 'private 7 up']);
  });

  test('refused private talk never falls back to the channel', () async {
    reply.heard(7);
    refuse = true; // e.g. "needs to update" or not connected
    await hold();
    expect(sent.where((s) => s.startsWith('channel')), isEmpty);
  });

  test('latest friend wins', () async {
    reply.heard(7);
    reply.heard(9);
    await hold();
    expect(sent, ['private 9 down', 'private 9 up']);
  });
}
