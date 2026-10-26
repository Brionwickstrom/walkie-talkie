import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../core/peer.dart';
import '../core/transport.dart';
import '../trip/geo.dart';
import 'home_view.dart';

/// Who is connected through whom (direct links, phone relays, LoRa radio),
/// with signal and last heard: a small graph plus a list, like
/// Meshtastic's node list. Helps find dead spots on a trail.
class NetworkMapPage extends StatefulWidget {
  const NetworkMapPage({super.key, required this.controller});
  final WalkieController controller;
  @override
  State<NetworkMapPage> createState() => _NetworkMapPageState();
}

class NetNode {
  NetNode(this.id, this.name);
  final int id;
  final String name;
  List<TransportKind> links = [];
  int? hops;
  bool radio = false;
  double? snr;
  int? radioRssi;
  int? radioHops;
  Map<TransportKind, Duration> rtt = {};
  Map<TransportKind, int> rssi = {};
  Duration? lastHeard;

  /// Mesh neighbour that hears this phone directly (for relayed ones).
  int? via;
  bool sameChannel = true;
}

class _NetworkMapPageState extends State<NetworkMapPage> {
  WalkieController get c => widget.controller;

  List<NetNode> _nodes() {
    final now = DateTime.now();
    final m = c.manager;
    final mesh = m.mesh;
    final radio = c.loraTransport.peerSignals;
    final out = <NetNode>[];
    for (final Peer p in c.peers) {
      final n = NetNode(p.id, p.displayName)
        ..links = (m.fastLinks(p, now)
          ..sort((a, b) => b.defaultPriority.compareTo(a.defaultPriority)))
        ..hops = p.meshHops
        ..rtt = Map.of(p.rtt)
        ..rssi = Map.of(p.rssi)
        ..sameChannel = p.channel == c.scope;
      DateTime? last;
      for (final t in [...p.lastSeen.values, ?p.meshSeen]) {
        if (last == null || t.isAfter(last)) last = t;
      }
      n.lastHeard = last == null ? null : now.difference(last);
      final r = radio[p.id];
      if (r != null && now.difference(r.at) < const Duration(minutes: 16)) {
        n
          ..radio = true
          ..snr = r.snr
          ..radioRssi = r.rssi
          ..radioHops = r.hopsAway;
      }
      if (n.links.isEmpty && n.hops != null) {
        for (final nb in mesh.meshNeighbours()) {
          if (mesh.neighbourHears(nb, p.id)) {
            n.via = nb;
            break;
          }
        }
      }
      out.add(n);
    }
    out.sort((a, b) {
      int rank(NetNode n) => n.links.isNotEmpty
          ? 0
          : n.hops != null
          ? 1
          : n.radio
          ? 2
          : 3;
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final nodes = _nodes();
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(title: const Text('Network map')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                AspectRatio(
                  aspectRatio: 1.2,
                  child: Card(
                    child: CustomPaint(
                      painter: NetGraphPainter(
                        me: c.name,
                        nodes: nodes,
                        colors: theme.colorScheme,
                        text: theme.textTheme.bodySmall!,
                      ),
                    ),
                  ),
                ),
                Wrap(
                  spacing: 12,
                  children: [
                    _legend(Colors.green, 'direct'),
                    _legend(Colors.orange, 'via other phones'),
                    _legend(Colors.purple, 'LoRa radio', dashed: true),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  c.manager.mesh.debugInfo,
                  style: theme.textTheme.bodySmall,
                ),
                if (c.radioPaired)
                  Text(
                    'Radio: ${c.loraTransport.debugInfo}',
                    style: theme.textTheme.bodySmall,
                  ),
                const Divider(),
                if (nodes.isEmpty) const Text('No other phones heard yet.'),
                for (final n in nodes) _tile(context, n),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _legend(Color color, String text, {bool dashed = false}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 18,
        height: 3,
        color: dashed ? color.withValues(alpha: 0.6) : color,
      ),
      const SizedBox(width: 4),
      Text(text),
    ],
  );

  Widget _tile(BuildContext context, NetNode n) {
    final parts = <String>[];
    for (final k in n.links) {
      final bits = [transportName(k)];
      final rtt = n.rtt[k];
      if (rtt != null) bits.add('${rtt.inMilliseconds} ms');
      final rssi = n.rssi[k];
      if (rssi != null) bits.add('$rssi dBm');
      parts.add(bits.join(' '));
    }
    if (n.links.isEmpty && n.hops != null) {
      parts.add(
        '${n.hops} hops${n.via != null ? ' via ${c.nameOf(n.via!)}' : ''}',
      );
    }
    if (n.radio) {
      parts.add(
        'LoRa SNR ${n.snr?.toStringAsFixed(1) ?? '?'} dB, ${n.radioRssi ?? '?'} dBm'
        '${n.radioHops != null && n.radioHops! > 0 ? ', ${n.radioHops} radio hops' : ''}',
      );
    }
    if (parts.isEmpty) parts.add('no path right now');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Avatar(id: n.id, name: n.name),
      title: Text(n.name + (n.sameChannel ? '' : ' (other channel)')),
      subtitle: Text(
        '${parts.join(' · ')}\nlast heard ${n.lastHeard == null ? 'never' : formatAge(n.lastHeard!)}',
      ),
      isThreeLine: true,
      trailing: Icon(
        n.links.isNotEmpty
            ? transportIcon(n.links.first)
            : n.hops != null
            ? Icons.hub
            : n.radio
            ? Icons.settings_input_antenna
            : Icons.link_off,
      ),
    );
  }
}

/// Me in the middle, direct phones on the inner ring, relayed / radio-only
/// phones on the outer ring (linked to the phone that relays them).
class NetGraphPainter extends CustomPainter {
  NetGraphPainter({
    required this.me,
    required this.nodes,
    required this.colors,
    required this.text,
  });
  final String me;
  final List<NetNode> nodes;
  final ColorScheme colors;
  final TextStyle text;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r1 = math.min(size.width, size.height) * 0.27;
    final r2 = math.min(size.width, size.height) * 0.43;
    final inner = nodes.where((n) => n.links.isNotEmpty).toList();
    final outer = nodes.where((n) => n.links.isEmpty).toList();
    final pos = <int, Offset>{};
    for (var i = 0; i < inner.length; i++) {
      final a = -math.pi / 2 + 2 * math.pi * i / math.max(1, inner.length);
      pos[inner[i].id] = c + Offset(math.cos(a), math.sin(a)) * r1;
    }
    for (var i = 0; i < outer.length; i++) {
      final a =
          -math.pi / 2 +
          math.pi / math.max(2, outer.length) +
          2 * math.pi * i / math.max(1, outer.length);
      pos[outer[i].id] = c + Offset(math.cos(a), math.sin(a)) * r2;
    }
    final line = Paint()
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (final n in inner) {
      canvas.drawLine(c, pos[n.id]!, line..color = Colors.green);
    }
    for (final n in outer) {
      final p = pos[n.id]!;
      if (n.hops != null) {
        final from = n.via != null && pos.containsKey(n.via) ? pos[n.via]! : c;
        canvas.drawLine(from, p, line..color = Colors.orange);
      } else if (n.radio) {
        _dashed(
          canvas,
          c,
          p,
          line..color = Colors.purple.withValues(alpha: 0.7),
        );
      }
    }
    _node(canvas, c, 'You', colors.primary, big: true);
    for (final n in nodes) {
      _node(
        canvas,
        pos[n.id]!,
        n.name,
        n.links.isEmpty && n.hops == null && !n.radio
            ? Colors.grey
            : avatarColor(n.id),
      );
    }
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint p) {
    final d = (b - a).distance;
    final dir = (b - a) / d;
    for (var t = 0.0; t < d; t += 10) {
      canvas.drawLine(a + dir * t, a + dir * math.min(d, t + 6), p);
    }
  }

  void _node(
    Canvas canvas,
    Offset at,
    String label,
    Color color, {
    bool big = false,
  }) {
    canvas.drawCircle(at, big ? 14 : 10, Paint()..color = color);
    final tp = TextPainter(
      text: TextSpan(text: label, style: text),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 90);
    tp.paint(canvas, at + Offset(-tp.width / 2, big ? 16 : 12));
  }

  @override
  bool shouldRepaint(covariant NetGraphPainter old) => true;
}
