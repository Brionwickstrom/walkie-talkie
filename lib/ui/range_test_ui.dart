import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data' show BytesBuilder;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../trip/geo.dart';
import '../trip/range_test.dart';
import 'sheets.dart';

const Color rangeGreen = Color(0xFF2E7D32);
const Color rangeRed = Color(0xFFC62828);

Color rangeColor(RangeKind k) => k == RangeKind.connect ? rangeGreen : rangeRed;

String rangeTitle(RangeKind k) =>
    k == RangeKind.connect ? 'Connected' : 'Dropped';

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "5:44 PM" (with seconds when [seconds]).
String rangeClock(DateTime t, {bool seconds = false}) {
  final l = t.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  final mm = l.minute.toString().padLeft(2, '0');
  final ss = seconds ? ':${l.second.toString().padLeft(2, '0')}' : '';
  return '$h:$mm$ss ${l.hour < 12 ? 'AM' : 'PM'}';
}

/// "Fri Oct 30, 5:44:34 PM".
String rangeWhen(DateTime t) {
  final l = t.toLocal();
  return '${_days[l.weekday - 1]} ${_months[l.month - 1]} ${l.day}, '
      '${rangeClock(l, seconds: true)}';
}

/// "Direct (no relays)", "1 relay", "3 relays".
String rangeHops(int? h) => h == null
    ? 'unknown'
    : h == 0
    ? 'Direct (no relays)'
    : '$h relay${h == 1 ? '' : 's'}';

/// The green / red markers. A blurred position carries "~" in its label.
List<Marker> rangeMarkers(RangeTest rt, {void Function(RangeEvent e)? onTap}) {
  if (!rt.visible) return const [];
  return [
    for (final e in rt.events)
      Marker(
        key: Key('range-${e.id}'),
        point: LatLng(e.pos.lat, e.pos.lng),
        width: 96,
        height: 62,
        child: GestureDetector(
          onTap: onTap == null ? null : () => onTap(e),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 4),
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: rangeColor(e.kind),
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: const [
                    BoxShadow(blurRadius: 3, color: Colors.black38),
                  ],
                ),
                child: Icon(
                  e.kind == RangeKind.connect ? Icons.check : Icons.close,
                  size: 16,
                  color: Colors.white,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: rangeColor(e.kind), width: 1),
                ),
                child: Text(
                  '${rangeClock(e.at)}${e.approximate ? ' ~' : ''}',
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.black87,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
  ];
}

/// The "could be anywhere in here" circle for a blurred marker.
List<CircleMarker> rangeCircles(RangeTest rt, RangeEvent? selected) {
  if (!rt.visible || selected == null || !selected.approximate) return const [];
  if (!rt.events.any((e) => e.id == selected.id)) return const [];
  return [
    CircleMarker(
      point: LatLng(selected.pos.lat, selected.pos.lng),
      radius: rangeBlurM,
      useRadiusInMeter: true,
      color: rangeColor(selected.kind).withValues(alpha: 0.10),
      borderColor: rangeColor(selected.kind).withValues(alpha: 0.5),
      borderStrokeWidth: 1,
    ),
  ];
}

/// What the tap on a marker shows.
Future<void> showRangeEventSheet(
  BuildContext context,
  RangeTest rt,
  RangeEvent e, {
  bool imperial = true,
}) {
  final cs = Theme.of(context).colorScheme;
  return showAppSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              key: const Key('rangeSheet'),
              leading: CircleAvatar(
                backgroundColor: rangeColor(e.kind),
                child: Icon(
                  e.kind == RangeKind.connect ? Icons.check : Icons.close,
                  color: Colors.white,
                ),
              ),
              title: Text(
                e.kind == RangeKind.connect
                    ? 'Connected to the home radio'
                    : 'Dropped off the home radio',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              subtitle: Text(rangeWhen(e.at)),
            ),
            _row('Signal (SNR)', e.snr == null ? 'unknown' : '${e.snr} dB'),
            _row('Hops', rangeHops(e.hops)),
            _row(
              'Distance from home',
              e.distM == null
                  ? 'unknown'
                  : formatDistance(e.distM!, imperial: imperial),
            ),
            _row(
              'Spot',
              '${e.pos.lat.toStringAsFixed(5)}, '
                  '${e.pos.lng.toStringAsFixed(5)}',
            ),
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (e.approximate ? Colors.amber : rangeGreen).withValues(
                  alpha: 0.15,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                key: const Key('rangeAccuracy'),
                e.approximate
                    ? 'Approximate, blurred position: the radio hides its '
                          'exact spot, so the real place can be up to about '
                          '3 km (2 mi) away. The circle on the map shows how '
                          'far.'
                    : 'Exact position.',
                style: TextStyle(color: cs.onSurface),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('rangeRemove'),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Remove this marker'),
              onPressed: () {
                Navigator.pop(ctx);
                unawaited(rt.remove(e));
              },
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _row(String k, String v) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(width: 150, child: Text(k)),
      Expanded(
        child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    ],
  ),
);

/// Settings for the range test markers: show / hide, import (file, pasted
/// text, this PC's range test), copy, clear.
class RangeTestPage extends StatefulWidget {
  const RangeTestPage({
    super.key,
    required this.range,
    this.onShow,
    this.imperial = true,
    this.pcFile,
  });
  final RangeTest range;

  /// Centre the Trip map on a marker.
  final void Function(RangeEvent e)? onShow;
  final bool imperial;

  /// Tests: the range_state.json to offer instead of the PC's.
  final File? pcFile;

