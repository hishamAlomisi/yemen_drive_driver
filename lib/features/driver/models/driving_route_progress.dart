import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// The remaining road geometry, projected onto a segment rather than a vertex.
/// GPS stays independent; it must not create a shortcut through the next bend.
class DrivingRouteProgress {
  const DrivingRouteProgress({
    required this.points,
    required this.offRouteMeters,
  });

  factory DrivingRouteProgress.from(List<LatLng> route, LatLng position) {
    if (route.length < 2) {
      return DrivingRouteProgress(points: route, offRouteMeters: 0);
    }
    var closestDistance = double.infinity;
    var closestSegment = 0;
    var projection = route.first;
    final scale = math.cos(position.latitude * math.pi / 180);
    double longitudeDelta(double from, double to) =>
        (to - from + 540) % 360 - 180;
    for (var index = 0; index < route.length - 1; index++) {
      final from = route[index];
      final to = route[index + 1];
      final dx = longitudeDelta(from.longitude, to.longitude) * scale;
      final dy = to.latitude - from.latitude;
      final px = longitudeDelta(from.longitude, position.longitude) * scale;
      final py = position.latitude - from.latitude;
      final squaredLength = dx * dx + dy * dy;
      final fraction = squaredLength == 0
          ? 0.0
          : ((px * dx + py * dy) / squaredLength).clamp(0.0, 1.0);
      final candidate = LatLng(
        from.latitude + dy * fraction,
        (from.longitude +
                    longitudeDelta(from.longitude, to.longitude) * fraction +
                    540) %
                360 -
            180,
      );
      final distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        candidate.latitude,
        candidate.longitude,
      );
      if (distance < closestDistance) {
        closestDistance = distance;
        closestSegment = index;
        projection = candidate;
      }
    }
    return DrivingRouteProgress(
      // While rerouting, keep only the known road instead of drawing a line
      // from an off-road GPS point across buildings to the existing route.
      points: closestDistance > 75
          ? route
          : [projection, ...route.skip(closestSegment + 1)],
      offRouteMeters: closestDistance,
    );
  }

  final List<LatLng> points;
  final double offRouteMeters;
}
