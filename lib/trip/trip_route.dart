import 'trip_packet.dart';

/// Where a Trip message goes (see TransportManager.sendTrip).
class TripRoute {
  const TripRoute({
    this.to,
    this.fast = true,
    this.radio = false,
    this.flood = false,
  });

  /// One phone, or null for the channel.
  final int? to;

  /// Fast links (LAN, Wi-Fi Direct, Bluetooth, internet, phone mesh).
  final bool fast;

  /// Also the LoRa radio, for phones nothing faster reaches.
  final bool radio;

  /// Everyone in range, not only known phones on the channel.
  final bool flood;

  @override
  String toString() => 'TripRoute(to=$to fast=$fast radio=$radio flood=$flood)';
}

typedef TripSend = void Function(TripMsg msg, TripRoute route);
typedef Clock = DateTime Function();
