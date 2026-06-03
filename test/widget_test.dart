import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cardiogram/main.dart';

void main() {
  testWidgets('Home screen renders the headline', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const CardiogramApp());
    await tester.pump();

    expect(find.text('Cardiogram connected.'), findsOneWidget);
    expect(find.text('My History'), findsOneWidget);
  });

  testWidgets('My History opens the history screen', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const CardiogramApp());
    await tester.pump();

    await tester.tap(find.text('My History'));
    await tester.pumpAndSettle();

    expect(find.text('My History'), findsWidgets);
    expect(find.text('avg BPM'), findsWidgets);
  });
}
