import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../core/transport.dart';
import '../core/transport_manager.dart';
import 'inbox.dart';
import 'outbox.dart';
import 'storage.dart';
import 'voice_clip.dart';
import 'voice_transfer.dart';

/// What the [Messenger] needs from the transport layer (the
/// [TransportManager] in the app, a fake in tests).
abstract class MessengerLink {
  int get localNodeId;
  bool isReachable(int peerId);
  TransportKind? bestLinkTo(int peerId);
  Set<int> reachablePeersOn(int channel);

  /// Where we are now ([TransportManager.scope]): a channel number, or a
  /// private-channel scope (>= 0x10000).
  int get scope;

  /// Extra bytes per frame on the current channel (encryption).
  int get frameOverhead;
  Future<bool> sendData(int peerId, Uint8List payload);
  Stream<InboundData> get data;
  String nameOf(int peerId);
}

class ManagerMessengerLink implements MessengerLink {
  ManagerMessengerLink(this.m);
  final TransportManager m;

  @override
  int get localNodeId => m.localNodeId;
  @override
  bool isReachable(int peerId) => m.isReachable(peerId);
  @override
  TransportKind? bestLinkTo(int peerId) => m.bestLinkTo(peerId);
  @override
  Set<int> reachablePeersOn(int channel) => m.reachablePeersOn(channel);
  @override
  int get scope => m.scope;
  @override
  int get frameOverhead => m.frameOverhead;
  @override
  Future<bool> sendData(int peerId, Uint8List payload) =>
      m.sendData(peerId, payload);
  @override
  Stream<InboundData> get data => m.data;
  @override
  String nameOf(int peerId) => m.peer(peerId)?.displayName ?? '';
}

/// Delivery state of one outgoing message to one phone (for the UI).
class OutgoingStatus {
  OutgoingStatus(this.entry, this.peer, this.progress, this.sending);
  final OutboxEntry entry;
  final int peer;
  final double progress;
  final bool sending;
}

/// Voice messages: reliable chunked delivery with acks, store-and-forward
/// for phones that are out of reach (retried whenever they are seen again,
/// for up to 24 h), and the received-messages inbox.
class Messenger {
  Messenger({
    required this.link,
    required MessageStorage storage,
    Clock? clock,
    Random? random,
    this.chunkSize = fastChunkSize,
    this.tickInterval = const Duration(milliseconds: 50),
    this.stallTimeout = const Duration(seconds: 8),
    this.retryDelay = const Duration(seconds: 3),
    this.ackDelay = const Duration(milliseconds: 120),
    Duration ttl = const Duration(hours: 24),
  }) : outbox = Outbox(storage, ttl: ttl),
       inbox = Inbox(storage),
       _clock = clock ?? DateTime.now,
       _random = random ?? Random();

  final MessengerLink link;
  final Outbox outbox;
  final Inbox inbox;
  final Clock _clock;
  final Random _random;

  /// Chunk size on Wi-Fi / internet; Bluetooth always uses [bleChunkSize].
  final int chunkSize;
  final Duration tickInterval;
  final Duration stallTimeout;
  final Duration retryDelay;
  final Duration ackDelay;

  final Map<(int, int), TransferSender> _sessions = {};
  final Map<(int, int), DateTime> _retryAt = {};
  final Map<(int, int), TransferReceiver> _rx = {};
  final Map<(int, int), DateTime> _ackDue = {};
  final Map<int, Uint8List> _bodies = {};
  StreamSubscription<InboundData>? _sub;
  Timer? _timer;
  bool _ticking = false;

  final _received = StreamController<InboxEntry>.broadcast();
  final _delivered = StreamController<(OutboxEntry, int)>.broadcast();
  final _changes = StreamController<void>.broadcast();

  /// A complete new voice message arrived.
  Stream<InboxEntry> get received => _received.stream;

  /// A message reached a phone (entry, peer).
  Stream<(OutboxEntry, int)> get delivered => _delivered.stream;

  /// Something in the inbox/outbox changed.
  Stream<void> get changes => _changes.stream;

