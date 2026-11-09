import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart'
    as maps;

import '../lib/shared/widgets/app_google_map.dart';

class _MapPlatform extends maps.MethodChannelGoogleMapsFlutter {
  final initialized = <int>{};
  final cameras = <CameraUpdate>[];
  Completer<void>? gate;
  int inFlight = 0;
  int maximumInFlight = 0;

  Future<void> _move(CameraUpdate update) async {
    cameras.add(update);
    inFlight++;
    if (inFlight > maximumInFlight) maximumInFlight = inFlight;
    await gate?.future;
    inFlight--;
  }

  @override
  Future<void> animateCamera(CameraUpdate update,
          {required int mapId, Duration? duration}) =>
      _move(update);

  @override
  Future<void> moveCamera(CameraUpdate update, {required int mapId}) =>
      _move(update);

  @override
  Future<void> updateGroundOverlays(maps.GroundOverlayUpdates updates,
      {required int mapId}) async {}

  @override
  Widget buildViewWithConfiguration(
      int creationId, ValueChanged<int> onPlatformViewCreated,
      {required maps.MapWidgetConfiguration widgetConfiguration,
      maps.MapConfiguration mapConfiguration = const maps.MapConfiguration(),
      maps.MapObjects mapObjects = const maps.MapObjects()}) {
    if (initialized.add(creationId)) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              MethodChannel('plugins.flutter.io/google_maps_$creationId'),
              (_) async => null);
      scheduleMicrotask(() => onPlatformViewCreated(creationId));
    }
    return const ColoredBox(color: Colors.transparent);
  }
}

void main() {
  late maps.GoogleMapsFlutterPlatform previous;
  late _MapPlatform platform;
  setUp(() {
    previous = maps.GoogleMapsFlutterPlatform.instance;
    platform = _MapPlatform();
    maps.GoogleMapsFlutterPlatform.instance = platform;
  });
  tearDown(() => maps.GoogleMapsFlutterPlatform.instance = previous);

  Widget view(LatLng position,
          {int revision = 0,
          bool enabled = true,
          VoidCallback? onUserInteraction}) =>
      MaterialApp(
        home: TickerMode(
          enabled: enabled,
          child: AppGoogleMap(
            initialTarget: const LatLng(15, 44),
            followTarget: position,
            smoothFollow: true,
            pauseOnUserInteraction: true,
            followRequestId: revision,
            onUserInteraction: onUserInteraction,
            markers: {
              Marker(markerId: const MarkerId('car'), position: position),
            },
          ),
        ),
      );

  testWidgets(
      'pan preserves user camera while GPS updates and slow work drains',
      (tester) async {
    var interactions = 0;
    await tester.pumpWidget(
        view(const LatLng(15, 44), onUserInteraction: () => interactions++));
    await tester.pump();
    final pending = Completer<void>();
    platform.gate = pending;
    await tester.pumpWidget(view(const LatLng(15.001, 44),
        onUserInteraction: () => interactions++));
    expect(platform.cameras, hasLength(1));
    await tester.pumpWidget(view(const LatLng(15.002, 44),
        onUserInteraction: () => interactions++));
    final gesture = await tester.startGesture(const Offset(200, 200));
    await gesture.moveBy(const Offset(60, 20));
    await gesture.up();
    expect(interactions, 1);
    for (var index = 3; index < 103; index++) {
      await tester.pumpWidget(view(LatLng(15 + index / 1000, 44),
          onUserInteraction: () => interactions++));
    }
    expect(platform.cameras, hasLength(1));
    final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
    expect(map.markers.single.position, const LatLng(15.102, 44));
    platform.gate = null;
    pending.complete();
    await tester.pump(const Duration(seconds: 1));
    expect(platform.cameras, hasLength(1),
        reason: 'A pending old GPS target cannot recenter after a gesture.');
    await tester.pumpWidget(view(const LatLng(15.102, 44), revision: 1));
    await tester.pump();
    expect(platform.cameras, hasLength(2),
        reason: 'Explicit recenter works without waiting for a new GPS fix.');
    expect(platform.maximumInFlight, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pinch suspends follow even before either finger moves',
      (tester) async {
    var interactions = 0;
    await tester.pumpWidget(
        view(const LatLng(15, 44), onUserInteraction: () => interactions++));
    await tester.pump();
    final first = await tester.startGesture(const Offset(100, 200), pointer: 1);
    final second =
        await tester.startGesture(const Offset(200, 200), pointer: 2);
    await first.up();
    await second.up();
    expect(interactions, 1);
    await tester.pumpWidget(view(const LatLng(15.01, 44)));
    await tester.pump(const Duration(seconds: 1));
    expect(platform.cameras, isEmpty);
    await tester.pumpWidget(view(const LatLng(15.01, 44), revision: 1));
    expect(platform.cameras, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hidden maps stop camera work and retain manual camera ownership',
      (tester) async {
    await tester.pumpWidget(view(const LatLng(15, 44)));
    await tester.pump();
    await tester.pumpWidget(view(const LatLng(15.01, 44), enabled: false));
    await tester.pump(const Duration(seconds: 1));
    expect(platform.cameras, isEmpty);
    await tester.pumpWidget(view(const LatLng(15.01, 44)));
    await tester.pump();
    expect(platform.cameras, hasLength(1));
    await tester.drag(find.byType(GoogleMap), const Offset(40, 0));
    await tester.pumpWidget(view(const LatLng(15.02, 44), enabled: false));
    await tester.pumpWidget(view(const LatLng(15.03, 44)));
    await tester.pump(const Duration(seconds: 1));
    expect(platform.cameras, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });
}