  @override
  State<RangeTestPage> createState() => _RangeTestPageState();
}

class _RangeTestPageState extends State<RangeTestPage> {
  RangeTest get rt => widget.range;

  void _say(String s) =>
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(s)));

  String _summary(RangeImport r) {
    final n = r.found;
    final base = n == 0
        ? 'No connect or drop markers found'
        : '$n marker${n == 1 ? '' : 's'} ('
              '${r.added} new${r.updated > 0 ? ', ${r.updated} already there' : ''})';
    return r.noPlace == 0
        ? '$base.'
        : '$base. ${r.noPlace} had no position and were skipped.';
  }

  Future<void> _file() async {
    try {
      final files = await FilePicker.pickFiles(
        dialogTitle: 'Pick range_state.json',
      );
      if (files.isEmpty) return;
      final b = BytesBuilder(copy: false);
      await for (final c in files.first.readAsByteStream()) {
        b.add(c);
        if (b.length > 2 * 1024 * 1024) throw const FormatException('too big');
      }
      final r = await rt.importText(
        utf8.decode(b.takeBytes(), allowMalformed: true),
      );
      if (mounted) _say(_summary(r));
    } on FormatException {
      if (mounted) {
        _say('That is not a range test file (range_state.json).');
      }
    } catch (e) {
      if (mounted) _say('Could not read the file: $e');
    }
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final text = d?.text ?? '';
    if (text.trim().isEmpty) {
      _say('Nothing copied yet. Copy the range test text first.');
      return;
    }
    try {
      final r = await rt.importText(text);
      if (mounted) _say(_summary(r));
    } on FormatException {
      if (mounted) {
        _say('The copied text has no range test markers in it.');
      }
    }
  }

  Future<void> _pc() async {
    final r = await rt.importFromPc(file: widget.pcFile);
    if (!mounted) return;
    _say(r == null ? 'Nothing new from the PC range test.' : _summary(r));
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: rt.toText()));
    if (!mounted) return;
    _say('Copied ${rt.length} markers. Paste them on another device.');
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all range test markers?'),
        content: const Text(
          'This only removes the markers from this device. The range test '
          'files on the PC stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            key: const Key('rangeClearYes'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) await rt.clear();
  }

  @override
  Widget build(BuildContext context) {
    final showPc = widget.pcFile != null || RangeTest.pcRangeFile() != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Range test markers')),
      body: ListenableBuilder(
        listenable: rt,
        builder: (context, _) {
          final list = rt.events.reversed.toList();
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              SwitchListTile(
                key: const Key('rangeVisible'),
                title: const Text('Show on the map'),
                subtitle: const Text(
                  'Green = connected to the home radio, red = dropped. Tap '
                  'a marker for time, signal, hops and distance.',
                ),
                value: rt.visible,
                onChanged: (v) => rt.setVisible(v),
              ),
              SwitchListTile(
                key: const Key('rangeExact'),
                title: const Text('New positions are exact'),
                subtitle: const Text(
                  'Leave off while the radio blurs its position (about 3 km). '
                  'Turn on once it shares Full precision.',
                ),
                value: rt.importExact,
                onChanged: (v) => rt.setImportExact(v),
              ),
              const Divider(),
              if (showPc)
                ListTile(
                  key: const Key('rangePc'),
                  leading: const Icon(Icons.computer),
                  title: const Text('Import from this PC'),
                  subtitle: const Text(
                    'The range test on this PC (meshtastic_watch folder). '
                    'Also checked by itself when the map opens.',
                  ),
                  onTap: _pc,
                ),
              ListTile(
                key: const Key('rangePaste'),
                leading: const Icon(Icons.content_paste),
                title: const Text('Paste copied markers'),
                subtitle: const Text(
                  'Text you copied: the range test lines or the whole file.',
                ),
                onTap: _paste,
              ),
              ListTile(
                key: const Key('rangeFile'),
                leading: const Icon(Icons.file_open),
                title: const Text('Import a range test file'),
                subtitle: const Text('range_state.json'),
                onTap: _file,
              ),
              ListTile(
                key: const Key('rangeCopy'),
                leading: const Icon(Icons.copy),
                title: const Text('Copy markers'),
                subtitle: const Text(
                  'To paste into the app on another device.',
                ),
                enabled: !rt.isEmpty,
                onTap: rt.isEmpty ? null : _copy,
              ),
              ListTile(
                key: const Key('rangeClear'),
                leading: const Icon(Icons.delete_outline),
                title: const Text('Clear all markers'),
                enabled: !rt.isEmpty,
                onTap: rt.isEmpty ? null : _clear,
              ),
              const Divider(),
              if (list.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No markers yet.'),
                ),
              for (final e in list)
                ListTile(
                  key: Key('rangeRow-${e.id}'),
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: rangeColor(e.kind),
                    child: Icon(
                      e.kind == RangeKind.connect ? Icons.check : Icons.close,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                  title: Text(
                    '${rangeTitle(e.kind)} · ${rangeClock(e.at, seconds: true)}',
                  ),
                  subtitle: Text(
                    [
                      if (e.snr != null) 'SNR ${e.snr}',
                      rangeHops(e.hops),
                      if (e.distM != null)
                        formatDistance(e.distM!, imperial: widget.imperial),
                      if (e.approximate) 'approximate',
                    ].join(' · '),
                  ),
                  onTap: widget.onShow == null ? null : () => widget.onShow!(e),
                ),
            ],
          );
        },
      ),
    );
  }
}