  Future<void> start() async {
    await outbox.load();
    await inbox.load();
    _sub ??= link.data.listen(onData);
    _timer ??= Timer.periodic(tickInterval, (_) => tick());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> dispose() async {
    await stop();
    await _received.close();
    await _delivered.close();
    await _changes.close();
  }

  /// Queue [clip] for [toPeer] (or everyone on [channel] when null) and
  /// start sending right away if they are reachable.
  Future<OutboxEntry> send(
    VoiceClip clip, {
    int? toPeer,
    required int channel,
  }) async {
    final entry = OutboxEntry(
      msgId: _random.nextInt(0x7FFFFFFF) + 1,
      toPeer: toPeer,
      channel: channel,
      createdAt: _clock(),
      durationMs: clip.durationMs,
      recipients: toPeer == null ? link.reachablePeersOn(channel) : {toPeer},
    );
    final body = clip.encode();
    _bodies[entry.msgId] = body;
    await outbox.add(entry, body);
    _changed();
    await tick();
    return entry;
  }

  Future<void> cancel(int msgId) async {
    _sessions.removeWhere((k, _) => k.$1 == msgId);
    _bodies.remove(msgId);
    await outbox.cancel(msgId);
    _changed();
  }

  /// Per-recipient status of everything still in the outbox.
  List<OutgoingStatus> get outgoing => [
    for (final e in outbox.entries)
      for (final p in e.pending)
        OutgoingStatus(
          e,
          p,
          _sessions[(e.msgId, p)]?.progress ?? 0,
          _sessions.containsKey((e.msgId, p)),
        ),
  ];

  /// Channel messages nobody has received yet (no recipients known).
  List<OutboxEntry> get waitingForAnyone => [
    for (final e in outbox.entries)
      if (e.recipients.isEmpty) e,
  ];

  /// Drive sending, retries, acks and expiry. Runs every [tickInterval];
  /// public for tests.
  Future<void> tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      await _tick();
    } finally {
      _ticking = false;
    }
  }

  Future<void> _tick() async {
    final now = _clock();
    var changed = false;

    final expired = await outbox.expire(now);
    if (expired.isNotEmpty) {
      for (final e in expired) {
        _bodies.remove(e.msgId);
        _sessions.removeWhere((k, _) => k.$1 == e.msgId);
      }
      changed = true;
    }
    if (outbox.addRecipients(link.reachablePeersOn)) {
      await outbox.save();
      changed = true;
    }

    // Start sessions for reachable recipients.
    for (final e in List.of(outbox.entries)) {
      for (final p in e.pending.toList()) {
        final key = (e.msgId, p);
        if (_sessions.containsKey(key)) continue;
        // A message recorded on a private channel only goes out while we
        // are on that same private channel (encrypted with its key), and
        // vice versa, so nothing private ever leaks onto a public channel.
        if (!scopeMatches(e.channel, link.scope)) continue;
        if (!link.isReachable(p)) continue;
        final retry = _retryAt[key];
        if (retry != null && now.isBefore(retry)) continue;
        var body = _bodies[e.msgId];
        if (body == null) {
          body = await _loadBody(e);
          if (body == null) continue;
          _bodies[e.msgId] = body;
        }
        _sessions[key] = TransferSender(
          msgId: e.msgId,
          to: p,
          body: body,
          durationMs: e.durationMs,
          channelMessage: e.isChannel,
          now: now,
          chunkSize: link.bestLinkTo(p) == TransportKind.ble
              ? bleChunkSize - link.frameOverhead
              : chunkSize,
        );
        changed = true;
      }
    }

    // Pump sessions.
    for (final entry in _sessions.entries.toList()) {
      final s = entry.value;
      if (!link.isReachable(s.to) ||
          now.difference(s.lastProgress) > stallTimeout) {
        // Out of reach / stuck: park it, the message stays queued.
        _sessions.remove(entry.key);
        _retryAt[entry.key] = now.add(retryDelay);
        changed = true;
        continue;
      }
      final pacing = link.bestLinkTo(s.to) == TransportKind.ble
          ? TransferPacing.ble
          : TransferPacing.fast;
      for (final pkt in s.due(now, pacing)) {
        await link.sendData(s.to, pkt);
      }
    }

    // Delayed acks on the receiving side, and forget stale partials.
    for (final key in _ackDue.keys.toList()) {
      if (now.difference(_ackDue[key]!) < ackDelay) continue;
      _ackDue.remove(key);
      final r = _rx[key];
      if (r != null) await link.sendData(r.sender, r.ack().encode());
    }
    _rx.removeWhere(
      (_, r) => now.difference(r.lastActivity) > const Duration(minutes: 2),
    );

    if (changed) _changed();
  }

  Future<Uint8List?> _loadBody(OutboxEntry e) =>
      outbox.storage.getBlob(e.blobName);

  /// Handle a data payload from a peer.
  Future<void> onData(InboundData d) async {
    final pkt = DataPacket.tryDecode(d.payload);
    if (pkt == null || pkt.to != link.localNodeId) return;
    final now = _clock();
    if (pkt is AckPacket) {
      final key = (pkt.msgId, d.peerId);
      final s = _sessions[key];
      if (s != null) {
        if (s.onAck(pkt, now)) _changed();
        if (s.complete) {
          _sessions.remove(key);
          await _deliveredTo(pkt.msgId, d.peerId);
        }
      } else if (pkt.complete) {
        // Completed after the session was parked.
        await _deliveredTo(pkt.msgId, d.peerId);
      }
      return;
    }
    if (pkt is ChunkPacket) {
      final key = (d.peerId, pkt.msgId);
      if (inbox.contains(d.peerId, pkt.msgId)) {
        // Already have it; our final ack was probably lost.
        await link.sendData(
          d.peerId,
          AckPacket(
            msgId: pkt.msgId,
            to: d.peerId,
            total: pkt.total,
            nextMissing: pkt.total,
            bitmap: 0,
          ).encode(),
        );
        return;
      }
      final r = _rx.putIfAbsent(
        key,
        () => TransferReceiver(
          sender: d.peerId,
          msgId: pkt.msgId,
          total: pkt.total,
          durationMs: pkt.durationMs,
          channelMessage: pkt.channelMessage,
          now: now,
        ),
      );
      final isNew = r.add(pkt, now);
      if (r.complete) {
        _rx.remove(key);
        _ackDue.remove(key);
        final body = r.assemble();
        await link.sendData(d.peerId, r.ack().encode());
        if (VoiceClip.tryDecode(body) == null) return;
        final name = link.nameOf(d.peerId);
        final e = InboxEntry(
          sender: d.peerId,
          msgId: pkt.msgId,
          senderName: name,
          channel: d.channel,
          channelMessage: pkt.channelMessage,
          receivedAt: now,
          durationMs: pkt.durationMs,
        );
        await inbox.add(e, body);
        if (!_received.isClosed) _received.add(e);
        _changed();
      } else if (!isNew || r.unacked >= 8) {
        // Duplicate means the sender missed our ack: answer right away.
        _ackDue.remove(key);
        await link.sendData(d.peerId, r.ack().encode());
      } else {
        _ackDue.putIfAbsent(key, () => now);
      }
    }
  }

  Future<void> _deliveredTo(int msgId, int peer) async {
    final e = outbox.byId(msgId);
    if (e == null) return;
    if (await outbox.markDelivered(msgId, peer)) {
      if (outbox.byId(msgId) == null) _bodies.remove(msgId);
      if (!_delivered.isClosed) _delivered.add((e, peer));
      _changed();
    }
  }

  Future<Uint8List?> bodyOf(InboxEntry e) => inbox.body(e);

  Future<void> deleteReceived(InboxEntry e) async {
    await inbox.delete(e);
    _changed();
  }

  Future<void> markPlayed(InboxEntry e) async {
    await inbox.markPlayed(e);
    _changed();
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }
}

/// Whether an outbox entry made on [entryScope] may be sent while we are on
/// [current]: any public channel to any public channel (as before), but a
/// private channel only to exactly the same private channel.
bool scopeMatches(int entryScope, int current) {
  const private = 0x10000;
  if (entryScope < private && current < private) return true;
  return entryScope == current;
}
