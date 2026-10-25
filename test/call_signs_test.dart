import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/call_signs.dart';
import 'package:walkie_talkie/app/settings.dart';
import 'package:walkie_talkie/core/peer.dart';

void main() {
  test('curated list is big, unique and clean-ish', () {
    expect(callSigns.length, greaterThanOrEqualTo(100));
    expect(callSigns.toSet().length, callSigns.length);
    for (final s in callSigns) {
      expect(s.trim(), s);
      expect(s.length, lessThanOrEqualTo(24));
    }
  });

  test('same id always gives the same call sign', () {
    for (final id in [1, 0x38EA1234, 0xFFFFFFFF, 424242]) {
      expect(callSignFor(id), callSignFor(id));
      expect(callSigns, contains(callSignFor(id)));
    }
    expect(AppSettings.defaultNameFor(77), callSignFor(77));
  });

  test('ids spread over the list', () {
    final used = {for (var i = 1; i <= 2000; i++) callSignFor(i * 7919)};
    expect(used.length, greaterThan(callSigns.length * 0.8));
  });

  test('reroll (salt) changes the call sign, stays deterministic', () {
    const id = 0x1234ABCD;
    final names = {for (var s = 0; s < 6; s++) callSignFor(id, salt: s)};
    expect(names.length, greaterThan(3));
    expect(callSignFor(id, salt: 3), callSignFor(id, salt: 3));
  });

  test('settings: no custom name -> call sign, reroll via salt', () {
    final s = AppSettings(nodeId: 99, channel: 1);
    expect(s.name, callSignFor(99));
    s.callSignSalt = 1;
    expect(s.name, callSignFor(99, salt: 1));
    s.customName = 'Brion';
    expect(s.name, 'Brion');
    expect(s.hasCustomName, isTrue);
  });

  test('old "Phone 38EA" default saved as custom name is replaced', () {
    const id = 0x38EA0001;
    final legacy = AppSettings.legacyDefaultNameFor(id);
    expect(legacy, 'Phone 38EA');
    final s = AppSettings(nodeId: id, channel: 1, customName: legacy);
    expect(s.customName, isNull);
    expect(s.name, callSignFor(id));
    final kept = AppSettings(nodeId: id, channel: 1, customName: 'Phone 1234');
    expect(kept.name, 'Phone 1234');
  });

  test('peer without a name yet shows its call sign', () {
    expect(Peer(5).displayName, callSignFor(5));
  });

  test('settings round-trip through memory store', () async {
    final store = MemorySettingsStore();
    final s = await store.load(defaultChannel: 1);
    expect(s.stayReachable, isTrue);
    expect(s.startOnBoot, isFalse);
    s.callSignSalt = 4;
    await store.save(s);
    expect((await store.load(defaultChannel: 1)).callSignSalt, 4);
  });
}
