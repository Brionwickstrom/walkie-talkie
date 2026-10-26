import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../chat/chat_body.dart';
import '../core/transport.dart';
import '../core/transport_manager.dart';
import '../lora/radio_clip.dart';
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

  /// The phone understands chat messages (v1.5+).
  bool supportsChat(int peerId);
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
  @override
  bool supportsChat(int peerId) => m.peer(peerId)?.supportsChat ?? false;
}

/// A chat message (text / photo / location) that arrived.
class ChatArrival {
  ChatArrival({
    required this.sender,
    required this.msgId,
    required this.senderName,
    required this.channel,
    required this.channelMessage,
    required this.receivedAt,
    required this.body,
    this.viaRadio = false,
  });

  /// Came over a LoRa radio.
  final bool viaRadio;
  final int sender;
  final int msgId;
  final String senderName;
  final int channel;
  final bool channelMessage;
  final DateTime receivedAt;
  final ChatBody body;
}

/// Delivery state of one outgoing message to one phone (for the UI).
class OutgoingStatus {
  OutgoingStatus(
    this.entry,
    this.peer,
    this.progress,
    this.sending, {
    this.viaRadio = false,
    this.chunksDone = 0,
    this.chunksTotal = 0,
  });
  final OutboxEntry entry;
  final int peer;
  final double progress;
  final bool sending;

  /// Going out over the LoRa radio (slow: one packet every few seconds).
  final bool viaRadio;
  final int chunksDone;
  final int chunksTotal;
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
    this.maxAttempts = 30,
    this.radioStallTimeout = const Duration(minutes: 4),
    this.radioAckDelay = const Duration(seconds: 3),
    this.radioLiveInterval = const Duration(minutes: 5),
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

  /// LoRa radio transfers (v1.7.0): give up a session after this long
  /// without progress, ack after this pause (one ack for several chunks),
  /// and send live-location updates at most this often.
  final Duration radioStallTimeout;
  final Duration radioAckDelay;
  final Duration radioLiveInterval;

  /// Largest chat body sent over the radio (text, a location): ~5 packets.
  static const radioMaxChatBody = 700;

  /// Turns a received radio clip (Codec 2) into a playable [VoiceClip]
  /// body (Opus). Null result or no hook: the clip is dropped.
  Future<Uint8List?> Function(Uint8List radioClip)? radioClipToVoice;

  final Set<(int, int)> _radioSessions = {};
  final Set<(int, int)> _radioRx = {};
  final Map<(int, int), Uint8List> _radioBodies = {};
  final Map<(int, int), DateTime> _radioLiveAt = {};
  final Duration retryDelay;
  final Duration ackDelay;

  /// Sending sessions per message and phone before giving up (each one
  /// only re-sends the chunks not acknowledged yet).
  final int maxAttempts;
  final Map<(int, int), int> _attempts = {};

  /// Every message ever received (sender, id), kept across restarts, so a
  /// message re-sent after a lost ack (or after it was deleted here) is
  /// acknowledged again but never shown / announced twice.
  final Set<String> _seen = {};
  final List<String> _seenOrder = [];
  static const seenName = 'seen.json';
  static const seenMax = 3000;

  /// Received messages recorded longer ago than this are dropped (they can
  /// only be stale re-sends; the outbox keeps messages for 24 h).
  static const maxMessageAge = Duration(hours: 25);

  bool hasSeen(int sender, int msgId) => _seen.contains('${sender}_$msgId');

  Future<void> _markSeen(int sender, int msgId) async {
    final k = '${sender}_$msgId';
    if (!_seen.add(k)) return;
    _seenOrder.add(k);
    while (_seenOrder.length > seenMax) {
      _seen.remove(_seenOrder.removeAt(0));
    }
    await outbox.storage.writeJson(seenName, _seenOrder);
  }

  final Map<(int, int), TransferSender> _sessions = {};
  final Map<(int, int), DateTime> _retryAt = {};
  final Map<(int, int), TransferReceiver> _rx = {};
  final Map<(int, int), DateTime> _ackDue = {};
  final Map<(int, bool), Uint8List> _bodies = {};

  /// Chat messages already received (sender, msgId), to re-ack duplicates.
  /// [alreadyHaveChat] covers the ones from before a restart.
  final Set<(int, int)> _chatSeen = {};
  bool Function(int sender, int msgId)? alreadyHaveChat;
  StreamSubscription<InboundData>? _sub;
  Timer? _timer;
  bool _ticking = false;

