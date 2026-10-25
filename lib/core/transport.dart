import 'dart:async';
import 'dart:typed_data';

import 'frame.dart';

/// The physical/logical paths a peer can be reached on.
///
/// The default preference order (highest first) is LAN > BLE > internet:
/// LAN has the most bandwidth and lowest latency and needs no internet; BLE
/// works with no network at all but is short range and low bandwidth; the
/// internet relay has unlimited range but needs connectivity and adds
/// latency.
enum TransportKind {
  lan('Wi-Fi / LAN', 30),
  ble('Bluetooth LE', 20),
  internet('Internet', 10);

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

  Future<void> dispose() => stop();
}
