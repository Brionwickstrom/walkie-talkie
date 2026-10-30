import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:walkie_talkie/app/settings.dart';
import 'package:walkie_talkie/app/walkie_controller.dart';
import 'package:walkie_talkie/gateway/stream_wire.dart';
import 'package:walkie_talkie/lora/meshtastic_ble.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/protobuf.dart';
import 'package:walkie_talkie/lora/saved_radios.dart';
import 'package:walkie_talkie/lora/stream_radio.dart';
import 'package:walkie_talkie/platform/platform_caps.dart';
import 'package:walkie_talkie/ui/radio_settings.dart';

import 'lora_proto_test.dart' show configComplete, myInfo, nodeInfo;
import 'v231_helpers.dart' show phone, quietPlugins;

// v2.5.4: saved radios. Radios here are pretend USB radios behind
// StreamWire; nothing touches a real port.

/// Pretend USB radios by port id: (node number, long name, short name).
class UsbRadios {
  UsbRadios(this.radios);
  final Map<String, (int, String, String)> radios;
  final opened = <String>[];
  final closed = <String>[];
  var open = 0;
  var maxOpen = 0;

  List<String> get present => radios.keys.toList();

  Future<StreamRadioConnection> openFn(String id) async {
    final r = radios[id];
    if (r == null) throw StateError('no such port');
    opened.add(id);
    open++;
    maxOpen = max(maxOpen, open);
    final inC = StreamController<List<int>>();
    final framer = StreamFramer();
    late final StreamWire wire;
    wire = StreamWire(inC.stream, (bytes) async {
      for (final p in framer.add(bytes)) {
        for (final f in pbDecode(p)) {
          if (f.number != 3) continue;
          final n = f.asInt;
          scheduleMicrotask(() {
            if (inC.isClosed) return;
            inC.add(StreamFramer.frame(myInfo(r.$1)));
            inC.add(StreamFramer.frame(nodeInfo(r.$1, r.$2, r.$3)));
            inC.add(StreamFramer.frame(configComplete(n)));
          });
        }
      }
    });
    return StreamRadioConnection(wire, () async {
      open--;
      closed.add(id);
      await wire.close();
      await inC.close();
    });
  }
}

