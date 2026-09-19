import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_models.dart';

class LocationSearchResult {
  const LocationSearchResult({
    required this.title,
    required this.formattedAddress,
    required this.location,
    this.street = '',
  });

  final String title;
  final String formattedAddress;
  final String street;
  final LatLng location;
}

class NoInternetException implements Exception {
  const NoInternetException();
}

abstract interface class LocationSearchRepository {
  Future<List<LocationSearchResult>> search(String query);
  Future<LocationSearchResult?> reverseGeocode(LatLng point);
}

/// Provider searches are made through YemenDrive API. This keeps Places and
/// Geocoding credentials outside the APK.
class ApiLocationSearchRepository implements LocationSearchRepository {
  ApiLocationSearchRepository(this._client);
  final ApiClient _client;

  @override
  Future<List<LocationSearchResult>> search(String query) async {
    if (query.trim().length < 2) return const [];
    final result = await _client.execute<Object?>(
      model: 'MapLocationSearchModel',
      operation: 'search',
      data: <String, Object?>{'query': query.trim()},
    );
    if (result is ApiFailure<Object?>) _throwForFailure(result);
    if (result is! ApiSuccess<Object?> || result.data is! List) return const [];
    return (result.data as List)
        .whereType<Map>()
        .map((item) => _fromJson(Map<Object?, Object?>.from(item)))
        .where((item) =>
            item.location.latitude != 0 || item.location.longitude != 0)
        .toList(growable: false);
  }

  @override
  Future<LocationSearchResult?> reverseGeocode(LatLng point) async {
    final result = await _client.execute<Object?>(
      model: 'MapLocationSearchModel',
      operation: 'report',
      data: <String, Object?>{
        'latitude': point.latitude,
        'longitude': point.longitude,
      },
    );
    if (result is ApiFailure<Object?>) _throwForFailure(result);
    if (result is! ApiSuccess<Object?> || result.data is! Map) return null;
    return _fromJson(Map<Object?, Object?>.from(result.data as Map));
  }

  Never _throwForFailure(ApiFailure<Object?> failure) {
    if (failure.problem.code == 'network_error')
      throw const NoInternetException();
    throw LocationSearchRequestException(failure.problem.title);
  }

  LocationSearchResult _fromJson(Map<Object?, Object?> data) =>
      LocationSearchResult(
        title: '${data['title'] ?? 'موقع'}',
        formattedAddress: '${data['formattedAddress'] ?? ''}',
        street: '${data['street'] ?? ''}',
        location: LatLng(
          (data['latitude'] as num?)?.toDouble() ?? 0,
          (data['longitude'] as num?)?.toDouble() ?? 0,
        ),
      );
}

class LocationSearchRequestException implements Exception {
  const LocationSearchRequestException(this.message);
  final String message;
  @override
  String toString() => message;
}
