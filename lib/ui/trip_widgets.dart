import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

/// Small red SOS button (v1.8.1) that is hard to set off by accident:
/// slide it to the right to arm it, then keep holding for 3 s (a ring
/// fills up). A plain tap only shows how; pocket touches and taps do
/// nothing. Letting go before the ring is full cancels.
class SosSlideButton extends StatefulWidget {
  const SosSlideButton({
    super.key,
    required this.onSend,
    this.holdFor = const Duration(seconds: 3),
    this.slide = 84,
  });
  final VoidCallback onSend;
  final Duration holdFor;

  /// How far (logical px) the button must be slid to arm.
  final double slide;

  static const size = 46.0;
  static const hint = 'Slide and hold to send SOS';

  @override
  State<SosSlideButton> createState() => _SosSlideButtonState();
}

class _SosSlideButtonState extends State<SosSlideButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold =
      AnimationController(vsync: this, duration: widget.holdFor)
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed) _fire();
        });
  double _dx = 0;
  bool _dragging = false;
  bool _armed = false;
  bool _hint = false;
  Timer? _hintTimer;

  @override
  void dispose() {
    _hintTimer?.cancel();
    _hold.dispose();
    super.dispose();
  }

  void _fire() {
    HapticFeedback.heavyImpact();
    _reset();
    widget.onSend();
  }

  void _reset() {
    _hold.reset();
    if (!mounted) return;
    setState(() {
      _dx = 0;
      _dragging = false;
      _armed = false;
    });
  }

  void _showHint() {
    HapticFeedback.selectionClick();
    _hintTimer?.cancel();
    setState(() => _hint = true);
    _hintTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _hint = false);
    });
  }

  void _onStart(DragStartDetails _) {
    HapticFeedback.selectionClick();
    _hintTimer?.cancel();
    setState(() {
      _dragging = true;
      _hint = false;
    });
  }

  void _onUpdate(DragUpdateDetails d) {
    final dx = (_dx + d.delta.dx).clamp(0.0, widget.slide);
    final armed = _armed
        ? dx >=
              widget.slide *
                  0.6 // hysteresis: slide back to disarm
        : dx >= widget.slide;
    if (armed && !_armed) {
      HapticFeedback.mediumImpact();
      _hold.forward(from: 0);
    } else if (!armed && _armed) {
      _hold.reset();
    }
    setState(() {
      _dx = dx;
      _armed = armed;
    });
  }

  void _onEnd([Object? _]) {
    if (_hold.isCompleted) return;
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    const size = SosSlideButton.size;
    final slide = widget.slide;
    return Semantics(
      button: true,
      label: 'SOS. Slide right, then hold for 3 seconds',
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (_dragging)
              Positioned(
                left: 0,
                top: 0,
                width: size + slide,
                height: size,
                child: IgnorePointer(
                  child: Container(
                    key: const Key('sosTrack'),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(size / 2),
                      border: Border.all(color: Colors.red.shade300),
                    ),
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(
                      _armed ? Icons.touch_app : Icons.double_arrow,
                      color: Colors.white70,
                      size: 20,
                    ),
                  ),
                ),
              ),
            if (_hint || _dragging)
              Positioned(
                left: 0,
                bottom: size + 6,
                child: IgnorePointer(
                  child: Container(
                    key: const Key('sosHint'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.8),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _armed
                          ? 'Keep holding... ${(widget.holdFor.inMilliseconds * (1 - _hold.value) / 1000).ceil()}'
                          : _dragging
                          ? 'Slide all the way, then hold'
                          : SosSlideButton.hint,
                      softWrap: false,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ),
              ),
            // Keyed: the track / hint appear before it mid-drag, and the
            // gesture must survive that rebuild.
            Positioned(
              key: const ValueKey('sosKnob'),
              left: _dx,
              top: 0,
              child: GestureDetector(
                key: const Key('sosButton'),
                behavior: HitTestBehavior.opaque,
                onTap: _showHint,
                onHorizontalDragStart: _onStart,
                onHorizontalDragUpdate: _onUpdate,
                onHorizontalDragEnd: _onEnd,
                onHorizontalDragCancel: _onEnd,
                child: AnimatedBuilder(
                  animation: _hold,
                  builder: (context, _) => SizedBox(
                    width: size,
                    height: size,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: size - 6,
                          height: size - 6,
                          decoration: BoxDecoration(
                            color: _armed
                                ? Colors.red.shade900
                                : Colors.red.shade700,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: const [
                              BoxShadow(blurRadius: 3, color: Colors.black38),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: const Text(
                            'SOS',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        if (_armed)
                          SizedBox(
                            width: size,
                            height: size,
                            child: CircularProgressIndicator(
                              key: const Key('sosRing'),
                              value: _hold.value,
                              strokeWidth: 4,
                              color: Colors.white,
                              backgroundColor: Colors.red.shade200,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// My SOS is on (small, in a map corner): tap for who answered / cancel.
class SosActivePill extends StatelessWidget {
  const SosActivePill({super.key, required this.acks, required this.onTap});
  final int acks;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.red.shade700,
    shape: const StadiumBorder(side: BorderSide(color: Colors.white, width: 2)),
    elevation: 3,
    child: InkWell(
      key: const Key('sosActive'),
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          acks == 0 ? 'SOS ON' : 'SOS ON · $acks answered',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    ),
  );
}

/// Offline power save status chip (Trip tab): tap to turn it on / off.
class OfflineSaverChip extends StatelessWidget {
  const OfflineSaverChip({super.key, required this.on, required this.onTap});
  final bool on;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: on ? Colors.green.shade700 : cs.surface.withValues(alpha: 0.92),
      shape: const StadiumBorder(),
      elevation: 2,
      child: InkWell(
        key: const Key('offlineSaverChip'),
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.energy_savings_leaf,
                size: 18,
                color: on ? Colors.white : Colors.green.shade700,
              ),
              const SizedBox(width: 4),
              Text(
                on ? 'Power save on' : 'Power save',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: on ? Colors.white : cs.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Trip tab layout (v1.8.1): a big map with a small guarded SOS in its
/// bottom-left corner and the panel below; or the map alone, edge to edge
/// ([full]), with the same controls and SOS. Back leaves full screen.
class TripLayout extends StatelessWidget {
  const TripLayout({
    super.key,
    required this.full,
    required this.onFull,
    required this.map,
    required this.panel,
    required this.sos,
    this.controls = const [],
    this.fullControls = const [],
    this.topLeft = const [],
  });
  final bool full;
  final ValueChanged<bool> onFull;

  /// The map itself (fills its box).
  final Widget map;
  final Widget panel;

  /// [SosSlideButton] or [SosActivePill].
  final Widget sos;

  /// Round map buttons (recenter, layers, offline, pin), top right under
  /// the full-screen toggle.
  final List<Widget> controls;

  /// Extra buttons only in full screen (zoom: pinch works too, and the
  /// smaller map has no room for them).
  final List<Widget> fullControls;

  /// Chips top left (power save, waiting for GPS).
  final List<Widget> topLeft;

  /// Share of the height the map gets when not full screen.
  static const mapShare = 0.6;

  @override
  Widget build(BuildContext context) {
    final mapStack = Stack(
      children: [
        Positioned.fill(child: map),
        Positioned(
          right: 8,
          top: 8,
          bottom: 8,
          child: SingleChildScrollView(
            child: Column(
              children: [
                RoundMapButton(
                  key: const Key('mapFullScreen'),
                  icon: full ? Icons.fullscreen_exit : Icons.fullscreen,
                  tip: full ? 'Exit full screen' : 'Full-screen map',
                  onTap: () => onFull(!full),
                ),
                ...controls,
                if (full) ...fullControls,
              ],
            ),
          ),
        ),
        Positioned(
          left: 8,
          top: 8,
          right: 64,
          child: Wrap(spacing: 6, runSpacing: 6, children: topLeft),
        ),
        Positioned(left: 12, bottom: 22, child: sos),
      ],
    );
    return PopScope(
      canPop: !full,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && full) onFull(false);
      },
      // Same tree in both modes so the map keeps its camera and tiles.
      child: LayoutBuilder(
        builder: (context, box) {
          final mapH = full
              ? box.maxHeight
              : (box.maxHeight * mapShare).clamp(240.0, 640.0);
          return Column(
            children: [
              SizedBox(
                key: const Key('tripMap'),
                height: mapH,
                child: mapStack,
              ),
              if (!full) Expanded(child: panel),
            ],
          );
        },
      ),
    );
  }
}

/// Round button on the map.
class RoundMapButton extends StatelessWidget {
  const RoundMapButton({
    super.key,
    required this.icon,
    required this.tip,
    required this.onTap,
    this.color,
  });
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  final Color? color;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Material(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
      shape: const CircleBorder(),
      elevation: 2,
      child: IconButton(
        tooltip: tip,
        icon: Icon(icon, color: color),
        onPressed: onTap,
      ),
    ),
  );
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
