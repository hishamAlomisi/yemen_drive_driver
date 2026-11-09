import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../lib/features/driver/models/driving_route_progress.dart';

void main() {
  const route = [LatLng(15, 44), LatLng(15, 44.001), LatLng(15.001, 44.001)];

  test('approaching a corner retains the corner instead of cutting across it',
      () {
    final progress =
        DrivingRouteProgress.from(route, const LatLng(15, 44.0008));
    expect(progress.points, hasLength(3));
    expect(progress.points[1], route[1]);
    expect(progress.points.last, route.last);
    expect(progress.points.first.latitude, closeTo(15, .0000001));
    expect(progress.points.first.longitude, closeTo(44.0008, .0000001));
  });

  test('after turning only the already travelled segments are removed', () {
    final progress =
        DrivingRouteProgress.from(route, const LatLng(15.0003, 44.001));
    expect(progress.points, hasLength(2));
    expect(progress.points.first.latitude, closeTo(15.0003, .0000001));
    expect(progress.points.last, route.last);
  });

  test('off-route GPS never draws an invented road to the known route', () {
    final progress =
        DrivingRouteProgress.from(route, const LatLng(15.002, 44.003));
    expect(progress.offRouteMeters, greaterThan(75));
    expect(progress.points, route);
  });

  test('repeated route points and arrival keep finite road coordinates', () {
    final progress = DrivingRouteProgress.from(
      [route.first, route.first, route.last, route.last],
      route.last,
    );
    expect(progress.offRouteMeters, closeTo(0, .001));
    expect(
        progress.points
            .every((p) => p.latitude.isFinite && p.longitude.isFinite),
        isTrue);
    expect(progress.points.last, route.last);
  });
}
