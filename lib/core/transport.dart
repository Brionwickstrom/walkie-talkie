import 'dart:async';
import 'dart:typed_data';

import 'frame.dart';

/// The physical/logical paths a peer can be reached on.
///
/// The default preference order (highest first) is LAN > Wi-Fi Direct >
/// BLE > internet:
/// LAN has the most bandwidth and lowest latency and needs no internet; BLE
/// works with no network at all but is short range and low bandwidth; the
/// internet relay has unlimited range but needs connectivity and adds
/// latency.
enum TransportKind {
  lan('Wi-Fi / LAN', 30),

  /// Android Wi-Fi P2P group formed with nearby app phones when there is no
  /// shared network (v1.6.0).
  wifiDirect('Wi-Fi Direct', 25),
  ble('Bluetooth LE', 20),
  internet('Internet', 10),

  /// Meshtastic LoRa radio paired over Bluetooth (v1.7.0): miles of range
  /// but a few small packets per minute. Only used for phones no other
  /// link (or the phone mesh) reaches, and never for live audio.
  lora('LoRa radio', 5);

  const TransportKind(this.label, this.defaultPriority);
  final String label;
  final int defaultPriority;
}

/// A frame delivered by a transport, plus an opaque link address the
/// transport can use later to unicast back to the sender.
class InboundFrame {
  InboundFrame(this.frame, this.transport, {this.rssi});

  final Frame frame;
  final TransportKind transport;

  /// Optional signal strength hint (BLE). Not used for routing yet.
  final int? rssi;
}

enum TransportStatus { stopped, starting, running, unavailable, error }

/// Common interface for every link type.
///
/// Discovery is implicit: a transport finds candidates in its own way
/// (UDP beacons/mDNS, BLE scanning, relay channel membership) and simply
/// surfaces every valid [Frame] it receives. The [TransportManager] learns
/// peers from the sender ids inside frames, and the transport remembers how
/// to reach each sender id so [send] can unicast.
abstract class Transport {
  TransportKind get kind;

  /// Larger is better. Defaults to [TransportKind.defaultPriority].
  int get priority => kind.defaultPriority;

  TransportStatus get status;

  /// Very slow link (LoRa): no per-second hellos, pings, mesh beacons or
  /// live audio; the manager decides what may go out on it.
  bool get lowBandwidth => false;

  /// How long a peer heard on this link stays reachable, if different
  /// from the manager's normal link timeout.
  Duration? get linkTimeout => null;

  /// Human readable reason when [status] is unavailable/error.
  String? get statusDetail => null;

  Stream<TransportStatus> get statusChanges;

  Stream<InboundFrame> get frames;

  /// Start discovery/advertising and accept traffic.
  Future<void> start({required int localNodeId, required int channel});

  Future<void> stop();

  /// Channel changes are cheap: transports that scope discovery by channel
  /// (relay) re-join, the rest just keep going.
  Future<void> setChannel(int channel) async {}

  /// Send [frame] to the given peers, or to everyone reachable on this
  /// transport when [peerIds] is null (used for hello beacons).
  ///
  /// Implementations may over-deliver (e.g. a BLE notify reaches every
  /// subscribed central, the relay fans out to the whole channel); the
  /// receiver de-duplicates.
  Future<void> send(Uint8List frame, {Set<int>? peerIds});

  /// Whether this transport currently has a way to address [peerId]
  /// (e.g. a live BLE connection or a known UDP endpoint). Lets the manager
  /// stop routing over a link the moment the radio reports it gone, instead
  /// of waiting for the liveness timeout.
  bool canReach(int peerId) => true;

  /// Addresses other phones can use to reach us directly on this transport
  /// (LAN: "ip:port"). Advertised in hello beacons over every link.
  List<String> get localAddresses => const [];

  /// A peer told us (over any link) where it can be reached on this
  /// transport. LAN uses this to try direct unicast when broadcast/mDNS
  /// are blocked.
  void learnPeerAddresses(int peerId, List<String> addresses) {}

  /// Battery saver: scan / sweep / keep-alive less often. Traffic still
  /// flows; discovery of new phones and failure detection get slower.
  void setPowerSaver(bool on) {}

  /// Offline power save (see [PowerPlan]): the strongest saver. Transports
  /// that need the internet are stopped by the manager; the others cut
  /// discovery to the minimum (sweeps off, short scan bursts, on-demand
  /// Wi-Fi Direct). Implies [setPowerSaver].
  void setOfflineSaver(bool on) {}

  /// One-line diagnostic for the debug UI.
  String? get debugInfo => null;

  Future<void> dispose() => stop();
}