Future<void> until(bool Function() ok, {int ms = 4000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

Future<WalkieController> load(
  AppSettings s, {
  UsbRadios? usb,
  List<String>? ports,
}) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  quietPlugins();
  SharedPreferences.setMockInitialValues({});
  PlatformCaps.debugDesktop = true;
  final c = await WalkieController.load(store: MemorySettingsStore(s));
  if (usb != null) {
    c.radioDevice
      ..openStream = usb.openFn
      ..usbRadios = (() => ports ?? usb.present);
  }
  addTearDown(c.dispose);
  return c;
}

AppSettings base({String? id, String? name, List<SavedRadio>? saved}) =>
    AppSettings(
      nodeId: 0x1234,
      channel: 1,
      radioId: id,
      radioName: name,
      savedRadios: saved,
    );

const a = 'serial:COM3';
const b = 'serial:COM5';
FoundRadio found(String id) => FoundRadio(id, StreamRadioId.label(id), 0);

void main() {
  tearDown(() => PlatformCaps.debugDesktop = null);

  group('SavedRadio', () {
    test('json round trip, tolerant decode, no duplicates', () {
      final r = SavedRadio(
        id: 'serial:COM7',
        name: 'Ridge',
        shortName: 'RDG',
        nodeId: 0xABCD,
        label: 'Truck',
        lastConnected: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final back = SavedRadio.decodeList(SavedRadio.encodeList([r, r])).single;
      expect(back.id, 'serial:COM7');
      expect(back.name, 'Ridge');
      expect(back.shortName, 'RDG');
      expect(back.nodeId, 0xABCD);
      expect(back.label, 'Truck');
      expect(back.lastConnected, r.lastConnected);
      expect(SavedRadio.decodeList(null), isEmpty);
      expect(SavedRadio.decodeList('not json'), isEmpty);
      expect(SavedRadio.decodeList('[1,{"x":2},{"id":"A"}]').single.id, 'A');
    });

    test('title: your name, then the radio\'s, then the port', () {
      final r = SavedRadio(id: 'serial:COM7');
      expect(r.title, 'USB radio on COM7');
      expect(SavedRadio(id: 'AA:BB').title, 'Radio');
      r.name = 'Ridge';
      expect(r.title, 'Ridge');
      r.label = ' Truck ';
      expect(r.title, 'Truck');
    });

    test('kind says how it connects', () {
      expect(SavedRadio(id: 'AA:BB:CC').kind, 'Bluetooth');
      expect(SavedRadio(id: 'serial:COM7').kind, 'USB cable on COM7');
      expect(
        SavedRadio(id: 'tcp:192.168.1.40:4403').kind,
        'Wi-Fi 192.168.1.40',
      );
      expect(SavedRadio(id: 'tcp:h:4404').kind, 'Wi-Fi h:4404');
    });

    test('last seen wording', () {
      final n = DateTime(2026, 10, 30, 12);
      expect(radioSeen(n, now: n), 'just now');
      expect(
        radioSeen(n.subtract(const Duration(minutes: 5)), now: n),
        '5 min ago',
      );
      expect(
        radioSeen(n.subtract(const Duration(hours: 3)), now: n),
        '3 h ago',
      );
      expect(
        radioSeen(n.subtract(const Duration(days: 4)), now: n),
        '4 days ago',
      );
    });
  });

  group('settings', () {
    test('saved radios and the one in use are stored (old key kept)', () async {
      SharedPreferences.setMockInitialValues({});
      const store = SharedPrefsSettingsStore();
      final s = AppSettings(
        nodeId: 1,
        channel: 1,
        radioId: a,
        radioName: 'Alpha',
        savedRadios: [SavedRadio(id: a, name: 'Alpha', nodeId: 7)],
      );
      await store.save(s);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lora_radio_id'), a);
      final back = await store.load(defaultChannel: 1);
      expect(back.radioId, a);
      expect(back.savedRadios.single.nodeId, 7);
    });

    test(
      'an older install with one radio gets it as the first entry',
      () async {
        final c = await load(base(id: 'AA:BB', name: 'RAK WisMesh'));
        expect(c.savedRadios.map((r) => r.id), ['AA:BB']);
        expect(c.savedRadios.single.name, 'RAK WisMesh');
        expect(c.activeRadio?.id, 'AA:BB');
        expect(c.radioPaired, isTrue);
      },
    );

    test('nothing is added twice, and no radio means an empty list', () async {
      final c = await load(
        base(
          id: 'AA:BB',
          saved: [SavedRadio(id: 'AA:BB', label: 'Mine')],
        ),
      );
      expect(c.savedRadios, hasLength(1));
      expect(c.savedRadios.single.label, 'Mine');
      final d = await load(base());
      expect(d.savedRadios, isEmpty);
      expect(d.activeRadio, isNull);
    });
  });

  group('connecting', () {
    test('a connected radio is remembered with its names and node', () async {
      final usb = UsbRadios({a: (0x11, 'Alpha', 'ALP')});
      final c = await load(base(), usb: usb);
      expect(await c.pairRadio(found(a)), isNull);
      await until(() => c.radioDevice.ready);
      final r = c.savedRadios.single;
      expect(r.id, a);
      expect(r.name, 'Alpha');
      expect(r.shortName, 'ALP');
      expect(r.nodeId, 0x11);
      expect(r.lastConnected, isNotNull);
      expect(c.settings.radioId, a);
      expect(c.settings.radioName, 'Alpha');
      expect(c.activeRadio?.title, 'Alpha');
    });

    test('a new name from the radio is kept up to date', () async {
      final usb = UsbRadios({a: (0x11, 'Alpha', 'ALP')});
      final c = await load(base(), usb: usb);
      await c.pairRadio(found(a));
      await until(() => c.radioDevice.ready);
      c.radioDevice.session!.handle(
        FromRadio.tryDecode(nodeInfo(0x11, 'Alpha 2', 'AL2'))!,
      );
      await until(() => c.savedRadios.single.name == 'Alpha 2');
      expect(c.savedRadios.single.shortName, 'AL2');
      expect(c.settings.radioName, 'Alpha 2');
    });

    test('switching disconnects the old radio before the new one', () async {
      final usb = UsbRadios({
        a: (0x11, 'Alpha', 'ALP'),
        b: (0x22, 'Beta', 'BET'),
      });
      final c = await load(base(), usb: usb);
      await c.pairRadio(found(a));
      await until(() => c.radioDevice.ready);
      await c.pairRadio(found(b));
      await until(() => c.radioDevice.ready && c.radioDevice.deviceId == b);
      expect(c.radioDevice.session!.myNodeNum, 0x22);
      expect(usb.maxOpen, 1);
      expect(usb.closed, contains(a));
      expect(c.savedRadios.map((r) => r.id), [a, b]);
      expect(c.activeRadio?.id, b);

      expect(await c.switchRadio(a), isNull);
      await until(() => c.radioDevice.ready && c.radioDevice.deviceId == a);
      expect(c.radioDevice.session!.myNodeNum, 0x11);
      expect(c.settings.radioId, a);
      expect(usb.maxOpen, 1);
    });

    test(
      'switching is blocked while talking and while settings write',
      () async {
        final usb = UsbRadios({
          a: (0x11, 'Alpha', 'ALP'),
          b: (0x22, 'Beta', 'BET'),
        });
        final c = await load(base(), usb: usb);
        await c.pairRadio(found(a));
        await until(() => c.radioDevice.ready);
        await c.pairRadio(found(b));
        await until(() => c.radioDevice.deviceId == b && c.radioDevice.ready);
        c.transmitting = true;
        expect(await c.switchRadio(a), contains('talk'));
        expect(await c.pairRadio(found('serial:COM9')), contains('talk'));
        expect(await c.disconnectRadio(), contains('talk'));
        expect(c.radioDevice.deviceId, b);
        expect(c.savedRadios.map((r) => r.id), [a, b]);
        c.transmitting = false;
        c.radioEditing = true;
        expect(await c.switchRadio(a), contains('changed'));
        c.radioEditing = false;
        expect(await c.switchRadio(a), isNull);
      },
    );

    test('choosing the radio already in use does nothing', () async {
      final usb = UsbRadios({a: (0x11, 'Alpha', 'ALP')});
      final c = await load(base(), usb: usb);
      await c.pairRadio(found(a));
      await until(() => c.radioDevice.ready);
      c.transmitting = true;
      expect(await c.switchRadio(a), isNull);
      expect(await c.pairRadio(found(a)), isNull);
      expect(usb.opened, [a]);
    });
  });

  group('disconnect, remove, rename', () {
    test('disconnect keeps the radio in the list', () async {
      final usb = UsbRadios({a: (0x11, 'Alpha', 'ALP')});
      final c = await load(base(), usb: usb);
      await c.pairRadio(found(a));
      await until(() => c.radioDevice.ready);
      expect(await c.disconnectRadio(), isNull);
      expect(c.radioPaired, isFalse);
      expect(c.settings.radioId, isNull);
      expect(c.radioDevice.state, RadioState.none);
      expect(c.savedRadios.single.id, a);
      expect(c.savedRadios.single.nodeId, 0x11);
      // and it comes back with a tap
      await c.switchRadio(a);
      await until(() => c.radioDevice.ready);
      expect(c.activeRadio?.id, a);
    });

    test('remove takes the one in use out and disconnects it', () async {
      final usb = UsbRadios({
        a: (0x11, 'Alpha', 'ALP'),
        b: (0x22, 'Beta', 'BET'),
      });
      final c = await load(base(), usb: usb);
      await c.pairRadio(found(a));
      await until(() => c.radioDevice.ready);
      await c.pairRadio(found(b));
      await until(() => c.radioDevice.deviceId == b && c.radioDevice.ready);
      expect(await c.removeRadio(b), isNull);
      expect(c.savedRadios.map((r) => r.id), [a]);
      expect(c.radioPaired, isFalse);
      expect(c.settings.radioId, isNull);
      expect(c.settings.savedRadios.map((r) => r.id), [a]);
    });

    test('remove another radio leaves the connection alone', () async {
      final usb = UsbRadios({
        a: (0x11, 'Alpha', 'ALP'),
        b: (0x22, 'Beta', 'BET'),
      });
      final c = await load(base(), usb: usb);
      await c.pairRadio(found(a));
      await until(() => c.radioDevice.ready);
      await c.pairRadio(found(b));
      await until(() => c.radioDevice.deviceId == b && c.radioDevice.ready);
      c.transmitting = true; // not the radio in use: allowed
      expect(await c.removeRadio(a), isNull);
      expect(c.savedRadios.map((r) => r.id), [b]);
      expect(c.radioDevice.ready, isTrue);
    });

    test('remove the one in use is blocked while talking', () async {
      final usb = UsbRadios({a: (0x11, 'Alpha', 'ALP')});
      final c = await load(base(), usb: usb);
      await c.pairRadio(found(a));
      await until(() => c.radioDevice.ready);
      c.transmitting = true;
      expect(await c.removeRadio(a), contains('talk'));
      expect(c.savedRadios, hasLength(1));
    });

    test(
      'rename is a local label; empty goes back to the radio name',
      () async {
        final usb = UsbRadios({a: (0x11, 'Alpha', 'ALP')});
        final c = await load(base(), usb: usb);
        await c.pairRadio(found(a));
        await until(() => c.radioDevice.ready);
        await c.renameRadio(a, '  Truck  ');
        expect(c.activeRadio?.title, 'Truck');
        expect(c.savedRadios.single.name, 'Alpha');
        // the radio's own name is not touched, and a new name read from the
        // radio does not undo the label
        await c.renameRadio(a, '');
        expect(c.activeRadio?.title, 'Alpha');
        await c.renameRadio(a, 'Truck');
        await c.renameRadio(a, 'Alpha');
        expect(c.savedRadios.single.label, isNull);
      },
    );
  });

  group('USB radio on another port', () {
    test('found again by its node number', () async {
      final usb = UsbRadios({'serial:COM9': (0x11, 'Alpha', 'ALP')});
      final c = await load(
        base(
          id: a,
          saved: [
            SavedRadio(id: a, name: 'Alpha', nodeId: 0x11),
            SavedRadio(id: 'serial:COM8', name: 'Other', nodeId: 0x99),
          ],
        ),
        usb: usb,
        ports: ['serial:COM9', 'serial:COM8'],
      );
      c.radioDevice.start();
      await until(() => c.radioDevice.ready);
      expect(c.radioDevice.deviceId, 'serial:COM9');
      expect(c.settings.radioId, 'serial:COM9');
      expect(c.savedRadios.map((r) => r.id), ['serial:COM9', 'serial:COM8']);
      expect(c.savedRadios.first.name, 'Alpha');
      // the other saved radio's port is never opened
      expect(usb.opened.where((p) => p == 'serial:COM8'), isEmpty);
    });

    test('a different radio on the free port is not taken for it', () async {
      final usb = UsbRadios({'serial:COM9': (0x77, 'Stranger', 'STR')});
      final c = await load(
        base(
          id: a,
          saved: [SavedRadio(id: a, nodeId: 0x11)],
        ),
        usb: usb,
      );
      c.radioDevice.start();
      await until(() => c.radioDevice.state == RadioState.reconnecting);
      expect(c.radioDevice.deviceId, a);
      expect(c.settings.radioId, a);
      expect(c.radioDevice.detail, contains('Not found: plug the radio in'));
      expect(c.radioDevice.detail, contains('COM3'));
      expect(c.radioDevice.ready, isFalse);
    });

    test(
      'a radio never connected is not searched for on other ports',
      () async {
        final usb = UsbRadios({'serial:COM9': (0x11, 'Alpha', 'ALP')});
        final c = await load(
          base(
            id: a,
            saved: [SavedRadio(id: a)],
          ),
          usb: usb,
        );
        c.radioDevice.start();
        await until(() => c.radioDevice.state == RadioState.reconnecting);
        expect(usb.opened, isEmpty);
        expect(c.radioDevice.detail, contains('Not found'));
      },
    );

    test('nothing plugged in: not found, with the hint', () async {
      final usb = UsbRadios({});
      final c = await load(
        base(
          id: a,
          saved: [SavedRadio(id: a, nodeId: 0x11)],
        ),
        usb: usb,
      );
      c.radioDevice.start();
      await until(() => c.radioDevice.state == RadioState.reconnecting);
      expect(c.radioDevice.detail, contains('plug the radio in'));
    });
  });

  group('Settings screen', () {
    Future<WalkieController> screen(
      WidgetTester t, {
      required List<SavedRadio> saved,
      String? active,
      List<String> ports = const [],
      RadioState state = RadioState.ready,
      bool desktop = true,
    }) async {
      phone(t, w: 400, h: 1800, ts: 1.0);
      PlatformCaps.debugDesktop = desktop;
      quietPlugins();
      SharedPreferences.setMockInitialValues({});
      final c = (await t.runAsync(
        () => WalkieController.load(
          store: MemorySettingsStore(base(id: active, saved: saved)),
        ),
      ))!;
      c.radioDevice
        ..usbRadios = (() => ports)
        ..state = state;
      addTearDown(c.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: RadioSettings(controller: c)),
          ),
        ),
      );
      return c;
    }

    final t0 = DateTime.now().subtract(const Duration(hours: 3));

    testWidgets('lists the saved radios; the one in use says Connected', (
      t,
    ) async {
      await screen(
        t,
        active: a,
        ports: [a],
        saved: [
          SavedRadio(id: a, name: 'Alpha', lastConnected: DateTime.now()),
          SavedRadio(id: b, name: 'Beta', lastConnected: t0),
          SavedRadio(id: 'AA:BB', name: 'Phone radio'),
        ],
      );
      expect(find.text('Saved radios'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(
        find.textContaining('Connected · USB cable on COM3'),
        findsOneWidget,
      );
      expect(
        find.text('USB cable on COM5 · Not found: plug it in'),
        findsOneWidget,
      );
      expect(find.text('Bluetooth · Not connected yet'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      expect(
        t.widget<ListTile>(find.byKey(const Key('savedRadio-$a'))).selected,
        isTrue,
      );
      expect(
        t.widget<ListTile>(find.byKey(const Key('savedRadio-$b'))).selected,
        isFalse,
      );
    });

    testWidgets('a plugged in saved radio shows when it was last seen', (
      t,
    ) async {
      await screen(
        t,
        active: a,
        ports: [a, b],
        saved: [
          SavedRadio(id: a, name: 'Alpha'),
          SavedRadio(id: b, name: 'Beta', lastConnected: t0),
        ],
      );
      expect(find.text('USB cable on COM5 · Seen 3 h ago'), findsOneWidget);
    });

    testWidgets('no old Forget / Disconnect button, add buttons stay', (
      t,
    ) async {
      await screen(
        t,
        active: a,
        ports: [a],
        saved: [SavedRadio(id: a, name: 'Alpha')],
      );
      expect(find.text('Forget radio'), findsNothing);
      expect(find.text('Disconnect radio'), findsNothing);
      expect(find.byKey(const Key('radioScan')), findsOneWidget);
      expect(find.byKey(const Key('radioWifi')), findsOneWidget);
      expect(find.text('Add a radio'), findsOneWidget);
    });

    testWidgets('no saved radios: only the add buttons', (t) async {
      await screen(t, saved: []);
      expect(find.text('Saved radios'), findsNothing);
      expect(find.text('Add a radio'), findsNothing);
      expect(find.byKey(const Key('radioScan')), findsOneWidget);
      expect(find.text('Find USB radio'), findsOneWidget);
    });

    testWidgets('a phone: Bluetooth rows, Find my radio, PIN help', (t) async {
      await screen(
        t,
        desktop: false,
        active: 'AA:BB',
        saved: [
          SavedRadio(id: 'AA:BB', name: 'Alpha', lastConnected: DateTime.now()),
          SavedRadio(id: 'CC:DD', name: 'Beta'),
        ],
      );
      expect(find.text('Find my radio'), findsOneWidget);
      expect(find.byKey(const Key('radioWifi')), findsNothing);
      expect(find.text('Bluetooth · Connected'), findsNothing);
      expect(find.text('Connected · Bluetooth'), findsOneWidget);
      expect(find.text('Bluetooth · Not connected yet'), findsOneWidget);
      expect(find.textContaining('Not found'), findsNothing);
      expect(find.textContaining('123456'), findsNothing);
    });

    testWidgets('the menu: disconnect, rename, remove', (t) async {
      final c = await screen(
        t,
        active: a,
        ports: [a, b],
        saved: [
          SavedRadio(id: a, name: 'Alpha'),
          SavedRadio(id: b, name: 'Beta'),
        ],
      );
      // the one in use has Disconnect; the other does not
      await t.tap(find.byKey(const Key('savedRadioMenu-$b')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('savedRadioDisconnect')), findsNothing);
      expect(find.byKey(const Key('savedRadioRename')), findsOneWidget);
      expect(find.byKey(const Key('savedRadioRemove')), findsOneWidget);
      await t.tap(find.byKey(const Key('savedRadioRename')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('savedRadioName')), 'Spare');
      await t.tap(find.byKey(const Key('savedRadioNameSave')));
      await t.pumpAndSettle();
      expect(find.text('Spare'), findsOneWidget);
      expect(find.text('Beta'), findsNothing);
      expect(c.savedRadios.last.label, 'Spare');

      await t.tap(find.byKey(const Key('savedRadioMenu-$b')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('savedRadioRemove')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('removeRadioDialog')), findsOneWidget);
      expect(find.textContaining('Remove Spare?'), findsOneWidget);
      await t.tap(find.byKey(const Key('removeRadioConfirm')));
      await t.pumpAndSettle();
      expect(c.savedRadios.map((r) => r.id), [a]);
      expect(find.text('Spare'), findsNothing);

      await t.tap(find.byKey(const Key('savedRadioMenu-$a')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('savedRadioDisconnect')), findsOneWidget);
      await t.tap(find.byKey(const Key('savedRadioDisconnect')));
      await t.pumpAndSettle();
      expect(c.radioPaired, isFalse);
      expect(find.text('Alpha'), findsOneWidget);
    });

    testWidgets('cancel in the remove dialog keeps the radio', (t) async {
      final c = await screen(
        t,
        saved: [SavedRadio(id: a, name: 'Alpha')],
        ports: [a],
      );
      await t.tap(find.byKey(const Key('savedRadioMenu-$a')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('savedRadioRemove')));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(c.savedRadios, hasLength(1));
    });

    testWidgets('tapping another radio while talking changes nothing', (
      t,
    ) async {
      final c = await screen(
        t,
        active: a,
        ports: [a, b],
        saved: [
          SavedRadio(id: a, name: 'Alpha'),
          SavedRadio(id: b, name: 'Beta'),
        ],
      );
      c.transmitting = true;
      await t.tap(find.byKey(const Key('savedRadio-$b')));
      await t.pump();
      expect(c.radioDevice.deviceId, a);
      expect(c.settings.radioId, a);
      expect(await c.switchRadio(b), contains('talk'));
      c.transmitting = false;
    });

    testWidgets('the one in use is not tappable', (t) async {
      await screen(
        t,
        active: a,
        ports: [a],
        saved: [SavedRadio(id: a, name: 'Alpha')],
      );
      expect(
        t.widget<ListTile>(find.byKey(const Key('savedRadio-$a'))).onTap,
        isNull,
      );
    });

    testWidgets('a radio that is not connected shows why', (t) async {
      final c = await screen(
        t,
        active: a,
        ports: [a],
        saved: [SavedRadio(id: a, name: 'Alpha')],
        state: RadioState.reconnecting,
      );
      c.radioDevice.detail = 'Not found: plug the radio in (it was on COM3).';
      c.notifyListeners();
      await t.pump();
      expect(
        find.textContaining('Not connected, retrying · Not found'),
        findsOneWidget,
      );
    });

    testWidgets('scan results hide radios that are already saved', (t) async {
      await screen(
        t,
        active: a,
        ports: [a, b],
        saved: [SavedRadio(id: a, name: 'Alpha')],
      );
      await t.tap(find.byKey(const Key('radioScan')));
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('radioAdd-$b')), findsOneWidget);
      expect(find.byKey(const Key('radioAdd-$a')), findsNothing);
    });

    testWidgets('only saved radios found: says nothing is new', (t) async {
      await screen(
        t,
        active: a,
        ports: [a],
        saved: [SavedRadio(id: a, name: 'Alpha')],
      );
      await t.tap(find.byKey(const Key('radioScan')));
      await t.pump();
      await t.pump();
      expect(find.textContaining('already in your list'), findsOneWidget);
    });
  });
}