  final _received = StreamController<InboxEntry>.broadcast();
  final _chats = StreamController<ChatArrival>.broadcast();
  final _delivered = StreamController<(OutboxEntry, int)>.broadcast();
  final _changes = StreamController<void>.broadcast();
  final _read = StreamController<(int, int)>.broadcast();

  // ------------------------------------------------------ read receipts

  /// Wait this long to batch receipts (fast links / LoRa radio).
  static const readBatchDelay = Duration(seconds: 2);
  static const radioReadBatchDelay = Duration(seconds: 20);

  /// Receipts waiting to go out: sender -> (first queued, msg ids).
  final Map<int, (DateTime, List<int>)> _readDue = {};
  final Set<(int, int)> _readSent = {};

  /// Read receipts sent (tests / Details).
  int readPacketsSent = 0;

  /// One of our messages was seen by a phone: (msgId, peer).
  Stream<(int, int)> get read => _read.stream;

  /// Tell [sender] their message [msgId] was seen (opened chat / played
  /// voice message). Batched; goes over whatever reaches them, the radio
  /// included (tiny). Each message at most once.
  void markRead(int sender, int msgId) {
    if (sender == link.localNodeId) return;
    if (!_readSent.add((sender, msgId))) return;
    if (_readSent.length > 2000) _readSent.remove(_readSent.first);
    final cur = _readDue[sender];
    if (cur == null) {
      _readDue[sender] = (_clock(), [msgId]);
    } else {
      cur.$2.add(msgId);
    }
  }

  Future<void> _flushReads(DateTime now) async {
    for (final e in _readDue.entries.toList()) {
      final peer = e.key;
      if (!link.isReachable(peer)) continue;
      final wait = link.bestLinkTo(peer) == TransportKind.lora
          ? radioReadBatchDelay
          : readBatchDelay;
      final (since, ids) = e.value;
      if (now.difference(since) < wait && ids.length < ReadPacket.maxIds) {
        continue;
      }
      _readDue.remove(peer);
      for (var i = 0; i < ids.length; i += ReadPacket.maxIds) {
        final batch = ids.sublist(i, min(i + ReadPacket.maxIds, ids.length));
        final ok = await link.sendData(
          peer,
          ReadPacket(to: peer, ids: batch).encode(),
        );
        if (ok) {
          readPacketsSent++;
        } else {
          // Try again later with the rest.
          final rest = ids.sublist(i);
          _readDue[peer] = (now, rest);
          break;
        }
      }
    }
    // Receipts nobody could take for a day are dropped.
    _readDue.removeWhere(
      (_, v) => now.difference(v.$1) > const Duration(hours: 24),
    );
  }

  /// A complete new voice message arrived.
  Stream<InboxEntry> get received => _received.stream;

  /// A chat message arrived (not stored by the messenger).
  Stream<ChatArrival> get chats => _chats.stream;

  /// A message reached a phone (entry, peer).
  Stream<(OutboxEntry, int)> get delivered => _delivered.stream;

  /// Something in the inbox/outbox changed.
  Stream<void> get changes => _changes.stream;

  Future<void> start() async {
    await outbox.load();
    await inbox.load();
    final seen = await outbox.storage.readJson(seenName);
    if (seen is List) {
      for (final k in seen) {
        if (k is String && _seen.add(k)) _seenOrder.add(k);
      }
    }
    for (final e in inbox.entries) {
      final k = '${e.sender}_${e.msgId}';
      if (_seen.add(k)) _seenOrder.add(k);
    }
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
    await _chats.close();
    await _delivered.close();
    await _changes.close();
    await _read.close();
  }

  /// Queue [clip] for [toPeer] (or everyone on [channel] when null) and
  /// start sending right away if they are reachable.
  Future<OutboxEntry> send(
    VoiceClip clip, {
    int? toPeer,
    required int channel,
    RadioClip? radioClip,
  }) async {
    final entry = OutboxEntry(
      hasRadioBody: radioClip != null,
      msgId: _random.nextInt(0x7FFFFFFF) + 1,
      toPeer: toPeer,
      channel: channel,
      createdAt: _clock(),
      durationMs: clip.durationMs,
      recipients: toPeer == null ? link.reachablePeersOn(channel) : {toPeer},
    );
    // The send time rides along (ignored by older apps) so receivers can
    // tell a fresh message from a stale one.
    final body = clip.encode(sentAt: entry.createdAt);
    _bodies[(entry.msgId, false)] = body;
    Uint8List? radio;
    if (radioClip != null) {
      radio = RadioClip(
        mode: radioClip.mode,
        bitsPerFrame: radioClip.bitsPerFrame,
        frameMs: radioClip.frameMs,
        frames: radioClip.frames,
        bits: radioClip.bits,
        sentAt: entry.createdAt,
      ).encode();
    }
    await outbox.add(entry, body, radioBody: radio);
    _changed();
    await tick();
    return entry;
  }

