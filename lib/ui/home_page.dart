import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/config.dart';
import '../app/passcodes.dart';
import '../app/walkie_controller.dart';
import '../core/link_policy.dart';
import '../core/peer.dart';
import '../core/transport.dart';
import '../platform/platform_caps.dart';
import '../update/update_ui.dart';
import '../chat/chat_store.dart';
import '../trip/geo.dart';
import 'chat_page.dart';
import 'friends_page.dart';
import 'history_page.dart';
import 'home_view.dart';
import 'link_sheet.dart';
import 'inbox_page.dart';
import 'quiet_widgets.dart';
import 'radio_settings.dart';
import 'sheets.dart';
import 'trip_page.dart';
import 'trip_widgets.dart';
import 'whos_where_page.dart';
import '../app/power_plan.dart';
import '../app/link_settings.dart';
import '../app/invite.dart';
import '../app/setup.dart';
import 'adaptive_layout.dart';
import 'battery_help.dart';
import 'channels_sheet.dart';
import 'connection_test_page.dart';
import 'invite_sheet.dart';
import 'setup_wizard.dart';

import 'dart:io' show Platform;

import '../trip/sos.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});
  final WalkieController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  WalkieController get c => widget.controller;
  Timer? _tick;
  final UpdateFlow _updates = UpdateFlow();
  String _version = '';
  final List<StreamSubscription<dynamic>> _subs = [];
  AppLifecycleListener? _lifecycle;
  DateTime _lastUpdateCheck = DateTime.now();

  /// 0 = Talk, 1 = Trip.
  int _tab = 0;

  /// Trip map is full screen: no app bar or tab bar (status / navigation
  /// bar insets are kept by the SafeArea).
  bool _tripFull = false;
  bool _hideBarsFor(bool wide) => _tripFull && (wide || _tab == 1);

  final GlobalKey<TripPageState> _tripKey = GlobalKey();
  final Set<String> _sosShown = {};
  bool _tripWired = false;

  @override
  void initState() {
    super.initState();
    if (c.setupEntry == SetupEntry.wizard && !c.started) {
      // First run (v1.8.7): the setup wizard asks for permissions and
      // starts the links itself.
      c.permissionsBySetup = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await openSetupWizard(context, c);
        c.permissionsBySetup = false;
        await c.start();
        _wireTrip();
      });
    } else {
      c.start().then((_) async {
        _wireTrip();
        await _maybeAskBattery();
        await _maybeSetupPrompt();
      });
    }
    _updates.updater
        .currentVersionLabel()
        .then((v) {
          if (mounted) setState(() => _version = v);
        })
        .catchError((_) {});
    // Quiet update check shortly after start (after permission prompts).
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) _updates.check(context);
    });
    // The app can now live for days in the background: check again when
    // it comes back to the screen after a while.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (DateTime.now().difference(_lastUpdateCheck) >
            const Duration(hours: 6)) {
          _lastUpdateCheck = DateTime.now();
          if (mounted) _updates.check(context);
        }
      },
    );
    _subs.add(
      c.notices.listen((msg) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(msg)));
      }),
    );
    _subs.add(
      c.friendRequestStream.listen((r) async {
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('${r.name} wants to be friends'),
            content: const Text(
              'Friends can talk and chat with each other privately from '
              'anywhere, on any channel (end-to-end encrypted).',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Decline'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Accept'),
              ),
            ],
          ),
        );
        if (ok == null || !mounted) return;
        if (!c.friendRequests.contains(r)) return;
        await answerFriendRequest(context, c, r, ok);
      }),
    );
    _subs.add(
      c.uiRequests.listen((r) {
        if (!mounted) return;
        if (r == 'inbox') _openInbox(context);
        if (r.startsWith('join:')) {
          // Invite link opened (v1.8.7): confirm before anything changes.
          final inv = Invite.parse(r.substring(5));
          if (inv != null) {
            confirmInvite(context, c, inv);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('That invite link is not valid.')),
            );
          }
        }
        if (r.startsWith('import:')) {
          // A trail / map file opened with the app: Trip tab, import it.
          final j = jsonDecode(r.substring(7)) as Map;
          setState(() => _tab = 1);
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _tripKey.currentState?.importShared(
              '${j['path']}',
              '${j['name']}',
            ),
          );
        }
        if (r == 'sos') {
          final open = c.trip?.sos.unanswered ?? const [];
          if (open.isNotEmpty) _showSos(open.first, force: true);
        }
        // Private talk / message notification from a friend: open their
        // chat so the reply is private, never the channel.
        if (r.startsWith('friend:')) {
          final id = int.tryParse(r.substring(7));
          if (id != null) {
            _openChat(context, friendConversation(id));
          }
        }
      }),
    );
    // Refresh link ages / debug lines / recording timer.
    var ticks = 0;
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      // v2.0.0: nothing to redraw (or poll) with the app in the background.
      final life = WidgetsBinding.instance.lifecycleState;
      if (!mounted || (life != null && life != AppLifecycleState.resumed)) {
        return;
      }
      setState(() {});
      // The volume buttons change the media stream; re-check every 2 s.
      if (ticks++ % 4 == 0) c.refreshMediaVolume();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _lifecycle?.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  void _wireTrip() {
    final t = c.trip;
    if (t == null || _tripWired || !mounted) return;
    _tripWired = true;
    _subs.add(t.sosAlerts.listen((a) => _showSos(a)));
  }

  /// Full-screen alert for someone's SOS (once per alert unless [force]).
  void _showSos(IncomingSos a, {bool force = false}) {
    if (!mounted) return;
    if (!force && !_sosShown.add(a.key)) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => SosAlertPage(
          controller: c,
          alert: a,
          onShowMap: () {
            setState(() => _tab = 1);
            final p = a.pos;
            if (p != null) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _tripKey.currentState?.focusOn(p),
              );
            }
          },
        ),
      ),
    );
  }

  int get _tripAlerts =>
      (c.trip?.sos.unanswered.length ?? 0) + (c.trip?.lost.lost.length ?? 0);

  /// Updated from an older version (v1.8.7): offer the setup check once,
  /// never force the wizard.
  Future<void> _maybeSetupPrompt() async {
    if (!mounted || c.setupEntry != SetupEntry.prompt) return;
    await c.markSetupPromptShown();
    if (!mounted) return;
    final pick = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('setup-prompt'),
        title: const Text('Run setup check?'),
        content: const Text(
          'New in this version: a quick check of permissions, mobile data, '
          'battery settings and every connection, with a fix button for '
          'anything that is off. Find it later in Settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'test'),
            child: const Text('Connection test'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'setup'),
            child: const Text('Run setup check'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (pick == 'setup') await openSetupWizard(context, c);
    if (pick == 'test' && mounted) await openConnectionTest(context, c);
  }

  /// One-time friendly explanation before Android's battery prompt.
  Future<void> _maybeAskBattery() async {
    if (!mounted || !c.bridge.supported) return;
    if (!c.settings.stayReachable || c.settings.batteryPromptShown) return;
    if (await c.bridge.ignoringBatteryOptimizations()) return;
    if (!mounted) return;
    await c.markBatteryPromptShown();
    if (!mounted) return;
    await showBatteryHelp(context, c);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final mq = MediaQuery.of(context);
        final pttSize = (mq.size.height * 0.17).clamp(104.0, 160.0);
        // v1.9.6: tablets and the desktop window get Talk and the Trip map
        // side by side; phones keep the two tabs.
        final wide = isTwoPane(mq.size.width, mq.size.height);
        if (wide) _wireTrip();
        final hideBars = _hideBarsFor(wide);
        final trip = TripPage(
          key: _tripKey,
          controller: c,
          onFullScreen: (v) => setState(() => _tripFull = v),
        );
        final talk = HomeBody(
          banners: [
            if (c.quietStatus != null)
              QuietBanner(
                text: c.quietStatus!,
                muted: c.quiet.muted,
                onUnmute: c.unmute,
                onSettings: () => _openSettings(context),
              ),
            if (c.playingSomething)
              Card(
                margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                color: Theme.of(context).colorScheme.tertiaryContainer,
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.volume_up),
                  title: Text(
                    c.playingTake != null
                        ? 'Replaying ${c.playingTake!.name}'
                              '${c.playingAll ? ' (all missed)' : ''}'
                        : c.playingKey != null
                        ? 'Playing a voice message'
                        : 'Playing live talk',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: FilledButton.icon(
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                    onPressed: c.stopAllAudio,
                  ),
                ),
              ),
            for (final r in List.of(c.activeRings))
              _RingBanner(
                urgent: r.urgent,
                name: c.nameOf(r.from),
                channel: c.labelFor(r.channel),
                onAnswer: () => c.answerRing(r),
                onDismiss: () => c.dismissRing(r),
              ),
          ],
          links: [
            for (final t in c.transports)
              if (t.kind != TransportKind.lora || c.radioPaired)
                (t.kind, t.status),
          ],
          internet: c.internetStatus,
          bestPath: c.connectionSummary.text,
          showDetails: c.settings.showDiagnostics,
          onToggleDetails: c.setShowDiagnostics,
          details: _detailLines(),
          channelLabel: c.channelName == null
              ? 'CH ${c.channel}'
              : '${c.channelTitle} (CH ${c.channel})',
          isPrivate: c.isPrivate,
          listenerWarning: c.hiddenListeners > 0
              ? UnknownListenerCard(
                  count: c.hiddenListeners,
                  isPrivate: c.isPrivate,
                  onTap: () => explainUnknownListener(
                    context,
                    isPrivate: c.isPrivate,
                    count: c.hiddenListeners,
                    isAdmin: c.isAdmin,
                  ),
                )
              : null,
          me: PersonView(
            id: c.nodeId,
            name: c.name,
            me: true,
            talking: c.transmitting,
          ),
          people: _people(),
          onRing: (p) => c.ring(toPeer: p.id),
          onBeep: (p) => c.ring(toPeer: p.id, beep: true),
          onMessage: (p) => _openRecordSheet(context, p.id, p.name),
          onVolume: (p) => _openPersonSheet(context, p),
          onRefresh: ({required bool radio}) => c.refreshPeople(radio: radio),
          radioAvailable: () => c.radioConnected,
          onLinkTap: (k) => _openLinkSheet(context, k),
          mobileDataHint: c.mobileDataHint,
          cell: c.cellStatus,
          cellLevel: c.cellInfo?.level,
          onCellTap: () => _openCellSheet(context),
          alone: c.aloneReason,
          onAloneFix: c.openPhoneSettings,
          onConnectionTest: () => openConnectionTest(context, c),
          notice: c.announcementMode && !c.isAdmin
              ? Card(
                  margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.campaign),
                    title: Text(
                      'Announcement mode: only '
                      '${c.adminId == null ? 'the admin' : c.nameOf(c.adminId!)}'
                      ' can talk here.',
                    ),
                  ),
                )
              : (c.mediaVolume ?? 1) < 0.3
              ? Card(
                  margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        const Icon(Icons.volume_down),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Media volume is low '
                            '(${((c.mediaVolume ?? 0) * 100).round()}%). '
                            'Press volume up to hear others clearly.',
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : null,
          onEditMe: () => _openSettings(context),
          error: c.error,
          queued: c.outgoing.isNotEmpty || c.waitingForAnyone.isNotEmpty
              ? TextButton.icon(
                  icon: const Icon(Icons.schedule_send, size: 18),
                  label: Text(
                    _queuedLabel(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: () => _openInbox(context),
                )
              : null,
          recent: c.takes.isEmpty
              ? null
              : RecentStrip(
                  takes: [for (final t in c.takes.take(8)) takeView(c, t)],
                  unheard: c.unheardTakes,
                  onPlay: (v) {
                    final t = c.takes.where((x) => x.id == v.id);
                    if (t.isNotEmpty) c.playTake(t.first);
                  },
                  onPlayMissed: c.playAllMissed,
                  onOpenHistory: () => _openHistory(context),
                ),
          headerAction: WhosWhereButton(
            count: c.whosWhereElsewhereCount,
            onPressed: () => _openWhosWhere(context),
          ),
          actions: ChannelActions(
            onRingAll: () => c.ring(),
            onBeepAll: () => c.ring(beep: true),
            record: _RecordButton(controller: c),
            mute: MuteButton(
              muted: c.quiet.muted,
              onMute: c.mute,
              onUnmute: c.unmute,
            ),
          ),
          ptt: _mainTalk(context, pttSize),
        );
        return PushToTalkKeys(
          onTalk: _pttKey,
          child: Scaffold(
            appBar: hideBars
                ? null
                : AppBar(
                    titleSpacing: 8,
                    title: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ChannelPicker(
                          channel: c.channel,
                          isPrivate: c.isPrivate,
                          emoji: c.channelName?.emoji ?? '',
                          onTap: () => showChannelsSheet(context, c),
                        ),
                        IconButton(
                          tooltip: c.isPrivate
                              ? 'Private channel (tap for passcode)'
                              : 'Make this channel private',
                          icon: c.switchingChannel
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  c.isPrivate ? Icons.lock : Icons.lock_open,
                                ),
                          onPressed: () => showPrivacySheet(context, c),
                        ),
                      ],
                    ),
                    actions: [
                      IconButton(
                        tooltip: 'Chat on this channel',
                        icon: Badge(
                          isLabelVisible: c.unreadChannelChat > 0,
                          label: Text('${c.unreadChannelChat}'),
                          child: const Icon(Icons.chat_bubble_outline),
                        ),
                        onPressed: () => _openChat(context, c.channelChat),
                      ),
                      IconButton(
                        tooltip: 'Friends',
                        icon: Badge(
                          isLabelVisible:
                              c.unreadFriendChats + c.friendRequests.length > 0,
                          label: Text(
                            '${c.unreadFriendChats + c.friendRequests.length}',
                          ),
                          child: Icon(
                            c.onlineFriends > 0
                                ? Icons.people
                                : Icons.people_outline,
                          ),
                        ),
                        onPressed: () => _openFriends(context),
                      ),
                      IconButton(
                        tooltip: 'Voice messages',
                        icon: Badge(
                          isLabelVisible: c.unplayedMessages > 0,
                          label: Text('${c.unplayedMessages}'),
                          child: const Icon(Icons.voicemail),
                        ),
                        onPressed: () => _openInbox(context),
                      ),
                      IconButton(
                        tooltip: 'Settings',
                        icon: const Icon(Icons.settings),
                        onPressed: () => _openSettings(context),
                      ),
                    ],
                  ),
            bottomNavigationBar: hideBars || wide
                ? null
                : NavigationBar(
                    key: const Key('mainTabs'),
                    height: 60,
                    labelBehavior:
                        NavigationDestinationLabelBehavior.alwaysShow,
                    selectedIndex: _tab,
                    onDestinationSelected: (i) {
                      _wireTrip();
                      setState(() {
                        _tab = i;
                        _tripFull = false;
                      });
                    },
                    destinations: [
                      const NavigationDestination(
                        icon: Icon(Icons.record_voice_over_outlined),
                        selectedIcon: Icon(Icons.record_voice_over),
                        label: 'Talk',
                      ),
                      NavigationDestination(
                        icon: Badge(
                          isLabelVisible: _tripAlerts > 0,
                          label: Text('$_tripAlerts'),
                          child: Icon(
                            c.trip?.sos.active != null
                                ? Icons.sos
                                : Icons.terrain_outlined,
                            color: c.trip?.sos.active != null
                                ? Colors.red
                                : null,
                          ),
                        ),
                        selectedIcon: const Icon(Icons.terrain),
                        label: 'Trip',
                      ),
                    ],
                  ),
            body: wide
                ? _tripFull
                      ? SafeArea(child: trip)
                      : TwoPaneHome(
                          width: mq.size.width,
                          talk: talk,
                          trip: trip,
                        )
                : _tab == 1
                ? SafeArea(child: trip)
                : SafeArea(child: talk),
          ),
        );
      },
    );
  }

  void _pttKey(bool down) {
    final reply = c.replyTarget;
    if (reply != null) {
      c.talkToFriend(reply, down);
      return;
    }
    if (c.settings.toggleTalk) {
      if (down) c.toggleTalk();
      return;
    }
    c.mainTalk(down);
  }

  void _openWhosWhere(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WhosWherePage(
          controller: c,
          onOpenPerson: (ctx, id) {
            final p = _people().where((v) => v.id == id && !v.left);
            if (p.isNotEmpty) _openPersonSheet(ctx, p.first);
          },
        ),
      ),
    );
  }

  /// People for the list: on our channel first (talking first, then by
  /// name), then other channels, then the ones that just left.
  List<PersonView> _people() {
    final now = DateTime.now();
    final out = <PersonView>[];
    for (final p in c.peers) {
      final links = c.manager.liveLinksOf(p, now)
        ..sort((a, b) => b.defaultPriority.compareTo(a.defaultPriority));
      DateTime? last;
      for (final t in [...p.lastSeen.values, ?p.meshSeen, ?p.gatewaySeen]) {
        if (last == null || t.isAfter(last)) last = t;
      }
      final mine = p.channel == c.scope;
      out.add(
        PersonView(
          id: p.id,
          name: p.displayName,
          talking: p.talking && mine,
          links: links,
          active: p.activeLink,
          lastHeard: last == null ? null : now.difference(last),
          elsewhere: mine ? null : 'On ${c.labelFor(p.channel)}',
          ringStatus: c.ringStatusText(p.id),
          volume: c.volumeOf(p.id),
          hops: p.meshHops,
          debug: peerDebugLine(p, now, path: c.pathOf(p)),
          distance: _distanceTo(p.id),
          arrowDeg: _arrowTo(p.id),
          battery: c.batteryOf(p.id),
          path: c.pathOf(p),
          gateway: p.viaGateway,
        ),
      );
    }
    out.sort((a, b) {
      if (a.here != b.here) return a.here ? -1 : 1;
      if (a.talking != b.talking) return a.talking ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    for (final l in c.recentlyLeft) {
      out.add(
        PersonView(
          id: l.id,
          name: l.name,
          left: true,
          lastHeard: now.difference(l.at),
        ),
      );
    }
    return out;
  }

  String? _distanceTo(int id) {
    final t = c.trip;
    final me = t?.myFix?.pos;
    final them = t?.people[id]?.pos;
    if (t == null || me == null || them == null) return null;
    return formatDistanceBearing(me, them, imperial: t.settings.imperial);
  }

  double? _arrowTo(int id) {
    final t = c.trip;
    final me = t?.myFix?.pos;
    final them = t?.people[id]?.pos;
    if (t == null || me == null || them == null) return null;
    return arrowAngleDeg(bearingDeg(me, them), t.heading);
  }

  /// Long-press on a person: their volume (0-200 %), beep, ring, message.
  Future<void> _openPersonSheet(BuildContext context, PersonView p) async {
    await showAppSheet<void>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: c,
        builder: (ctx, _) {
          final v = c.volumeOf(p.id);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Avatar(id: p.id, name: p.name),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          p.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(ctx).textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('Volume for this person: ${(v * 100).round()}%'),
                  Row(
                    children: [
                      const Icon(Icons.volume_mute),
                      Expanded(
                        child: Slider(
                          value: v,
                          max: 2,
                          divisions: 20,
                          label: '${(v * 100).round()}%',
                          onChanged: (x) => c.setPeerVolume(p.id, x),
                        ),
                      ),
                      const Icon(Icons.volume_up),
                    ],
                  ),
                  TextButton(
                    onPressed: () => c.setPeerVolume(p.id, 1),
                    child: const Text('Reset to 100%'),
                  ),
                  SwitchListTile(
                    key: const Key('alwaysAllow'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Always allow rings'),
                    subtitle: const Text(
                      'Their rings still sound while you are muted or in '
                      'quiet hours (with "Let urgent rings through" on).',
                    ),
                    value: c.alwaysAllowed(p.id),
                    onChanged: (v) => c.setAlwaysAllow(p.id, v),
                  ),
                  const Divider(),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.ring_volume),
                        label: const Text('Ring'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          c.ring(toPeer: p.id);
                        },
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.notifications_active),
                        label: const Text('Beep'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          c.ring(toPeer: p.id, beep: true);
                        },
                      ),
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(ctx)
                              .colorScheme
                              .errorContainer,
                          foregroundColor: Theme.of(ctx)
                              .colorScheme
                              .onErrorContainer,
                        ),
                        icon: const Icon(Icons.campaign),
                        label: const Text('Urgent ring'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          c.ring(toPeer: p.id, urgent: true);
                        },
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.mic),
                        label: const Text('Voice message'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _openRecordSheet(context, p.id, p.name);
                        },
                      ),
                    ],
                  ),
                  const Divider(),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (c.isFriend(p.id))
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.forum),
                          label: const Text('Private chat'),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _openChat(context, friendConversation(p.id));
                          },
                        )
                      else if (!p.left)
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.person_add),
                          label: const Text('Add friend'),
                          onPressed: () {
                            Navigator.pop(ctx);
                            c.requestFriend(p.id);
                          },
                        ),
                      OutlinedButton.icon(
                        icon: Icon(
                          c.isMuted(p.id) ? Icons.volume_up : Icons.volume_off,
                        ),
                        label: Text(c.isMuted(p.id) ? 'Unmute' : 'Mute'),
                        onPressed: () => c.setMuted(p.id, !c.isMuted(p.id)),
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.block),
                        label: const Text('Block'),
                        onPressed: () async {
                          final ok = await _confirm(
                            ctx,
                            'Block ${p.name}?',
                            'You will not hear, see or receive anything from '
                                'them (talk, rings, messages, chats). Undo in '
                                'Settings > Blocked.',
                            'Block',
                          );
                          if (ok && ctx.mounted) {
                            Navigator.pop(ctx);
                            await c.setBlocked(p.id, true, name: p.name);
                          }
                        },
                      ),
                      if (c.isAdmin && p.here)
                        OutlinedButton.icon(
                          icon: const Icon(Icons.person_remove),
                          label: const Text('Remove from channel'),
                          onPressed: () async {
                            final ok = await _confirm(
                              ctx,
                              'Remove ${p.name} from ${c.channelTitle}?',
                              'Everyone else is moved to a new passcode '
                                  'automatically. ${p.name} keeps the old one '
                                  'and can no longer hear or see the channel. '
                                  'Phones out of range right now need the '
                                  'new passcode from you.',
                              'Remove',
                            );
                            if (ok && ctx.mounted) {
                              Navigator.pop(ctx);
                              await c.kick(p.id);
                            }
                          },
                        ),
                    ],
                  ),
                  if (c.isMuted(p.id))
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'Muted: their live talk is not played here.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  List<String> _detailLines() => [
    for (final t in c.transports)
      '${_short(t.kind)}: ${t.status.name}'
          '${t.debugInfo != null ? ' · ${t.debugInfo}' : ''}'
          '${t.status != TransportStatus.running && t.statusDetail != null ? ' · ${t.statusDetail}' : ''}',
    if (c.playbackDropped > 0)
      'speaker: dropped ${c.playbackDropped} late frames',
    if (c.playbackLog.events.isNotEmpty) 'Playback log (newest first):',
    for (final e in c.playbackLog.events.take(30)) e.line,
  ];

  String _queuedLabel() {
    final sending = c.outgoing.where((o) => o.sending).length;
    final radio = c.outgoing.where((o) => o.sending && o.viaRadio).length;
    final waiting =
        c.outgoing.where((o) => !o.sending).length + c.waitingForAnyone.length;
    final parts = [
      if (sending > 0)
        'sending $sending${radio > 0 ? ' ($radio over the radio)' : ''}',
      if (waiting > 0) '$waiting waiting for someone to come in range',
    ];
    return 'Voice messages: ${parts.join(', ')}';
  }

  void _openHistory(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => HistoryPage(controller: c)));
  }

  /// Big talk button + private reply banner (v1.5.4).
  Widget _mainTalk(BuildContext context, double pttSize) {
    final reply = c.replyTarget;
    final name = reply == null ? null : c.friendName(reply);
    final n = c.channelListeners;
    final replyTalking =
        reply != null && c.transmitting && c.privateTalkTo == reply;
    return MainTalkArea(
      replyName: name,
      replyTransmitting: replyTalking,
      onReplyTalk: reply == null ? null : (d) => c.talkToFriend(reply, d),
      onChannelInstead: c.talkToChannelInstead,
      onOpenChat: reply == null
          ? null
          : () => _openChat(context, friendConversation(reply)),
      button: PttButton(
        transmitting: reply != null
            ? replyTalking
            : c.transmitting && c.privateTalkTo == null,
        busy: c.talkingPeer != null || (c.announcementMode && !c.isAdmin),
        onChanged: c.mainTalk,
        size: reply != null ? pttSize * 0.85 : pttSize,
        toggle: c.settings.toggleTalk,
        onTap: c.toggleTalk,
        private: reply != null,
        caption: name != null
            ? 'Reply privately to $name'
            : 'Talk to CH ${c.channel} ($n ${n == 1 ? 'person' : 'people'})'
                  '${PlatformCaps.desktop ? ' · or hold Space' : ''}',
      ),
    );
  }

  void _openChat(BuildContext context, String conv) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(controller: c, conv: conv),
      ),
    );
  }

  void _openFriends(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => FriendsPage(controller: c)));
  }

  void _openInbox(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => InboxPage(controller: c)));
  }

  Future<void> _openRecordSheet(
    BuildContext context,
    int peerId,
    String name,
  ) async {
    await showAppSheet<void>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: c,
        builder: (ctx, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Voice message to $name',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              const Text(
                'Hold the button and talk (up to 30 s). Let go to send. '
                'If they are out of range it is delivered when they come back.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              _RecordButton(controller: c, toPeer: peerId, big: true),
            ],
          ),
        ),
      ),
    );
    if (c.recording != null) await c.stopRecording();
  }

  /// Connection icon tapped (v1.8.5): its status and a button to the
  /// matching phone settings (or the in-app radio pairing).
  Future<void> _openLinkSheet(BuildContext context, TransportKind k) async {
    Transport? t;
    for (final x in c.transports) {
      if (x.kind == k) t = x;
    }
    final status = k == TransportKind.internet
        ? c.internetStatus.status
        : t?.status ?? TransportStatus.stopped;
    final btMissing = k == TransportKind.ble
        ? await c.bluetoothPermissionMissing()
        : false;
    if (k == TransportKind.internet) await c.refreshPhoneNet();
    if (!context.mounted) return;
    final info = describeLink(
      k,
      status,
      detail: t?.statusDetail,
      netKind: c.phoneNet,
      permissionMissing: btMissing,
      offlineSaver: c.settings.offlineSaver,
      ios: Platform.isIOS,
      relayInUse: k == TransportKind.internet ? c.relayInUse : null,
      directCount: k == TransportKind.internet ? c.directPeers.length : 0,
    );
    await showAppSheet<void>(
      context: context,
      builder: (ctx) => LinkSheetView(
        kind: k,
        info: info,
        onTest: () {
          Navigator.pop(ctx);
          openConnectionTest(context, c);
        },
        onAction: () async {
          Navigator.pop(ctx);
          if (info.setting == PhoneSetting.radioPairing) {
            await showAppSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (ctx2) => SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: RadioSettings(controller: c),
                ),
              ),
            );
            return;
          }
          if (info.permissionMissing) {
            final ok = await c.requestBluetoothPermission();
            if (ok) await c.openPhoneSettings(PhoneSetting.bluetooth);
            return;
          }
          await c.openPhoneSettings(info.setting);
        },
      ),
    );
  }

  /// Cell / mobile data icon tapped (v1.8.6).
  Future<void> _openCellSheet(BuildContext context) async {
    await c.refreshPhoneNet();
    if (!context.mounted) return;
    final state = c.cellStatus;
    final info = describeCell(state, c.cellInfo, ios: Platform.isIOS);
    await showAppSheet<void>(
      context: context,
      builder: (ctx) => LinkSheetView(
        kind: TransportKind.internet,
        icon: cellIcon(state, c.cellInfo?.level),
        info: info,
        onTest: () {
          Navigator.pop(ctx);
          openConnectionTest(context, c);
        },
        onAction: () {
          Navigator.pop(ctx);
          c.openPhoneSettings(info.setting);
        },
        onSecond: info.secondSetting == null
            ? null
            : () {
                Navigator.pop(ctx);
                c.openPhoneSettings(info.secondSetting!);
              },
      ),
    );
  }

  Future<void> _openSettings(BuildContext context) async {
    final nameCtl = TextEditingController(text: c.settings.customName ?? '');
    final relayCtl = TextEditingController(text: c.relayOverride);
    await showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => ListenableBuilder(
        listenable: c,
        builder: (ctx, _) => Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Your call sign',
                            style: Theme.of(ctx).textTheme.labelMedium,
                          ),
                          Text(
                            c.settings.defaultName,
                            style: Theme.of(ctx).textTheme.titleLarge,
                          ),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Pick another call sign',
                      icon: const Icon(Icons.casino),
                      onPressed: c.rerollCallSign,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: nameCtl,
                  decoration: InputDecoration(
                    labelText: 'Custom name (optional)',
                    hintText: c.settings.defaultName,
                    helperText: 'Leave empty to use your call sign',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: relayCtl,
                  decoration: InputDecoration(
                    labelText: 'Internet relays (optional)',
                    hintText: AppConfig.relayUrl,
                    helperText:
                        'Empty = default. Several: comma separated, first '
                        'is preferred. "off" = no internet relay.',
                    helperMaxLines: 3,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    c.setName(nameCtl.text);
                    c.setRelayUrl(relayCtl.text);
                    Navigator.pop(ctx);
                  },
                  child: const Text('Save'),
                ),
                if (c.bridge.supported) ...[
                  const Divider(height: 32),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Stay reachable when app is closed'),
                    subtitle: const Text(
                      'Rings, voice messages and live talk still come '
                      'through. Shows a small "listening" notification. '
                      'Uses more battery.',
                    ),
                    value: c.settings.stayReachable,
                    onChanged: (v) async {
                      await c.setStayReachable(v);
                      if (v && ctx.mounted) await showBatteryHelp(ctx, c);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Start listening after phone restarts'),
                    value: c.settings.startOnBoot,
                    onChanged: c.settings.stayReachable
                        ? (v) => c.setStartOnBoot(v)
                        : null,
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.battery_saver),
                        label: const Text('Battery settings'),
                        onPressed: () => showBatteryHelp(ctx, c),
                      ),
                      _FullScreenButton(controller: c),
                    ],
                  ),
                ],
                const Divider(height: 32),
                SwitchListTile(
                  key: const Key('showInWhosWhere'),
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.travel_explore),
                  title: const Text("Show me in Who's where"),
                  subtitle: const Text(
                    'Phones on other channels (nearby or online) can see '
                    'your name and which public channel you are on. On a '
                    'private channel they only see "Private" and your call '
                    'sign, never the channel number or name.',
                  ),
                  value: c.settings.showInWhosWhere,
                  onChanged: c.setShowInWhosWhere,
                ),
                SwitchListTile(
                  key: const Key('readReceipts'),
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.done_all),
                  title: const Text('Send read receipts'),
                  subtitle: const Text(
                    'People see "seen" once you open their chat or play '
                    'their voice message. Tiny, works over the radio too.',
                  ),
                  value: c.settings.readReceipts,
                  onChanged: c.setReadReceipts,
                ),
                const Divider(height: 32),
                _SectionTitle('Off-grid (no internet)'),
                SwitchListTile(
                  key: const Key('offlineSaver'),
                  contentPadding: EdgeInsets.zero,
                  secondary: Icon(
                    Icons.energy_savings_leaf,
                    color: c.settings.offlineSaver ? Colors.green : null,
                  ),
                  title: const Text('Offline power save'),
                  subtitle: Text(
                    'For when you know there is no internet (a hike) and '
                    'want the longest battery life. Turns off the internet '
                    'relay, network searching and live location, slows '
                    'Bluetooth, GPS and check-ins, and makes the app dark '
                    'and dim. Talk, receive, phone relay, the radio, SOS and '
                    'quick messages keep working. '
                    '${const PowerPlan(offline: true).estimate}',
                  ),
                  value: c.settings.offlineSaver,
                  onChanged: c.setOfflineSaver,
                ),
                SwitchListTile(
                  key: const Key('relayForOthers'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Relay for others'),
                  subtitle: const Text(
                    'With no internet or cell signal, pass talk on to phones '
                    'that are out of range of each other (up to 4 hops, '
                    'like on a hike). Phones close together still talk '
                    'directly with no delay. Private talk stays encrypted: '
                    'relays cannot hear it. Uses some extra battery while '
                    'relaying.',
                  ),
                  value: c.settings.relayForOthers,
                  onChanged: c.setRelayForOthers,
                ),
                if (c.wifiDirectSupported)
                  SwitchListTile(
                    key: const Key('wifiDirect'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Wi-Fi Direct'),
                    subtitle: const Text(
                      'Link straight to nearby Android phones over Wi-Fi '
                      'when there is no shared network: about 2-3x the '
                      'range of Bluetooth. Android may ask the other phone '
                      'to accept the connection. iPhones use Bluetooth or '
                      'a hotspot instead.',
                    ),
                    value: c.settings.wifiDirect,
                    onChanged: c.setWifiDirect,
                  ),
                SwitchListTile(
                  key: const Key('baseCamp'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Base camp mode'),
                  subtitle: Text(
                    'Leave this phone at camp (plugged in) as a fixed relay. '
                    'It holds Trip messages (SOS, quick messages, pins, '
                    'check-ins) for anyone out of range and delivers them '
                    'when they come back, for up to 6 hours. Works through '
                    'the paired LoRa radio too.'
                    '${c.trip != null && c.settings.trip.baseCamp ? ' Holding ${c.trip!.store.items.length} now.' : ''}',
                  ),
                  value: c.settings.trip.baseCamp,
                  onChanged: c.setBaseCamp,
                ),
                const Divider(height: 32),
                _SectionTitle('Long-range radio (Meshtastic)'),
                RadioSettings(controller: c),
                const Divider(height: 32),
                _SectionTitle('Mute & quiet hours'),
                QuietSettings(controller: c),
                const Divider(height: 32),
                _SectionTitle('Talk button'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Tap to talk (toggle)'),
                  subtitle: const Text(
                    'Tap once to start talking, tap again to stop. Stops by '
                    'itself after 2 minutes. Off = hold to talk.',
                  ),
                  value: c.settings.toggleTalk,
                  onChanged: c.setToggleTalk,
                ),
                if (c.bridge.supported) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Use volume-down as talk button'),
                    subtitle: const Text(
                      'Hold volume-down to talk while the app is open. While '
                      'this is on, volume-down does not lower the volume.',
                    ),
                    value: c.settings.volumeKeyPtt,
                    onChanged: c.setVolumeKeyPtt,
                  ),
                  if (c.settings.volumeKeyPtt)
                    _PermissionButton(
                      key: const Key('a11y'),
                      check: c.bridge.accessibilityEnabled,
                      onLabel: 'Works with other apps open too',
                      offLabel: 'Also with other apps open...',
                      icon: Icons.accessibility_new,
                      onTap: () => _explainAccessibility(ctx, c),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Headset button talks'),
                    subtitle: const Text(
                      'Bluetooth or wired headset play/pause button: press '
                      'to start, press again to stop (or hold while you '
                      'talk). Works while the app is listening. If you then '
                      'play music, the button goes back to the music app '
                      'until you reopen Walkie Talkie.',
                    ),
                    value: c.settings.headsetPtt,
                    onChanged: c.setHeadsetPtt,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Talk button on the notification'),
                    subtitle: const Text(
                      'Adds "Talk" to the listening notification, also on '
                      'the lock screen. Tap again to stop.',
                    ),
                    value: c.settings.notificationTalk,
                    onChanged: c.settings.stayReachable
                        ? c.setNotificationTalk
                        : null,
                  ),
                  const Divider(height: 32),
                  _SectionTitle('Urgent rings'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Urgent rings sound in silent mode'),
                    subtitle: const Text(
                      'Someone can send an urgent ring (long-press a person). '
                      'It rings for up to 1 minute at alarm volume with a '
                      'strong vibration, even when the phone is on silent.',
                    ),
                    value: c.settings.urgentLoud,
                    onChanged: c.setUrgentLoud,
                  ),
                  if (c.settings.urgentLoud)
                    _PermissionButton(
                      key: const Key('dnd'),
                      check: c.bridge.dndAccess,
                      onLabel: 'Also rings through Do Not Disturb',
                      offLabel: 'Also ring through Do Not Disturb...',
                      icon: Icons.do_not_disturb_off,
                      onTap: () => _explainDnd(ctx, c),
                    ),
                ],
                if (c.settings.blocked.isNotEmpty) ...[
                  const Divider(height: 32),
                  _SectionTitle('Blocked'),
                  for (final e in c.settings.blocked.entries)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.block),
                      title: Text(e.value),
                      trailing: TextButton(
                        onPressed: () => c.setBlocked(e.key, false),
                        child: const Text('Unblock'),
                      ),
                    ),
                ],
                const Divider(height: 32),
                _SectionTitle('Privacy'),
                SwitchListTile(
                  key: const Key('settings-join-private'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Alert when someone joins a private channel',
                  ),
                  subtitle: const Text('A short tone and their name.'),
                  value: c.settings.joinAlertPrivate,
                  onChanged: (v) => c.setJoinAlert(private: v),
                ),
                SwitchListTile(
                  key: const Key('settings-join-open'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Alert when someone joins an open channel'),
                  value: c.settings.joinAlertPublic,
                  onChanged: (v) => c.setJoinAlert(public: v),
                ),
                const Divider(height: 32),
                _SectionTitle('Messages'),
                SwitchListTile(
                  key: const Key('autoPlay'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Auto-play incoming talk'),
                  subtitle: const Text(
                    'Off: nothing plays by itself. Talk is saved in Missed '
                    'and voice messages wait in Voice messages until you '
                    'tap Play.',
                  ),
                  value: c.settings.autoPlay,
                  onChanged: c.setAutoPlay,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.receipt_long),
                  title: const Text('Playback log'),
                  subtitle: const Text(
                    'What played, from whom, and why. Screenshot this if '
                    'something keeps repeating.',
                  ),
                  onTap: () => showPlaybackLog(ctx, c),
                ),
                ListTile(
                  key: const Key('clearAll'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.delete_sweep),
                  title: const Text('Clear all messages and queues'),
                  subtitle: const Text(
                    'Stops all audio, deletes voice messages and missed '
                    'talk, and cancels everything waiting to be sent.',
                  ),
                  onTap: () async {
                    final ok = await showDialog<bool>(
                      context: ctx,
                      builder: (d) => AlertDialog(
                        title: const Text('Clear all messages and queues?'),
                        content: const Text(
                          'Voice messages, missed talk and anything still '
                          'waiting to be sent are deleted. Chats are kept.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(d, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(d, true),
                            child: const Text('Clear'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) await c.clearAllMessages();
                  },
                ),
                const Divider(height: 32),
                _SectionTitle('Battery'),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('Normal'),
                      icon: Icon(Icons.bolt),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('Saver'),
                      icon: Icon(Icons.battery_saver),
                    ),
                  ],
                  selected: {c.settings.powerSaver},
                  onSelectionChanged: (v) => c.setPowerSaver(v.first),
                ),
                const SizedBox(height: 6),
                Text(
                  c.settings.powerSaver
                      ? 'Saver: roughly 20-35% less battery while waiting '
                            '(estimate, varies by phone). Talk and rings still '
                            'come through, sometimes about a second later. '
                            'New phones nearby can take up to 30 s to show up '
                            'over Bluetooth.'
                      : 'Normal: fastest. Phones show up within a few '
                            'seconds. Switch to Saver to use less battery.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                // v1.9.8: how hard the app works to keep the fastest link.
                Text(
                  'Connection speed',
                  style: Theme.of(ctx).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                SegmentedButton<ConnectionSpeed>(
                  key: const Key('connection-speed'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: ConnectionSpeed.maxSpeed,
                      label: Text(
                        'Max speed (more battery)',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    ButtonSegment(
                      value: ConnectionSpeed.balanced,
                      label: Text('Balanced', textAlign: TextAlign.center),
                    ),
                  ],
                  selected: {c.settings.connectionSpeed},
                  onSelectionChanged: (v) => c.setConnectionSpeed(v.first),
                ),
                const SizedBox(height: 6),
                Text(
                  LinkPolicy.estimate(c.settings.connectionSpeed),
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                ListTile(
                  key: const Key('phone-settings-tile'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.app_settings_alt),
                  title: const Text(
                    'Phone settings for this app (mobile data, battery)',
                  ),
                  subtitle: const Text(
                    'Opens App info. Under Mobile data, turn on Mobile data '
                    'and Background data (and Unrestricted data if Data '
                    'saver is on) so the internet relay works without '
                    'Wi-Fi. Battery: set it to Unrestricted.',
                  ),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => c.openPhoneSettings(PhoneSetting.appInfo),
                ),
                const Divider(height: 32),
                _SectionTitle('Help & setup'),
                ListTile(
                  key: const Key('settings-setup'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.checklist),
                  title: const Text('Setup wizard'),
                  subtitle: const Text(
                    'Call sign, permissions, mobile data, battery, channel, '
                    'radio.',
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    openSetupWizard(context, c);
                  },
                ),
                ListTile(
                  key: const Key('settings-conn-test'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.network_check),
                  title: const Text('Connection test'),
                  subtitle: const Text(
                    'Checks Wi-Fi, Bluetooth, mobile data, internet, the '
                    'relay, the radio, permissions and battery, with fixes.',
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    openConnectionTest(context, c);
                  },
                ),
                ListTile(
                  key: const Key('settings-invite'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.qr_code),
                  title: const Text('Invite (QR code / link)'),
                  subtitle: const Text(
                    'Share this channel and / or a friend add.',
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    showInviteSheet(context, c);
                  },
                ),
                ListTile(
                  key: const Key('settings-join'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.qr_code_scanner),
                  title: const Text('Join with a code'),
                  subtitle: const Text('Scan or paste an invite.'),
                  onTap: () {
                    Navigator.pop(ctx);
                    scanInvite(context, c);
                  },
                ),
                ListTile(
                  key: const Key('settings-debug-log'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.bug_report_outlined),
                  title: const Text('Send debug log'),
                  subtitle: const Text(
                    'Connection log for troubleshooting (passcodes, keys and '
                    'precise locations removed).',
                  ),
                  onTap: () => sendDebugLog(ctx, c),
                ),
                const Divider(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _version.isEmpty ? 'Version' : 'Version $_version',
                        style: Theme.of(ctx).textTheme.bodyMedium,
                      ),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.system_update),
                      label: const Text('Check for updates'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _lastUpdateCheck = DateTime.now();
                        _updates.check(context, userInitiated: true);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Explains why Android / the phone maker's battery saving must leave the
/// app alone, with maker-specific steps (v1.8.7).
Future<void> showBatteryHelp(BuildContext context, WalkieController c) =>
    showBatteryGuide(context, c);

class _FullScreenButton extends StatefulWidget {
  const _FullScreenButton({required this.controller});
  final WalkieController controller;

  @override
  State<_FullScreenButton> createState() => _FullScreenButtonState();
}

class _FullScreenButtonState extends State<_FullScreenButton> {
  bool _allowed = true;

  @override
  void initState() {
    super.initState();
    widget.controller.bridge.canUseFullScreen().then((v) {
      if (mounted) setState(() => _allowed = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_allowed) return const SizedBox.shrink();
    return OutlinedButton.icon(
      icon: const Icon(Icons.fullscreen),
      label: const Text('Allow full-screen rings'),
      onPressed: widget.controller.bridge.openFullScreenSettings,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
}

/// Shows whether an optional Android permission is on; tap to explain and
/// open the system screen. Re-checks when the app comes back.
class _PermissionButton extends StatefulWidget {
  const _PermissionButton({
    super.key,
    required this.check,
    required this.onLabel,
    required this.offLabel,
    required this.icon,
    required this.onTap,
  });
  final Future<bool> Function() check;
  final String onLabel;
  final String offLabel;
  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_PermissionButton> createState() => _PermissionButtonState();
}

class _PermissionButtonState extends State<_PermissionButton> {
  bool? _on;
  AppLifecycleListener? _l;

  @override
  void initState() {
    super.initState();
    _refresh();
    _l = AppLifecycleListener(onResume: _refresh);
  }

  Future<void> _refresh() async {
    final v = await widget.check();
    if (mounted) setState(() => _on = v);
  }

  @override
  void dispose() {
    _l?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_on == true) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(widget.onLabel)),
          ],
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: OutlinedButton.icon(
          icon: Icon(widget.icon),
          label: Text(widget.offLabel),
          onPressed: widget.onTap,
        ),
      ),
    );
  }
}

Future<void> _explainAccessibility(
  BuildContext context,
  WalkieController c,
) => _explain(
  context,
  c,
  title: 'Volume-down with other apps open',
  body:
      'To use volume-down as the talk button while another app is open, '
      'Android needs you to turn on "Walkie Talkie volume-down talk button" '
      'under Accessibility (it may be under "Installed apps" or '
      '"Downloaded apps").\n\n'
      'It only watches the volume-down key while this setting is on and '
      'cannot read your screen.\n\n'
      'If Android says the setting is restricted: open Settings > Apps > '
      'Walkie Talkie, tap the ⋮ menu (top right) > "Allow restricted '
      'settings", then try again.\n\n'
      'With the screen off, Android does not pass the volume keys to apps, '
      'so use the headset button or the notification there.',
  action: 'Open Accessibility',
  onAction: (c) => c.bridge.openAccessibilitySettings(),
);

Future<void> _explainDnd(BuildContext context, WalkieController c) => _explain(
  context,
  c,
  title: 'Ring through Do Not Disturb?',
  body:
      'Urgent rings already play at alarm volume in silent mode. If you '
      'also want them to ring while Do Not Disturb is on, allow Walkie '
      'Talkie under "Do Not Disturb access" on the next screen.\n\n'
      'Only urgent rings use this: Do Not Disturb is switched off while '
      'one rings (up to 1 minute) and switched back on right after. '
      'Normal rings, beeps and talk stay quiet.',
  action: 'Allow',
  onAction: (c) => c.bridge.openDndSettings(),
);

Future<void> _explain(
  BuildContext context,
  WalkieController c, {
  required String title,
  required String body,
  required String action,
  required Future<void> Function(WalkieController c) onAction,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(body)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            onAction(c);
          },
          child: Text(action),
        ),
      ],
    ),
  );
}

