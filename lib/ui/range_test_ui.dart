import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File;
import 'dart:typed_data' show BytesBuilder;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../trip/geo.dart';
import '../trip/range_logger.dart';
import '../trip/range_test.dart';

import 'package:path_provider/path_provider.dart';

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

/// "!0b4f84fb" or "0b4f84fb" as a node number, null if it is not one.
int? parseNodeId(String s) {
  final t = s.trim().replaceFirst(
    RegExp(r'^[!#]|^0x', caseSensitive: false),
    '',
  );
  if (!RegExp(r'^[0-9a-fA-F]{1,8}$').hasMatch(t)) return null;
  final v = int.parse(t, radix: 16);
  return v == 0 || v == 0xFFFFFFFF ? null : v;
}

/// Red (weak, -15 dB or worse) through amber to green (0 dB or better).
Color snrColor(double? snr) {
  if (snr == null) return const Color(0xFF9E9E9E);
  final t = ((snr + 15) / 15).clamp(0.0, 1.0);
  return HSVColor.fromAHSV(1, 120 * t, 0.85, 0.75).toColor();
}

const Color noReplyFill = Color(0xFF757575);

/// The logged points of range logging (v2.5.9): answered pings graded by
/// SNR, packets heard (smaller), no-reply pings grey with a red ring. The
/// newest [max] are drawn.
List<CircleMarker> rangeSampleCircles(RangeTest rt, {int max = 1500}) {
  if (!rt.visible || rt.samples.isEmpty) return const [];
  final all = rt.samples;
  final list = all.length > max ? all.sublist(all.length - max) : all;
  return [
    for (final x in list)
      CircleMarker(
        point: LatLng(x.pos.lat, x.pos.lng),
        radius: switch (x.kind) {
          SampleKind.ok => 6,
          SampleKind.fail => 5,
          SampleKind.heard => 3.5,
        },
        useRadiusInMeter: false,
        color: x.kind == SampleKind.fail
            ? noReplyFill.withValues(alpha: 0.9)
            : snrColor(x.snr)
                  .withValues(alpha: x.kind == SampleKind.heard ? 0.75 : 0.95),
        borderColor: x.kind == SampleKind.fail
            ? rangeRed
            : x.kind == SampleKind.ok
            ? Colors.white
            : Colors.transparent,
        borderStrokeWidth: x.kind == SampleKind.heard ? 0 : 1.5,
      ),
  ];
}

