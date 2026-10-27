import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Width (logical pixels) from which Talk and the Trip map are shown side
/// by side (v1.9.6): tablets in either orientation and wide desktop
/// windows. Phones, even in landscape, stay below it.
const double kTwoPaneMinWidth = 700;

/// Shortest side from which a phone-sized screen counts as a tablet;
/// landscape phones are wide but short, so they keep the tabs.
const double kTwoPaneMinShortestSide = 560;

bool isTwoPane(double width, [double? height]) =>
    width >= kTwoPaneMinWidth &&
    (height == null || height >= kTwoPaneMinShortestSide || width >= 1000);

/// Width of the Talk pane in the two-pane layout.
double talkPaneWidth(double width) => (width * 0.4).clamp(340.0, 460.0);

/// Talk (people, push-to-talk) on the left, the Trip map on the right
/// (v1.9.6 tablet / desktop layout). The Talk pane keeps a phone-like
/// width so its cards look the same as on a phone; the map gets the rest.
class TwoPaneHome extends StatelessWidget {
  const TwoPaneHome({
    super.key,
    required this.width,
    required this.talk,
    required this.trip,
  });

  final double width;
  final Widget talk;
  final Widget trip;

  @override
  Widget build(BuildContext context) => Row(
    key: const Key('twoPane'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        key: const Key('talkPane'),
        width: talkPaneWidth(width),
        child: SafeArea(right: false, child: talk),
      ),
      const VerticalDivider(width: 1, thickness: 1),
      Expanded(
        key: const Key('tripPane'),
        child: SafeArea(left: false, child: trip),
      ),
    ],
  );
}

/// Space bar push-to-talk (v1.9.6, desktop and tablets with a keyboard):
/// [onTalk] true when Space goes down, false when it comes back up, like
/// holding the big Talk button. Ignored while typing in a text field and
/// while a dialog, sheet or another screen is on top.
class PushToTalkKeys extends StatefulWidget {
  const PushToTalkKeys({super.key, required this.onTalk, required this.child});

  final ValueChanged<bool> onTalk;
  final Widget child;

  @override
  State<PushToTalkKeys> createState() => _PushToTalkKeysState();
}

class _PushToTalkKeysState extends State<PushToTalkKeys> {
  bool _down = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    if (_down) widget.onTalk(false);
    super.dispose();
  }

  bool _typing() {
    final f = FocusManager.instance.primaryFocus?.context;
    if (f == null) return false;
    return f.widget is EditableText ||
        f.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool _onKey(KeyEvent e) {
    if (e.logicalKey != LogicalKeyboardKey.space || !mounted) return false;
    if (e is KeyUpEvent) {
      if (!_down) return false;
      _down = false;
      widget.onTalk(false);
      return true;
    }
    if (e is KeyRepeatEvent) return _down;
    if (e is! KeyDownEvent || _down) return _down;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    if (_typing()) return false;
    _down = true;
    widget.onTalk(true);
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
