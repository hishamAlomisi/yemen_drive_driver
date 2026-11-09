import 'package:geolocator/geolocator.dart';

/// Motion between received GPS fixes, with no prediction after the last fix.
abstract final class DriverMapMotion {
  static Duration duration(Duration gap) =>
      Duration(milliseconds: gap.inMilliseconds.clamp(120, 1000));

  static double heading(Position? previous, Position next, double fallback) {
    if (next.heading.isFinite &&
        next.heading >= 0 &&
        next.speed.isFinite &&
        next.speed > 0.7) {
      return next.heading % 360;
    }
    if (previous != null &&
        Geolocator.distanceBetween(previous.latitude, previous.longitude,
                next.latitude, next.longitude) >=
            5) {
      return (Geolocator.bearingBetween(previous.latitude, previous.longitude,
                  next.latitude, next.longitude) +
              360) %
          360;
    }
    return fallback;
  }
}