/// The small legend (colour = SNR).
class RangeLegend extends StatelessWidget {
  const RangeLegend({super.key});
  @override
  Widget build(BuildContext context) {
    Widget dot(Color c, String t, {Color? ring}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c,
            border: Border.all(color: ring ?? Colors.white, width: 1.5),
          ),
        ),
        const SizedBox(width: 4),
        Text(t, style: const TextStyle(fontSize: 12)),
      ],
    );
    return Wrap(
      key: const Key('rangeLegend'),
      spacing: 12,
      runSpacing: 4,
      children: [
        dot(snrColor(5), 'strong (0 dB+)'),
        dot(snrColor(-7), 'medium'),
        dot(snrColor(-15), 'weak (-15 dB)'),
        dot(noReplyFill, 'no reply', ring: rangeRed),
      ],
    );
  }
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
    this.logger,
    this.homeChoices,
    this.share,
    this.exportDir,
  });
  final RangeTest range;

  /// Range logging on this phone (null = not offered, tests).
  final RangeLogger? logger;

  /// Radios the connected radio knows (for "Home radio").
  final List<({int num, String name})> Function()? homeChoices;

  /// Share a file (CSV / JSON export); false = could not, copy instead.
  final Future<bool> Function(String path, String mime, String title)? share;

  /// Tests: where exports are written.
  final Directory? exportDir;

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

  Future<void> _export(bool csv) async {
    await rt.flush();
    final text = csv ? rt.samplesCsv() : rt.exportJson();
    var shared = false;
    try {
      final dir = widget.exportDir ?? await getTemporaryDirectory();
      await dir.create(recursive: true);
      final stamp = DateTime.now()
          .toIso8601String()
          .substring(0, 19)
          .replaceAll(':', '-');
      final f = File('${dir.path}/range-log-$stamp.${csv ? 'csv' : 'json'}');
      await f.writeAsString(text);
      final share = widget.share;
      if (share != null) {
        shared = await share(
          f.path,
          csv ? 'text/csv' : 'application/json',
          'Stalkie Talkie range log',
        );
      }
    } catch (_) {}
    if (shared) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _say('Could not open the share sheet. Copied the log instead.');
  }

  String _homeName() {
    final n = rt.homeNode;
    for (final c in widget.homeChoices?.call() ?? const []) {
      if (c.num == n) return '${c.name} (${radioNodeLabel(n)})';
    }
    return n == defaultRangeHomeNode
        ? 'Skunk Ape (${radioNodeLabel(n)})'
        : radioNodeLabel(n);
  }

  Future<void> _pickHome() async {
    final choices = [
      (num: defaultRangeHomeNode, name: 'Skunk Ape'),
      for (final c in widget.homeChoices?.call() ?? const [])
        if (c.num != defaultRangeHomeNode) c,
    ];
    final ctl = TextEditingController();
    final n = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Home radio'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in choices)
                ListTile(
                  key: Key('rangeHome-${c.num}'),
                  dense: true,
                  title: Text(c.name),
                  subtitle: Text(radioNodeLabel(c.num)),
                  trailing: c.num == rt.homeNode
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(ctx, c.num),
                ),
              TextField(
                key: const Key('rangeHomeId'),
                controller: ctl,
                decoration: const InputDecoration(
                  labelText: 'Or type a radio id, like !0b4f84fb',
                ),
                onSubmitted: (v) => Navigator.pop(ctx, parseNodeId(v)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('rangeHomeUse'),
            onPressed: () {
              final v = parseNodeId(ctl.text);
              if (v != null) Navigator.pop(ctx, v);
            },
            child: const Text('Use typed id'),
          ),
        ],
      ),
    );
    if (n != null) await rt.setHomeNode(n);
  }

  List<Widget> _loggingSection(BuildContext context) {
    final lg = widget.logger!;
    final plugged = lg.plugged();
    final every = lg.interval.inSeconds;
    final cs = Theme.of(context).colorScheme;
    return [
      SwitchListTile(
        key: const Key('rangeLogging'),
        title: const Text('Range logging'),
        subtitle: Text(
          rt.logging
              ? lg.status
              : 'Off. Turn on to log where your radio hears the home radio '
                    'while you drive.',
        ),
        value: rt.logging,
        onChanged: (v) => rt.setLogging(v),
      ),
      if (rt.logging) ...[
        ListTile(
          key: const Key('rangeHome'),
          leading: const Icon(Icons.home),
          title: const Text('Home radio'),
          subtitle: Text(_homeName()),
          trailing: const Icon(Icons.chevron_right),
          onTap: _pickHome,
        ),
        ListTile(
          title: Text(
            plugged
                ? 'Ping every $every s (plugged in)'
                : 'Ping every ${rt.pingSecs} s (on battery)',
          ),
          subtitle: Slider(
            key: const Key('rangePing'),
            min: 60,
            max: 120,
            divisions: 12,
            label: '${rt.pingSecs} s',
            value: rt.pingSecs.toDouble(),
            onChanged: (v) => rt.setPingSecs(v.round()),
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.amber.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            key: const Key('rangeBatteryNote'),
            'Battery: each ping is a radio transmit (and up to 3 retries when '
            'nobody answers), so your radio and the phone use more power '
            'while this is on, and the phone checks GPS every 10 s. Plugged '
            'in it pings every 30 s; never faster, to spare the shared '
            'public frequency. Turn it off when you are done.',
            style: TextStyle(color: cs.onSurface, fontSize: 13),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            key: const Key('rangeCounts'),
            '${rt.samples.length} points logged: '
            '${rt.samples.where((x) => x.kind == SampleKind.ok).length} '
            'replies, '
            '${rt.samples.where((x) => x.kind == SampleKind.fail).length} '
            'no reply, '
            '${rt.samples.where((x) => x.kind == SampleKind.heard).length} '
            'heard.',
          ),
        ),
      ],
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: RangeLegend(),
      ),
      ListTile(
        key: const Key('rangeExportCsv'),
        leading: const Icon(Icons.table_chart),
        title: const Text('Export log (CSV)'),
        subtitle: const Text('Every logged point: time, place, result, SNR.'),
        enabled: rt.samples.isNotEmpty,
        onTap: rt.samples.isEmpty ? null : () => _export(true),
      ),
      ListTile(
        key: const Key('rangeExportJson'),
        leading: const Icon(Icons.data_object),
        title: const Text('Export log (JSON)'),
        subtitle: const Text('Points and connect / drop markers.'),
        enabled: !rt.isEmpty || rt.samples.isNotEmpty,
        onTap: rt.isEmpty && rt.samples.isEmpty ? null : () => _export(false),
      ),
      ListTile(
        key: const Key('rangeClearPoints'),
        leading: const Icon(Icons.layers_clear),
        title: const Text('Clear logged points'),
        enabled: rt.samples.isNotEmpty,
        onTap: rt.samples.isEmpty
            ? null
            : () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Clear all logged points?'),
                    content: const Text(
                      'Removes the colored points from this device. The '
                      'connect / drop markers stay.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Keep'),
                      ),
                      FilledButton(
                        key: const Key('rangeClearPointsYes'),
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                );
                if (ok == true) await rt.clearSamples();
              },
      ),
      const Divider(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final showPc = widget.pcFile != null || RangeTest.pcRangeFile() != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Range test markers')),
      body: ListenableBuilder(
        listenable: Listenable.merge([rt, ?widget.logger]),
        builder: (context, _) {
          final list = rt.events.reversed.toList();
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (widget.logger != null) ..._loggingSection(context),
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
