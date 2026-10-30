import 'wx_alert.dart';

/// How one alert is announced on the phone.
class WxNotice {
  const WxNotice({
    required this.extreme,
    required this.sound,
    required this.bypass,
  });

  /// Tornado Warning / Extreme: the loud channel, full-screen when it
  /// sounds.
  final bool extreme;

  /// May make a sound now. False in mute / quiet hours (the notification is
  /// still high priority on the lock screen, just silent).
  final bool sound;

  /// May break through Do Not Disturb: only an extreme alert with the
  /// "sound in quiet hours and Do Not Disturb" switch on.
  final bool bypass;
}

/// The rule from the owner: quiet hours only silence sound, and Do Not
/// Disturb still applies, unless the extreme switch (default off) is on and
/// the alert is Extreme or a Tornado Warning. An UNCONFIRMED copy (from a
/// device we do not trust on an Open channel, v2.5.2) is announced like any
/// other warning (the warning channel) and never as extreme.
WxNotice planWxNotice(
  WxAlert a, {
  required bool silenced,
  required bool extremeSwitch,
}) {
  final bypass = a.alarms && extremeSwitch;
  return WxNotice(
    extreme: a.alarms,
    sound: !silenced || bypass,
    bypass: bypass,
  );
}

/// "Until 3:00 PM" in the phone's local time.
String wxUntil(WxAlert a, {DateTime? now}) {
  final t = a.expiresAt.toLocal();
  return 'Until ${wxClock(t, now: now)}';
}

/// "3:00 PM", or "Sat 3:00 PM" when not today.
String wxClock(DateTime t, {DateTime? now}) {
  final n = (now ?? DateTime.now());
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  final ap = t.hour < 12 ? 'AM' : 'PM';
  final same = t.year == n.year && t.month == n.month && t.day == n.day;
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return same ? '$h:$m $ap' : '${days[t.weekday - 1]} $h:$m $ap';
}

/// Notification text: [short] one line, [big] the expanded text.
({String title, String short, String big}) wxNoticeText(
  WxAlert a, {
  DateTime? now,
}) {
  final until = wxUntil(a, now: now);
  final area = a.areaDesc.isEmpty ? '' : ' · ${a.areaDesc}';
  final head = a.headline.isEmpty ? '' : WxAlert.unwrap(a.headline);
  final todo = a.instruction.isEmpty ? '' : WxAlert.unwrap(a.instruction);
  String cut(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n - 1)}…';
  final trust = a.trust == WxTrust.unconfirmed ? a.trustLine : null;
  return (
    title: a.event,
    short: cut('${trust == null ? '' : '$trust · '}$until$area', 120),
    big: cut(
      [
        ?trust,
        if (head.isNotEmpty) head else '$until$area',
        if (todo.isNotEmpty) todo,
      ].join('\n'),
      500,
    ),
  );
}
