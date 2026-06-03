import 'package:flutter/material.dart';

/// Reserves space for the real iOS status bar / Dynamic Island so app content
/// starts below it. The OS draws the real time, signal and battery, so we no
/// longer render faux copies of them.
class IosStatusBar extends StatelessWidget {
  const IosStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    return SizedBox(height: topInset > 0 ? topInset : 24);
  }
}