class _RingBanner extends StatelessWidget {
  const _RingBanner({
    this.urgent = false,
    required this.name,
    required this.channel,
    required this.onAnswer,
    required this.onDismiss,
  });
  final bool urgent;
  final String name;
  final String channel;
  final VoidCallback onAnswer;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: urgent ? cs.errorContainer : cs.tertiaryContainer,
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.ring_volume, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${urgent ? 'URGENT: ' : ''}$name is ringing you ($channel)',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
            FilledButton(onPressed: onAnswer, child: const Text('Answer')),
          ],
        ),
      ),
    );
  }
}

/// Hold to record a voice message, release to send.
class _RecordButton extends StatelessWidget {
  const _RecordButton({
    required this.controller,
    this.toPeer,
    this.big = false,
  });
  final WalkieController controller;
  final int? toPeer;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final rec = c.recording;
    final mine = rec != null && rec.toPeer == toPeer;
    final secs = mine
        ? DateTime.now().difference(rec.startedAt).inSeconds.clamp(0, 30)
        : 0;
    final cs = Theme.of(context).colorScheme;
    final label = mine
        ? 'Recording 0:${secs.toString().padLeft(2, '0')} / 0:30'
        : big
        ? 'Hold to record'
        : 'Hold: message';
    return Listener(
      onPointerDown: (_) => c.startRecording(toPeer: toPeer),
      onPointerUp: (_) => c.stopRecording(),
      onPointerCancel: (_) => c.stopRecording(cancel: true),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: big ? 32 : 12,
          vertical: big ? 22 : 8,
        ),
        decoration: BoxDecoration(
          color: mine ? Colors.red : cs.secondaryContainer,
          borderRadius: BorderRadius.circular(40),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              mine ? Icons.fiber_manual_record : Icons.keyboard_voice,
              color: mine ? Colors.white : cs.onSecondaryContainer,
              size: big ? 32 : 20,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: mine ? Colors.white : cs.onSecondaryContainer,
                fontWeight: FontWeight.w600,
                fontSize: big ? 18 : 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The channel button in the top bar (v1.9.4): "CH 3 ▾", opens the
/// channel picker with its Private channels section.
class _ChannelPicker extends StatelessWidget {
  const _ChannelPicker({
    required this.channel,
    required this.isPrivate,
    required this.emoji,
    required this.onTap,
  });
  final int channel;
  final bool isPrivate;
  final String emoji;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('channel-picker'),
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${emoji.isEmpty ? '' : '$emoji '}CH $channel'),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String text,
  String action,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

String _short(TransportKind k) => switch (k) {
  TransportKind.lan => 'WiFi',
  TransportKind.wifiDirect => 'WiFiD',
  TransportKind.ble => 'BLE',
  TransportKind.internet => 'Net',
  TransportKind.lora => 'LoRa',
};

/// e.g. "via WiFi | WiFi 0.3s 8ms | BLE 0.7s 41ms"
String peerDebugLine(Peer p, DateTime now, {String? path}) {
  final parts = <String>[
    'via ${p.activeLink == null ? (p.meshHops != null
                  ? 'mesh ${p.meshHops} hops'
                  : p.viaGateway != null
                  ? 'gateway ${p.viaGateway}'
                  : 'none') : _short(p.activeLink!)}'
        '${path != null ? ' ($path)' : ''}',
  ];
  for (final k in TransportKind.values) {
    final seen = p.lastSeen[k];
    if (seen == null) continue;
    final age = now.difference(seen).inMilliseconds / 1000;
    final rtt = p.rtt[k];
    parts.add(
      '${_short(k)} ${age.toStringAsFixed(1)}s'
      '${rtt != null ? ' ${rtt.inMilliseconds}ms' : ''}',
    );
  }
  return parts.join(' | ');
}

/// Make the current channel private / public, and show its passcode with a
/// QR code so others can join.
Future<void> showPrivacySheet(BuildContext context, WalkieController c) async {
  final ch = c.channel;
  final passCtl = TextEditingController();
  final nameCtl = TextEditingController(text: c.channelName?.name ?? '');
  final emojiCtl = TextEditingController(text: c.channelName?.emoji ?? '');
  var show = false;
  var makeAdmin = true;
  String? err;
  await showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final pass = c.settings.passcodeFor(ch);
        final theme = Theme.of(ctx);
        final key = c.manager.channelKey;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(pass != null ? Icons.lock : Icons.lock_open),
                    const SizedBox(width: 8),
                    Text(
                      pass != null ? 'CH $ch is private' : 'CH $ch is public',
                      style: theme.textTheme.titleLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    SizedBox(
                      width: 64,
                      child: TextField(
                        controller: emojiCtl,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(labelText: 'Emoji'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: nameCtl,
                        maxLength: 30,
                        decoration: const InputDecoration(
                          labelText: 'Channel name (optional)',
                          counterText: '',
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Save name',
                      icon: const Icon(Icons.check),
                      onPressed: () async {
                        await c.setChannelName(nameCtl.text, emojiCtl.text);
                        if (ctx.mounted) FocusScope.of(ctx).unfocus();
                        setSheet(() {});
                      },
                    ),
                  ],
                ),
                Text(
                  'Everyone on this channel sees the name (phones with app '
                  '1.5 or newer).',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (pass == null) ...[
                  const Text(
                    'Set a passcode to make this channel private. Everything '
                    'on it (talk, rings, beeps, voice messages, who is here) '
                    'is encrypted. Only phones on the same channel number '
                    'with the same passcode can hear or see each other.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passCtl,
                    obscureText: !show,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: makeAdmin
                          ? 'New passcode (at least ${Passcodes.minNew} '
                                'characters)'
                          : 'Passcode they gave you',
                      errorText: err,
                      suffixIcon: IconButton(
                        icon: Icon(
                          show ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () => setSheet(() => show = !show),
                      ),
                    ),
                  ),
                  if (makeAdmin)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const Key('privacy-generate'),
                        icon: const Icon(Icons.casino_outlined),
                        label: const Text('Make one for me'),
                        onPressed: () => setSheet(() {
                          passCtl.text = Passcodes.generate();
                          show = true;
                          err = null;
                        }),
                      ),
                    ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: makeAdmin,
                    onChanged: (v) => setSheet(() => makeAdmin = v ?? false),
                    title: const Text("I'm setting up this channel"),
                    subtitle: const Text(
                      'You become its admin: you can remove people and '
                      'turn on announcement mode. Untick when joining '
                      "someone else's channel.",
                    ),
                  ),
                  const SizedBox(height: 4),
                  FilledButton.icon(
                    icon: const Icon(Icons.lock),
                    label: const Text('Make private'),
                    onPressed: () async {
                      final p = passCtl.text.trim();
                      // v1.9.4: a new channel needs a strong passcode;
                      // joining someone's channel takes theirs as it is.
                      final problem = makeAdmin
                          ? Passcodes.problemForNew(p)
                          : Passcodes.problemForJoin(p);
                      if (problem != null) {
                        setSheet(() => err = problem);
                        return;
                      }
                      await c.setChannelPrivacy(ch, p, makeAdmin: makeAdmin);
                      setSheet(() => err = null);
                    },
                  ),
                ] else ...[
                  const Text(
                    'To join: on the other phone pick the same channel '
                    'number, tap the lock and type this passcode.',
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(8),
                      child: QrImageView(
                        data:
                            'Walkie Talkie private channel\nCH $ch\nPasscode: $pass',
                        size: 180,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    show ? pass : '\u2022' * pass.length,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  if (key != null && key.channel == ch)
                    Text(
                      'Check code ${key.fingerprint} (same on every phone '
                      'with the right passcode)',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        icon: Icon(
                          show ? Icons.visibility_off : Icons.visibility,
                        ),
                        label: Text(show ? 'Hide' : 'Show'),
                        onPressed: () => setSheet(() => show = !show),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy'),
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(
                              text:
                                  'Walkie Talkie private channel: CH $ch, '
                                  'passcode: $pass',
                            ),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Copied')),
                          );
                        },
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  Row(
                    children: [
                      const Icon(Icons.admin_panel_settings, size: 20),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          c.isAdmin
                              ? 'You are the admin of this channel'
                              : c.adminId != null
                              ? 'Admin: ${c.nameOf(c.adminId!)}'
                              : 'No admin yet',
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (c.adminId == null)
                        TextButton(
                          onPressed: () async {
                            await c.claimAdmin();
                            setSheet(() {});
                          },
                          child: const Text('Become admin'),
                        ),
                    ],
                  ),
                  SwitchListTile(
                    key: const Key('join-alert-private'),
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.notifications_active_outlined),
                    title: const Text('Alert when someone joins'),
                    subtitle: const Text(
                      'A short tone and a note with their name (all private '
                      'channels).',
                    ),
                    value: c.settings.joinAlertPrivate,
                    onChanged: (v) async {
                      await c.setJoinAlert(private: v);
                      setSheet(() {});
                    },
                  ),
                  if (c.isAdmin) ...[
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Announcement mode'),
                      subtitle: const Text(
                        'Only you can talk; everyone else listens.',
                      ),
                      value: c.announcementMode,
                      onChanged: (v) async {
                        await c.setAnnouncementMode(v);
                        setSheet(() {});
                      },
                    ),
                    Text(
                      'To remove someone: long-press them on the main '
                      'screen > Remove from channel.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ] else if (c.announcementMode)
                    const Text(
                      'Announcement mode is on: only the admin talks.',
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const Key('privacy-invite'),
                    icon: const Icon(Icons.qr_code),
                    label: const Text('Invite with QR / link'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      showInviteSheet(context, c);
                    },
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Make public again'),
                    onPressed: () async {
                      await c.setChannelPrivacy(ch, null);
                      setSheet(() {});
                    },
                  ),
                ],
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// Full playback log in a dialog (screenshot-friendly).
Future<void> showPlaybackLog(
  BuildContext context,
  WalkieController c,
) => showDialog<void>(
  context: context,
  builder: (d) => AlertDialog(
    title: const Text('Playback log'),
    content: SizedBox(
      width: double.maxFinite,
      child: c.playbackLog.events.isEmpty
          ? const Text('Nothing played yet since the app started.')
          : SingleChildScrollView(
              child: SelectableText(
                c.playbackLog.text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(d), child: const Text('Close')),
    ],
  ),
);
