import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../trip/geo.dart';
import '../trip/sos.dart';
import '../trip/trip_controller.dart';
import '../trip/trip_packet.dart';
import 'home_view.dart';

String hhmm(DateTime t) {
  final l = t.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '$h:${l.minute.toString().padLeft(2, '0')} ${l.hour < 12 ? 'AM' : 'PM'}';
}

IconData pinIcon(PinType t) => switch (t) {
  PinType.camp => Icons.cabin,
  PinType.water => Icons.water_drop,
  PinType.trailhead => Icons.signpost,
  PinType.meetup => Icons.groups,
  PinType.danger => Icons.warning_amber,
  PinType.car => Icons.directions_car,
  PinType.custom => Icons.place,
};

Color pinColor(PinType t) => switch (t) {
  PinType.camp => Colors.brown,
  PinType.water => Colors.blue,
  PinType.trailhead => Colors.green.shade800,
  PinType.meetup => Colors.purple,
  PinType.danger => Colors.orange.shade800,
  PinType.car => Colors.blueGrey,
  PinType.custom => Colors.red,
};

/// Arrow pointing at a bearing, relative to the phone's heading.
class BearingArrow extends StatelessWidget {
  const BearingArrow({
    super.key,
    required this.angleDeg,
    this.size = 20,
    this.color,
  });
  final double angleDeg;
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: angleDeg * math.pi / 180,
    child: Icon(
      Icons.navigation,
      size: size,
      color: color ?? Theme.of(context).colorScheme.secondary,
    ),
  );
}

