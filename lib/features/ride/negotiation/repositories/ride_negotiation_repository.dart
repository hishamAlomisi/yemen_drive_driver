import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_models.dart';
import '../../models/ride_models.dart';

abstract interface class RideNegotiationRepository {
  Future<RideQuote> getQuote({
    required int serviceKindId,
    required int serviceCatalogItemId,
    required RideCoordinate pickup,
    required RideCoordinate destination,
  });

  Future<String> createRequest(RideRequestDraft draft);
  Future<Map<String, Object?>> getRideDetail(String requestId);
  DriverOffer? mapRealtimeOffer(Map<String, Object?> event);
  Future<void> acceptOffer(String requestId, String offerId);
  Future<void> rejectOffer(String requestId, String offerId);
  Future<void> cancelRequest(String requestId);
}

/// REST provides the initial/reconnect snapshot. New offer changes arrive over
/// the authenticated Tracking Hub connection.
class ApiRideNegotiationRepository implements RideNegotiationRepository {
  const ApiRideNegotiationRepository(this._client);
  final ApiClient _client;

  @override
  Future<RideQuote> getQuote({
    required int serviceKindId,
    required int serviceCatalogItemId,
    required RideCoordinate pickup,
    required RideCoordinate destination,
  }) async {
    final result = await _client.execute<Object?>(
      model: 'PricingModel',
      operation: 'report',
      data: <String, Object?>{
        'serviceKindId': serviceKindId,
        'serviceCatalogItemId': serviceCatalogItemId,
        'distanceKm': _distance(pickup, destination),
        'durationMinutes': 0,
      },
    );
    if (result is! ApiSuccess) {
      throw const FormatException('تعذر جلب تسعيرة الخدمة من الخادم.');
    }
    final body = _map(result.data);
    final amountValue = body['amount'] ?? body['suggestedPrice'];
    final amount = _number(amountValue);
    if (amount <= 0) {
      throw const FormatException('الخدمة لا تحتوي على قاعدة تسعير فعالة.');
    }
    return RideQuote(
      suggestedPrice: amount,
      minPrice: amount,
      maxPrice: amount,
      priceStep: 100,
      currency: body['currency']?.toString() ?? 'ر.ي',
    );
  }

  @override
  Future<String> createRequest(RideRequestDraft draft) async {
    final result = await _client.execute<Object?>(
      model: 'RideModel',
      operation: 'add',
      data: <String, Object?>{
        'serviceKindId': draft.serviceKindId,
        'serviceCatalogItemId': draft.serviceCatalogItemId,
        'pickupLabel': draft.pickup,
        'pickupAddress': draft.pickupAddress,
        'pickupLatitude': draft.pickupCoordinate.latitude,
        'pickupLongitude': draft.pickupCoordinate.longitude,
        'destinationLabel': draft.destination,
        'destinationAddress': draft.destinationAddress,
        'destinationLatitude': draft.destinationCoordinate.latitude,
        'destinationLongitude': draft.destinationCoordinate.longitude,
        'customerPrice': draft.offeredPrice,
      },
    );
    final id =
        result is ApiSuccess ? _map(result.data)['id']?.toString() : null;
    if (id == null || id.isEmpty)
      throw const FormatException('Invalid ride response.');
    return id;
  }

  @override
  Future<Map<String, Object?>> getRideDetail(String requestId) async {
    final result = await _client.execute<Object?>(
      model: 'RideModel',
      operation: 'get',
      data: <String, Object?>{'id': requestId},
    );
    if (result is! ApiSuccess) {
      throw const FormatException('تعذر تحديث حالة الرحلة من الخادم.');
    }
    return _map(result.data);
  }

  @override
  DriverOffer? mapRealtimeOffer(Map<String, Object?> item) {
    final id = item['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    return DriverOffer(
      id: id,
      driverName: item['driverName']?.toString() ?? '',
      vehicleSummary: item['vehicleModel']?.toString() ?? '',
      price: _number(item['amount']),
      rating: 0,
      etaMinutes: 0,
      status: _offerStatus(item['status']),
      expiresAt: _serverUtcDateTime(item['expiresAtUtc']),
    );
  }

  DriverOfferStatus _offerStatus(Object? value) {
    switch (value?.toString().toLowerCase()) {
      case 'accepted':
      case '1':
        return DriverOfferStatus.accepted;
      case 'rejected':
      case '2':
        return DriverOfferStatus.rejected;
      case 'expired':
      case '3':
        return DriverOfferStatus.expired;
      default:
        return DriverOfferStatus.pending;
    }
  }

  static DateTime? _serverUtcDateTime(Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    final parsed = DateTime.tryParse(text);
    if (parsed == null) return null;
    final hasOffset =
        RegExp(r'(?:Z|[+-]\d{2}:?\d{2})$', caseSensitive: false).hasMatch(text);
    if (hasOffset) return parsed.toUtc();
    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
      parsed.microsecond,
    );
  }

  @override
  Future<void> acceptOffer(String requestId, String offerId) async {
    await _client.execute<Object?>(
        model: 'RideOfferActionModel',
        operation: 'accept',
        data: {'rideId': requestId, 'offerId': offerId});
  }

  @override
  Future<void> rejectOffer(String requestId, String offerId) async {
    await _client.execute<Object?>(
        model: 'RideOfferActionModel',
        operation: 'reject',
        data: {'rideId': requestId, 'offerId': offerId});
  }

  @override
  Future<void> cancelRequest(String requestId) async {
    await _client.execute<Object?>(
        model: 'RideModel', operation: 'cancel', data: {'id': requestId});
  }

  static Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  static double _number(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

  static double _distance(RideCoordinate a, RideCoordinate b) {
    final dx = (a.latitude - b.latitude).abs();
    final dy = (a.longitude - b.longitude).abs();
    return (dx + dy) * 111;
  }
}

