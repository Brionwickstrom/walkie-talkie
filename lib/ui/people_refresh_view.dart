import 'package:flutter/material.dart';

import '../app/people_refresh.dart';

/// Pull-to-refresh around a people list (Talk screen, Who's where;
/// v1.8.5). Pulling down, or tapping the refresh button, asks everyone
/// "who's here?" on every fast path and shows "Found N people" when the
/// answers settle (about 3 s at most). Holding the button also asks over
/// the LoRa radio (slow, at most once per 2 min); after a normal refresh
/// the toast offers "Also ask over radio (slow)" while a radio is
/// connected.
class PeopleRefreshScope extends StatefulWidget {
  const PeopleRefreshScope({
    super.key,
    required this.refresh,
    required this.builder,
    this.radioAvailable,
  });

  /// Runs one refresh (null = no pull-to-refresh, the list just shows).
  final Future<RefreshResult> Function({required bool radio})? refresh;

  /// Whether to offer the radio (a LoRa radio is connected).
  final bool Function()? radioAvailable;

  /// Builds the scrollable list. [button] is the small refresh icon for
  /// the list header (null without [refresh]). The list must be able to
  /// scroll when short ([AlwaysScrollableScrollPhysics]) so it can be
  /// pulled.
  final Widget Function(BuildContext context, Widget? button) builder;

  @override
  State<PeopleRefreshScope> createState() => PeopleRefreshScopeState();
}

class PeopleRefreshScopeState extends State<PeopleRefreshScope> {
  final _indicator = GlobalKey<RefreshIndicatorState>();
  bool _radioNext = false;
  bool _busy = false;

  /// Start a refresh with the spinner, as if pulled ([radio]: also ask
  /// over the radio).
  Future<void> show({bool radio = false}) async {
    if (radio) _radioNext = true;
    final s = _indicator.currentState;
    if (s == null) return;
    await s.show();
  }

  Future<void> _onRefresh() async {
    final run = widget.refresh;
    if (run == null) return;
    final radio = _radioNext;
    _radioNext = false;
    final messenger = ScaffoldMessenger.maybeOf(context);
    _busy = true;
    if (mounted) setState(() {});
    RefreshResult r;
    try {
      r = await run(radio: radio);
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
    if (messenger == null) return;
    final offerRadio =
        !radio && (widget.radioAvailable?.call() ?? false) && mounted;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('people-refresh-result'),
          content: Text(r.message),
          duration: Duration(seconds: offerRadio ? 6 : 3),
          action: offerRadio
              ? SnackBarAction(
                  key: const Key('people-refresh-radio'),
                  label: 'Also ask over radio (slow)',
                  onPressed: () {
                    if (mounted) show(radio: true);
                  },
                )
              : null,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.refresh == null) return widget.builder(context, null);
    final button = Tooltip(
      message: 'Refresh (hold to also ask over radio)',
      child: GestureDetector(
        onLongPress: _busy ? null : () => show(radio: true),
        child: IconButton(
          key: const Key('people-refresh'),
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.refresh),
          onPressed: _busy ? null : () => show(),
        ),
      ),
    );
    return RefreshIndicator(
      key: _indicator,
      onRefresh: _onRefresh,
      child: widget.builder(context, button),
    );
  }
}