/// Big red SOS button: hold 3 s to send, or tap and confirm.
class SosButton extends StatefulWidget {
  const SosButton({super.key, required this.onSend});
  final VoidCallback onSend;
  @override
  State<SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends State<SosButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold =
      AnimationController(vsync: this, duration: const Duration(seconds: 3))
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed) {
            _hold.reset();
            widget.onSend();
          }
        });

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.sos, color: Colors.red, size: 40),
        title: const Text('Send SOS?'),
        content: const Text(
          'Everyone in range gets a loud alarm with your location, over '
          'every path (internet, Wi-Fi, Bluetooth, phone relay and the '
          'LoRa radio). It repeats until someone answers.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send SOS'),
          ),
        ],
      ),
    );
    if (ok == true) widget.onSend();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'SOS. Hold for 3 seconds, or tap to confirm',
      child: Listener(
        onPointerDown: (_) => _hold.forward(from: 0),
        onPointerUp: (_) {
          if (_hold.isAnimating) _hold.reset();
        },
        onPointerCancel: (_) => _hold.reset(),
        child: GestureDetector(
          onTap: _confirm,
          child: AnimatedBuilder(
            animation: _hold,
            builder: (context, _) => Container(
              key: const Key('sosButton'),
              height: 64,
              decoration: BoxDecoration(
                color: Colors.red.shade700,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: _hold.value,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.red.shade900,
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                  Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.sos, color: Colors.white, size: 32),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            _hold.isAnimating
                                ? 'Keep holding... ${(3 - _hold.value * 3).ceil()}'
                                : 'Hold 3 s for SOS',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// My SOS is active: who answered, cancel.
class ActiveSosCard extends StatelessWidget {
  const ActiveSosCard({
    super.key,
    required this.sos,
    required this.nameOf,
    required this.onCancel,
  });
  final OutgoingSos sos;
  final String Function(int) nameOf;
  final VoidCallback onCancel;
  @override
  Widget build(BuildContext context) {
    final acks = sos.acks.keys.map(nameOf).toList();
    return Card(
      color: Colors.red.shade700,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.sos, color: Colors.white, size: 30),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'SOS SENT',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              acks.isEmpty
                  ? 'Repeating every 10 s until someone answers '
                        '(sent ${sos.repeats}x${sos.radioSends > 0 ? ', ${sos.radioSends}x by radio' : ''}). '
                        '${sos.pos == null ? 'Waiting for GPS...' : 'Your location is included.'}'
                  : 'Acknowledged by ${acks.join(', ')}. Help knows where you are.',
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white),
              ),
              icon: const Icon(Icons.cancel),
              label: const Text('Cancel SOS (I am OK)'),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Cancel your SOS?'),
                    content: const Text('Everyone is told you are OK.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Keep SOS on'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Cancel SOS'),
                      ),
                    ],
                  ),
                );
                if (ok == true) onCancel();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen alert for someone else's SOS.
class SosAlertPage extends StatelessWidget {
  const SosAlertPage({
    super.key,
    required this.controller,
    required this.alert,
    this.onShowMap,
  });
  final WalkieController controller;
  final IncomingSos alert;
  final VoidCallback? onShowMap;

  @override
  Widget build(BuildContext context) {
    final t = controller.trip!;
    return ListenableBuilder(
      listenable: t,
      builder: (context, _) {
        final s = alert;
        final name = controller.nameOf(s.origin);
        final me = t.myFix?.pos;
        final p = s.pos;
        final acked = s.ackedAt != null;
        final others = s.ackers.keys
            .where((id) => id != controller.nodeId)
            .map(controller.nameOf)
            .toList();
        return Scaffold(
          backgroundColor: s.cancelled
              ? Colors.grey.shade800
              : Colors.red.shade800,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.sos, color: Colors.white, size: 72),
                  Text(
                    s.cancelled ? '$name cancelled the SOS' : 'SOS from $name',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Received ${hhmm(s.firstAt)}${s.held ? ' (held by base camp)' : ''}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const Spacer(),
                  if (p != null && me != null) ...[
                    Center(
                      child: BearingArrow(
                        angleDeg: arrowAngleDeg(bearingDeg(me, p), t.heading),
                        size: 96,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      formatDistanceBearing(
                        me,
                        p,
                        imperial: t.settings.imperial,
                      ),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                  if (p != null)
                    SelectableText(
                      '${p.lat.toStringAsFixed(5)}, ${p.lng.toStringAsFixed(5)}'
                      '${s.accuracyM != null ? ' (±${s.accuracyM!.round()} m)' : ''}'
                      '${s.posAt != null ? '\nlocation ${formatAge(DateTime.now().difference(s.posAt!))} old' : ''}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    )
                  else
                    const Text(
                      'No location yet (their GPS has no fix).',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  if (others.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'Also answered: ${others.join(', ')}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  const Spacer(),
                  if (!s.cancelled && !acked)
                    FilledButton.icon(
                      key: const Key('ackSos'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.red.shade800,
                        minimumSize: const Size.fromHeight(64),
                        textStyle: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      icon: const Icon(Icons.check_circle),
                      label: const Text('Acknowledge - I am coming / on it'),
                      onPressed: () => t.acknowledgeSos(s),
                    ),
                  if (acked)
                    const Text(
                      'You acknowledged. They have been told.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white),
                          ),
                          icon: const Icon(Icons.volume_off),
                          label: const Text('Silence'),
                          onPressed: () => controller.bridge.silenceSos(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Colors.white),
                          ),
                          icon: const Icon(Icons.map),
                          label: const Text('Map'),
                          onPressed: () {
                            Navigator.pop(context);
                            onShowMap?.call();
                          },
                        ),
                      ),
                    ],
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      'Close',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Row of tiny coded quick messages.
class CannedBar extends StatelessWidget {
  const CannedBar({super.key, required this.trip, required this.onEdit});
  final TripController trip;
  final VoidCallback onEdit;
  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      for (var code = 1; code <= 5; code++)
        ActionChip(
          avatar: Icon(
            switch (code) {
              1 => Icons.directions_walk,
              2 => Icons.pan_tool,
              3 => Icons.priority_high,
              4 => Icons.cabin,
              _ => Icons.thumb_up,
            },
            size: 18,
            color: code == 3 ? Colors.red : null,
          ),
          label: Text(builtinCanned[code]),
          onPressed: () => trip.sendCanned(code: code),
        ),
      for (var code = 6; code < builtinCanned.length; code++)
        ActionChip(
          label: Text(builtinCanned[code]),
          onPressed: () => trip.sendCanned(code: code),
        ),
      for (final t in trip.settings.canned)
        ActionChip(
          label: Text(t),
          onPressed: () => trip.sendCanned(text: t),
        ),
      ActionChip(
        avatar: const Icon(Icons.edit, size: 18),
        label: const Text('Edit'),
        onPressed: onEdit,
      ),
    ];
    return Wrap(spacing: 6, runSpacing: 2, children: chips);
  }
}

/// Person row on the Trip tab: distance, bearing arrow, fix age, path.
class TripPersonTile extends StatelessWidget {
  const TripPersonTile({
    super.key,
    required this.id,
    required this.name,
    required this.trip,
    this.onTap,
    this.lost = false,
  });
  final int id;
  final String name;
  final TripController trip;
  final VoidCallback? onTap;
  final bool lost;
  @override
  Widget build(BuildContext context) {
    final pp = trip.people[id];
    final me = trip.myFix?.pos;
    final cs = Theme.of(context).colorScheme;
    String sub;
    if (pp == null) {
      sub = 'No location shared';
    } else {
      sub = [
        if (me != null)
          formatDistanceBearing(me, pp.pos, imperial: trip.settings.imperial),
        'fix ${formatAge(DateTime.now().difference(pp.at))} old',
        if (pp.hops > 1)
          'via ${pp.hops} hops'
        else
          'via ${transportName(pp.via)}',
      ].join(' · ');
    }
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Avatar(id: id, name: name),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(sub, style: lost ? TextStyle(color: cs.error) : null),
      trailing: pp != null && me != null
          ? BearingArrow(
              angleDeg: arrowAngleDeg(bearingDeg(me, pp.pos), trip.heading),
              size: 28,
            )
          : pp != null
          ? Icon(transportIcon(pp.via), color: cs.outline)
          : null,
      onTap: onTap,
    );
  }
}

/// One-line text prompt.
Future<String?> askText(
  BuildContext context, {
  required String title,
  String hint = '',
  String initial = '',
}) async {
  final ctrl = TextEditingController(text: initial);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  return ok == true ? ctrl.text : null;
}
