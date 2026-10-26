import 'package:flutter/material.dart';

/// Bottom sheet that never draws under the status bar or the gesture /
/// 3-button navigation bar (Android 15+ draws apps edge to edge).
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: isScrollControlled,
  useSafeArea: true,
  builder: (ctx) => SafeArea(top: false, child: builder(ctx)),
);
