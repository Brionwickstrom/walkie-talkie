import 'package:flutter/material.dart';

/// Small grey speed under a marker name. No box, smaller than the name.
class SpeedCaption extends StatelessWidget {
  const SpeedCaption(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 9,
        height: 1.15,
        color: Color(0xFF757575),
        fontWeight: FontWeight.w500,
      ),
    );
  }
}