  /// Queue a chat message (same store-and-forward as voice messages). Only
  /// phones that understand chat get it. [bleBody] is sent instead of the
  /// full one over Bluetooth (a photo thumbnail).
  Future<OutboxEntry> sendChat(
    ChatBody chat, {
    int? toPeer,
    required int channel,
    ChatBody? bleBody,
  }) async {
    final entry = OutboxEntry(
      msgId: _random.nextInt(0x7FFFFFFF) + 1,
      toPeer: toPeer,
      channel: channel,
      createdAt: _clock(),
      durationMs: 0,
      kind: OutboxKind.chat,
      hasBleBody: bleBody != null,
      recipients: toPeer == null
          ? link.reachablePeersOn(channel).where(link.supportsChat).toSet()
          : {toPeer},
    );
    final body = chat.encode();
    final ble = bleBody?.encode();
    _bodies[(entry.msgId, false)] = body;
    if (ble != null) _bodies[(entry.msgId, true)] = ble;
    await outbox.add(entry, body, bleBody: ble);
    _changed();
    await tick();
    return entry;
  }

  Future<void> cancel(int msgId) async {
    _sessions.removeWhere((k, _) => k.$1 == msgId);
    _radioSessions.removeWhere((k) => k.$1 == msgId);
    _bodies.removeWhere((k, _) => k.$1 == msgId);
    _radioBodies.removeWhere((k, _) => k.$1 == msgId);
    await outbox.cancel(msgId);
    _changed();
  }

  /// Per-recipient status of everything still in the outbox.
  List<OutgoingStatus> get outgoing => [
    for (final e in outbox.entries)
      if (!e.isChat)
        for (final p in e.pending)
          OutgoingStatus(
            e,
            p,
            _sessions[(e.msgId, p)]?.progress ?? 0,
            _sessions.containsKey((e.msgId, p)),
            viaRadio:
                _radioSessions.contains((e.msgId, p)) ||
                (!_sessions.containsKey((e.msgId, p)) &&
                    link.bestLinkTo(p) == TransportKind.lora),
            chunksDone: _sessions[(e.msgId, p)]?.acked.length ?? 0,
            chunksTotal: _sessions[(e.msgId, p)]?.total ?? 0,
          ),
  ];

