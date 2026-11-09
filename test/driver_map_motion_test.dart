import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import '../lib/features/driver/models/driver_map_motion.dart';

Position fix(double longitude, {double heading = -1, double speed = -1}) =>
    Position(
        latitude: 15,
        longitude: longitude,
        timestamp: DateTime.utc(2026, 11, 6),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: heading,
        headingAccuracy: 1,
        speed: speed,
        speedAccuracy: 1);

void main() {
  test('frequent GPS fixes catch up before the next sample without a long lag',
      () {
    expect(DriverMapMotion.duration(const Duration(milliseconds: 200)),
        const Duration(milliseconds: 200));
    expect(DriverMapMotion.duration(const Duration(seconds: 3)),
        const Duration(seconds: 1));
  });

  test('valid moving GPS heading controls the car, including crossing north',
      () {
    expect(
        DriverMapMotion.heading(
            fix(44), fix(44.001, heading: 370, speed: 4), 180),
        10);
  });

  test('movement supplies bearing when a GPS provider omits its heading', () {
    expect(DriverMapMotion.heading(fix(44), fix(44.001), 0), closeTo(90, .001));
  });

  test('stationary coordinate noise retains the last reliable bearing', () {
    expect(
        DriverMapMotion.heading(
            fix(44), fix(44.00001, heading: 270, speed: 0), 35),
        35);
  });
}
