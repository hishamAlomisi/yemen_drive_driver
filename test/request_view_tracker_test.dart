import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/features/driver/widgets/request_view_tracker.dart';

void main() {
  testWidgets(
      'only visible requests count as views and scrolling does not duplicate them',
      (tester) async {
    var reports = 0;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListView(children: [
      const SizedBox(height: 1000),
      RequestViewTracker(
          report: () async {
            reports++;
          },
          child: const SizedBox(height: 200)),
      const SizedBox(height: 500),
    ]))));
    await tester.pump();
    expect(reports, 0);
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(reports, 1);
    await tester.drag(find.byType(ListView), const Offset(0, -50));
    await tester.pumpAndSettle();
    expect(reports, 1);
  });

  testWidgets(
      'a background request is reported after returning to the foreground',
      (tester) async {
    var reports = 0;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListView(children: [
      RequestViewTracker(
          report: () async {
            reports++;
          },
          child: const SizedBox(height: 200)),
    ]))));
    await tester.pump();
    expect(reports, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(reports, 1);
  });
}
