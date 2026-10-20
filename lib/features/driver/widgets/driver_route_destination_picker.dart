import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_models.dart';
import '../../../shared/models/ride_route_change_snapshot.dart';
import '../../../shared/widgets/ride_route_destination_picker.dart';

Future<RideRouteDestination?> selectDriverRouteDestination(
  BuildContext context,
  Map<String, Object?> ride,
) {
  final latitude = double.tryParse('${ride['destinationLatitude']}');
  final longitude = double.tryParse('${ride['destinationLongitude']}');
  final initialTarget = latitude != null &&
          longitude != null &&
          latitude.isFinite &&
          longitude.isFinite &&
          latitude.abs() <= 90 &&
          longitude.abs() <= 180
      ? LatLng(latitude, longitude)
      : const LatLng(15.3694, 44.1910);
  final repository = DriverDestinationSearch(Get.find<ApiClient>());
  return Navigator.of(context).push<RideRouteDestination>(MaterialPageRoute(
    builder: (_) => RideRouteDestinationPicker(
      initialTarget: initialTarget,
      search: repository.search,
      reverseGeocode: repository.reverseGeocode,
    ),
  ));
}

class DriverDestinationSearch {
  const DriverDestinationSearch(this.client);
  final ApiClient client;

  Future<Object?> _call(String operation, Map<String, Object?> data) async {
    final result = await client.execute<Object?>(
        model: 'MapLocationSearchModel', operation: operation, data: data);
    if (result is ApiFailure<Object?>) {
      throw FormatException(result.problem.detail ?? result.problem.title);
    }
    return (result as ApiSuccess<Object?>).data;
  }

  Future<List<RideRouteDestination>> search(String query) async {
    final data = await _call('search', {'query': query.trim()});
    if (data is! List) throw const FormatException('تعذرت قراءة نتائج البحث.');
    return data.map(_destination).whereType<RideRouteDestination>().toList();
  }

  Future<RideRouteDestination?> reverseGeocode(LatLng point) async {
    final data = await _call('report', {
      'latitude': point.latitude,
      'longitude': point.longitude,
    });
    return _destination(data);
  }

  RideRouteDestination? _destination(Object? raw) {
    if (raw is! Map) return null;
    final latitude = double.tryParse('${raw['latitude']}');
    final longitude = double.tryParse('${raw['longitude']}');
    if (latitude == null || longitude == null) return null;
    final address = '${raw['formattedAddress'] ?? ''}'.trim();
    final destination = RideRouteDestination(
      latitude: latitude,
      longitude: longitude,
      label: address.isNotEmpty ? address : '${raw['title'] ?? ''}'.trim(),
    );
    return destination.isValid ? destination : null;
  }
}
