import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Bottom sheet that always fits on a small phone and never draws under the
/// status bar or the gesture / 3-button navigation bar (Android 15+ draws
/// apps edge to edge) or the keyboard.
///
/// * Always scroll-controlled with a maximum height of 90 % of the screen
///   (and never taller than the space below the status bar), so a tall
///   sheet is no longer clipped to 9/16 of the screen (v2.0.0 bug: the
///   person sheet lost everything below Ring / Beep).
/// * [scrollable] (default) puts the content in a scroll view, so whatever
///   does not fit scrolls. Pass `false` only when the builder already
///   scrolls by itself (a ListView, DraggableScrollableSheet or its own
///   SingleChildScrollView).
/// * The space below is [sheetBottomInset]: the navigation bar
///   (viewPadding) or the keyboard (viewInsets), whichever is taller. The
///   content never gets the inset twice: it is removed from the
///   MediaQuery the builder sees.
/// * A drag handle is shown ([showDragHandle]).
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool scrollable = true,
  bool showDragHandle = true,
}) {
  final mq = MediaQuery.of(context);
  final maxHeight = math.min(
    mq.size.height * sheetMaxHeightFraction,
    mq.size.height - mq.padding.top,
  );
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: showDragHandle,
    constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: 640),
    builder: (ctx) => AppSheetBody(scrollable: scrollable, builder: builder),
  );
}

/// Sheets are at most this share of the screen height.
const sheetMaxHeightFraction = 0.9;

/// Space the sheet keeps free at its bottom: the navigation bar or the
/// keyboard, whichever is taller (viewPadding and viewInsets overlap, the
/// nav bar sits under the keyboard).
double sheetBottomInset(MediaQueryData mq) =>
    math.max(mq.viewPadding.bottom, mq.viewInsets.bottom);

/// Body of [showAppSheet]; public so tests can pump it directly.
class AppSheetBody extends StatelessWidget {
  const AppSheetBody({
    super.key,
    required this.builder,
    this.scrollable = true,
  });

  final WidgetBuilder builder;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final inset = sheetBottomInset(mq);
    // The builder must not add the nav bar / keyboard space a second time
    // (SafeArea, viewInsets padding).
    final inner = MediaQuery(
      data: mq.copyWith(
        padding: mq.padding.copyWith(bottom: 0),
        viewPadding: mq.viewPadding.copyWith(bottom: 0),
        viewInsets: mq.viewInsets.copyWith(bottom: 0),
      ),
      child: Builder(builder: builder),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: scrollable
          ? SingleChildScrollView(
              primary: false,
              key: const Key('appSheetScroll'),
              child: SizedBox(width: double.infinity, child: inner),
            )
          : inner,
    );
  }
}
