import 'dart:async';

import 'package:flutter/widgets.dart';

/// Runs [onLeave] when this screen goes away (back button, swipe, pop),
/// e.g. to stop playback started from it.
class StopOnLeave extends StatefulWidget {
  const StopOnLeave({super.key, required this.onLeave, required this.child});
  final VoidCallback onLeave;
  final Widget child;

  @override
  State<StopOnLeave> createState() => _StopOnLeaveState();
}

class _StopOnLeaveState extends State<StopOnLeave> {
  @override
  void dispose() {
    // After this frame: listeners may not rebuild while the tree is locked.
    scheduleMicrotask(widget.onLeave);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