  /// Channel messages nobody has received yet (no recipients known).
  List<OutboxEntry> get waitingForAnyone => [
    for (final e in outbox.entries)
      if (e.recipients.isEmpty && !e.isChat) e,
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
        _bodies.removeWhere((k, _) => k.$1 == e.msgId);
        _sessions.removeWhere((k, _) => k.$1 == e.msgId);
      }
      changed = true;
    }
    if (outbox.addRecipients(
      link.reachablePeersOn,
      accept: (e, p) => !e.isChat || link.supportsChat(p),
    )) {
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
        final n = (_attempts[key] ?? 0) + 1;
        if (n > maxAttempts) {
          _attempts.remove(key);
          _retryAt.remove(key);
          await outbox.giveUp(e.msgId, p);
          changed = true;
          continue;
        }
        final best = link.bestLinkTo(p);
        final radio = best == TransportKind.lora;
        Uint8List? body;
        if (radio) {
          // Only what fits the radio: a Codec 2 clip, a short text or a
          // location. Anything else waits for a faster link.
          body = await _radioBody(e, p, now);
          if (body == null) continue;
        }
        _attempts[key] = n;
        final ble = e.hasBleBody && best == TransportKind.ble;
        if (body == null) {
          body = _bodies[(e.msgId, ble)];
          if (body == null) {
            body = await outbox.storage.getBlob(
              ble ? e.bleBlobName : e.blobName,
            );
            if (body == null) continue;
            _bodies[(e.msgId, ble)] = body;
          }
        }
        if (radio) {
          _radioSessions.add(key);
        } else {
          _radioSessions.remove(key);
        }
        _sessions[key] = TransferSender(
          msgId: radio ? (e.msgId | radioTransferBit) : e.msgId,
          to: p,
          body: body,
          durationMs: e.durationMs,
          channelMessage: e.isChannel,
          now: now,
          chunkSize: radio
              ? loraChunkSize - link.frameOverhead
              : best == TransportKind.ble
              ? bleChunkSize - link.frameOverhead
              : chunkSize,
        );
        changed = true;
      }
    }

    // Pump sessions.
    for (final entry in _sessions.entries.toList()) {
      final s = entry.value;
      final radio = _radioSessions.contains(entry.key);
      final best = link.bestLinkTo(s.to);
      // A radio transfer stops as soon as a fast link appears (it restarts
      // with the full message there), and vice versa.
      final switched = radio != (best == TransportKind.lora);
      if (!link.isReachable(s.to) ||
          switched ||
          now.difference(s.lastProgress) >
              (radio ? radioStallTimeout : stallTimeout)) {
        // Out of reach / stuck: park it, the message stays queued.
        _sessions.remove(entry.key);
        _radioSessions.remove(entry.key);
        _retryAt[entry.key] = now.add(switched ? Duration.zero : retryDelay);
        changed = true;
        continue;
      }
      final pacing = radio
          ? TransferPacing.lora
          : best == TransportKind.ble
          ? TransferPacing.ble
          : TransferPacing.fast;
      for (final pkt in s.due(now, pacing)) {
        await link.sendData(s.to, pkt);
      }
    }

    // Delayed acks on the receiving side, and forget stale partials.
    for (final key in _ackDue.keys.toList()) {
      final wait = _radioRx.contains(key) ? radioAckDelay : ackDelay;
      if (now.difference(_ackDue[key]!) < wait) continue;
      _ackDue.remove(key);
      final r = _rx[key];
      if (r != null) await link.sendData(r.sender, r.ack().encode());
    }
    _rx.removeWhere((k, r) {
      final keep = _radioRx.contains(k)
          ? const Duration(minutes: 10)
          : const Duration(minutes: 2);
      final stale = now.difference(r.lastActivity) > keep;
      if (stale) _radioRx.remove(k);
      return stale;
    });

    await _flushReads(now);

    if (changed) _changed();
  }

  /// Handle a data payload from a peer.
  Future<void> onData(InboundData d) async {
    final pkt = DataPacket.tryDecode(d.payload);
    if (pkt == null || pkt.to != link.localNodeId) return;
    final now = _clock();
    if (pkt is ReadPacket) {
      for (final id in pkt.ids) {
        if (!_read.isClosed) _read.add((id, d.peerId));
      }
      return;
    }
    if (pkt is AckPacket) {
      final id = realMsgId(pkt.msgId);
      final key = (id, d.peerId);
      final ackRadio =
          (pkt.msgId & radioTransferBit) != 0 ||
          d.transport == TransportKind.lora;
      final s = _sessions[key];
      if (s != null) {
        if (s.onAck(pkt, now)) _changed();
        if (s.complete) {
          _sessions.remove(key);
          _radioSessions.remove(key);
          await _deliveredTo(id, d.peerId, viaRadio: ackRadio);
        }
      } else if (pkt.complete) {
        // Completed after the session was parked.
        await _deliveredTo(id, d.peerId, viaRadio: ackRadio);
      }
      return;
    }
    if (pkt is ChunkPacket) {
      final key = (d.peerId, pkt.msgId);
      final id = realMsgId(pkt.msgId);
      final viaRadio = d.transport == TransportKind.lora;
      if (hasSeen(d.peerId, id) ||
          inbox.contains(d.peerId, id) ||
          _chatSeen.contains((d.peerId, id)) ||
          (alreadyHaveChat?.call(d.peerId, id) ?? false)) {
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
      if (viaRadio) _radioRx.add(key);
      final isNew = r.add(pkt, now);
      if (r.complete) {
        _rx.remove(key);
        _ackDue.remove(key);
        _radioRx.remove(key);
        var body = r.assemble();
        await link.sendData(d.peerId, r.ack().encode());
        // Another copy (other transport / re-send) may have completed it
        // while we awaited: only the first one counts.
        if (hasSeen(d.peerId, id)) return;
        await _markSeen(d.peerId, id);
        final name = link.nameOf(d.peerId);
        var clip = VoiceClip.tryDecode(body);
        var radioClip = false;
        if (clip == null && RadioClip.looksLike(body)) {
          final hook = radioClipToVoice;
          final voice = hook == null ? null : await hook(body);
          if (voice == null) return;
          body = voice;
          clip = VoiceClip.tryDecode(body);
          if (clip == null) return;
          radioClip = true;
        }
        if (clip == null) {
          final chat = ChatBody.tryDecode(body);
          if (chat == null) return;
          _chatSeen.add((d.peerId, id));
          if (!_chats.isClosed) {
            _chats.add(
              ChatArrival(
                sender: d.peerId,
                msgId: id,
                senderName: name,
                channel: d.channel,
                channelMessage: pkt.channelMessage,
                receivedAt: now,
                body: chat,
                viaRadio: viaRadio,
              ),
            );
          }
          return;
        }
        final sentAt = clip.sentAt;
        if (sentAt != null && now.difference(sentAt) > maxMessageAge) {
          return; // acknowledged above, but far too old to keep
        }
        final e = InboxEntry(
          sentAt: sentAt,
          sender: d.peerId,
          msgId: id,
          senderName: name,
          channel: d.channel,
          channelMessage: pkt.channelMessage,
          receivedAt: now,
          durationMs: radioClip ? clip.durationMs : pkt.durationMs,
          viaRadio: viaRadio || radioClip,
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

  /// Drop everything queued: nothing in the outbox is sent again, partial
  /// transfers are forgotten, every received message counts as seen (so a
  /// re-send from an older phone is acknowledged but never shown again)
  /// and is marked played, or deleted with [deleteInbox].
  Future<void> clearAll({bool deleteInbox = false}) async {
    for (final e in List.of(outbox.entries)) {
      await outbox.cancel(e.msgId);
    }
    _sessions.clear();
    _bodies.clear();
    _retryAt.clear();
    _attempts.clear();
    _rx.clear();
    _ackDue.clear();
    _radioSessions.clear();
    _radioRx.clear();
    _radioBodies.clear();
    for (final e in List.of(inbox.entries)) {
      await _markSeen(e.sender, e.msgId);
    }
    if (deleteInbox) {
      await inbox.clear();
    } else {
      await inbox.markAllPlayed();
    }
    _changed();
  }

  /// The body to send [e] to [peer] over the LoRa radio, or null when it
  /// should wait for a faster link: voice messages need their Codec 2
  /// clip; chats must be small and not photos; a live location goes at
  /// most every [radioLiveInterval].
  Future<Uint8List?> _radioBody(OutboxEntry e, int peer, DateTime now) async {
    if (!e.isChat) {
      if (!e.hasRadioBody) return null;
      final k = (e.msgId, 0);
      var b = _radioBodies[k];
      if (b == null) {
        b = await outbox.storage.getBlob(e.radioBlobName);
        if (b == null) return null;
        _radioBodies[k] = b;
      }
      return b;
    }
    var body = _bodies[(e.msgId, false)];
    if (body == null) {
      body = await outbox.storage.getBlob(e.blobName);
      if (body == null) return null;
      _bodies[(e.msgId, false)] = body;
    }
    if (body.length > radioMaxChatBody) return null;
    final chat = ChatBody.tryDecode(body);
    if (chat == null || chat.type == ChatType.photo) return null;
    final live = chat.liveId;
    if (live != null) {
      final last = _radioLiveAt[(peer, live)];
      if (last != null && now.difference(last) < radioLiveInterval) {
        return null;
      }
      _radioLiveAt[(peer, live)] = now;
    }
    return body;
  }

  /// Whether [e] can go over the LoRa radio at all.
  bool radioCapable(OutboxEntry e) {
    if (!e.isChat) return e.hasRadioBody;
    final b = _bodies[(e.msgId, false)];
    if (b == null) return true;
    if (b.length > radioMaxChatBody) return false;
    return ChatBody.tryDecode(b)?.type != ChatType.photo;
  }

  /// Deliveries confirmed over the LoRa radio: (msgId, peer).
  final Set<(int, int)> _radioDelivered = {};

  /// [msgId] reached [peer] over the LoRa radio ("delivered via radio").
  bool deliveredOverRadio(int msgId, int peer) =>
      _radioDelivered.contains((msgId, peer));

  Future<void> _deliveredTo(
    int msgId,
    int peer, {
    bool viaRadio = false,
  }) async {
    final e = outbox.byId(msgId);
    if (e == null) return;
    if (viaRadio) {
      _radioDelivered.add((msgId, peer));
      if (_radioDelivered.length > 200) {
        _radioDelivered.remove(_radioDelivered.first);
      }
    }
    _attempts.remove((msgId, peer));
    _retryAt.remove((msgId, peer));
    if (await outbox.markDelivered(msgId, peer)) {
      if (outbox.byId(msgId) == null) {
        _bodies.removeWhere((k, _) => k.$1 == msgId);
        _radioBodies.removeWhere((k, _) => k.$1 == msgId);
      }
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
