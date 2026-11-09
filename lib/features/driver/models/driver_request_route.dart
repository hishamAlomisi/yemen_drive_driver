import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../repositories/route_repository.dart';

LatLng? requestCoordinates(Object? latitude, Object? longitude) {
  final lat = double.tryParse('$latitude');
  final lng = double.tryParse('$longitude');
  if (lat == null ||
      lng == null ||
      !lat.isFinite ||
      !lng.isFinite ||
      lat.abs() > 90 ||
      lng.abs() > 180) return null;
  return LatLng(lat, lng);
}

LatLng? currentRequestOrigin(Position? position, {DateTime? now}) {
  if (position == null ||
      !position.accuracy.isFinite ||
      position.accuracy <= 0 ||
      position.accuracy > 75) return null;
  final age =
      (now ?? DateTime.now()).toUtc().difference(position.timestamp.toUtc());
  if (age > const Duration(seconds: 30) || age < const Duration(seconds: -5))
    return null;
  return requestCoordinates(position.latitude, position.longitude);
}

String requestDistanceText(int meters) =>
    meters < 1000 ? '$meters م' : '${(meters / 1000).toStringAsFixed(1)} كم';

/// Shared by the request card and its preview. Rebuilds reuse pending and
/// completed reads; failures are retried only after an explicit retry.
class DriverRequestRouteCache {
  DriverRequestRouteCache(this._repository);
  final RouteRepository Function() _repository;
  final _entries = <String, Future<DrivingRoute>>{};
  final _pending = <String>{};

  Future<DrivingRoute> route(LatLng origin, LatLng destination,
      {bool retry = false}) {
    final key = '${origin.latitude},${origin.longitude}:'
        '${destination.latitude},${destination.longitude}';
    if (retry && !_pending.contains(key)) _entries.remove(key);
    return _entries.putIfAbsent(key, () {
      while (_entries.length >= 64) {
        final completed = _entries.keys.where((key) => !_pending.contains(key));
        if (completed.isEmpty) break;
        _entries.remove(completed.first);
      }
      _pending.add(key);
      return Future.sync(() => _repository().getDrivingRoute(
          origin: origin,
          destination: destination)).whenComplete(() => _pending.remove(key));
    });
  }
}
