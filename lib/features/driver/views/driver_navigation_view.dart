import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../shared/widgets/app_google_map.dart';
import '../../../shared/widgets/ride_waiting_panel.dart';
import '../../../shared/widgets/ride_route_change_panel.dart';
import '../controllers/driver_controller.dart';
import '../repositories/route_repository.dart';

/// In-app navigation preview for the assigned driver's pickup or destination.
/// GPS stays local for the driver's marker; SignalR publishes that same fix to
/// the ride participants through the normal driver controller.
class DriverNavigationView extends StatefulWidget {
  const DriverNavigationView({super.key});

  @override
  State<DriverNavigationView> createState() => _DriverNavigationViewState();
}

class _DriverNavigationViewState extends State<DriverNavigationView> {
  late final LatLng _origin;
  late LatLng _destination;
  late final String _title;
  late final bool _followsDestination;
  late final int? _rideId;
  late final DriverController _driverController;
  late final Worker _positionWorker;
  late final Worker _passengerLocationWorker;
  late final Worker _rideWorker;
  final _routeRepository = ApiRoutesRepository(Get.find());

  LatLng? _driverPosition;
  LatLng? _passengerPosition;
  LatLng? _cameraFollowTarget;
  LatLng? _lastRouteOrigin;
  DateTime? _lastRouteRequestedAt;
  DateTime? _animationStartedAt;
  LatLng? _animationFrom;
  LatLng? _animationTarget;
  Timer? _markerAnimationTimer;
  List<LatLng> _routePoints = const <LatLng>[];
  bool _loading = true;
  bool _routeRequestInFlight = false;
  bool _routeReloadRequested = false;
  int _routeGeneration = 0;
  int _routeVersion = 0;
  Map<String, Object?>? _ride;
  String? _error;
  String _nextInstruction = '';
  String _nextManeuver = '';
  double _bearing = 0;
  double? _passengerBearing;
  int _distanceMeters = 0;
  int _durationSeconds = 0;
  int _nextStepDistanceMeters = 0;

  @override
  void initState() {
    super.initState();
    final data = Map<Object?, Object?>.from(
      (Get.arguments as Map?) ?? const <Object?, Object?>{},
    );
    _origin = LatLng(
      _number(data['originLatitude']),
      _number(data['originLongitude']),
    );
    _destination = LatLng(
      _number(data['destinationLatitude']),
      _number(data['destinationLongitude']),
    );
    _title = '${data['title'] ?? 'مسار الرحلة'}';
    _followsDestination = data['followsDestination'] == true;
    _rideId = int.tryParse('${data['rideId'] ?? ''}');
    _driverController = Get.find<DriverController>();
    final initialPosition = _driverController.currentPosition.value;
    _driverPosition = initialPosition == null
        ? _origin
        : LatLng(initialPosition.latitude, initialPosition.longitude);
    _cameraFollowTarget = _driverPosition;
    _positionWorker = ever<Position?>(
      _driverController.currentPosition,
      _handlePosition,
    );
    final rideId = _rideId;
    _setPassengerPosition(
      rideId == null
          ? null
          : _driverController.passengerLocationForRide(rideId),
    );
    _passengerLocationWorker = ever(
      _driverController.passengerLocationsByRideId,
      (_) => _syncPassengerPosition(),
    );
    _rideWorker = ever(_driverController.rides, (_) => _syncRide());
    _syncRide();
    if (rideId != null) {
      unawaited(
          _driverController.refreshRide(rideId).catchError((Object _) {}));
    }
    unawaited(_loadRoute(_driverPosition!, force: true));
  }

  void _syncRide() {
    if (!mounted || _rideId == null) return;
    final ride = _driverController.rides
        .where((item) => '${item['id']}' == '$_rideId')
        .firstOrNull;
    if (ride == null) return;
    final latitude = double.tryParse('${ride['destinationLatitude']}');
    final longitude = double.tryParse('${ride['destinationLongitude']}');
    final version = int.tryParse('${ride['routeVersion']}') ?? 0;
    final canFollow = _followsDestination &&
        latitude != null &&
        longitude != null &&
        latitude.isFinite &&
        longitude.isFinite &&
        latitude.abs() <= 90 &&
        longitude.abs() <= 180;
    final destination = canFollow ? LatLng(latitude, longitude) : _destination;
    final routeChanged =
        canFollow && (destination != _destination || version != _routeVersion);
    setState(() {
      _ride = ride;
      _routeVersion = version;
      if (routeChanged) {
        _destination = destination;
        _routeGeneration++;
        _routePoints = const [];
        _distanceMeters = 0;
        _durationSeconds = 0;
        _nextInstruction = '';
        _nextManeuver = '';
        _error = null;
        _loading = true;
      }
    });
    if (routeChanged) {
      unawaited(_loadRoute(_driverPosition ?? _origin, force: true));
    }
  }

  void _syncPassengerPosition() {
    if (!mounted) return;
    final rideId = _rideId;
    setState(() {
      _setPassengerPosition(
        rideId == null
            ? null
            : _driverController.passengerLocationForRide(rideId),
      );
    });
  }

  void _setPassengerPosition(PassengerLocationUpdate? location) {
    _passengerPosition =
        location == null ? null : LatLng(location.latitude, location.longitude);
    _passengerBearing = location?.bearing;
  }

  void _handlePosition(Position? position) {
    if (position == null ||
        !position.accuracy.isFinite ||
        position.accuracy <= 0 ||
        position.accuracy > 75) {
      return;
    }

    final target = LatLng(position.latitude, position.longitude);
    final headingIsReliable = position.heading.isFinite &&
        position.heading >= 0 &&
        (position.speed.isFinite ? position.speed : 0) > 0.7;
    setState(() {
      if (headingIsReliable) _bearing = position.heading % 360;
      _animateMarkerTo(target);
      final previousCameraTarget = _cameraFollowTarget ?? _origin;
      if (Geolocator.distanceBetween(
            previousCameraTarget.latitude,
            previousCameraTarget.longitude,
            target.latitude,
            target.longitude,
          ) >=
          150) {
        _cameraFollowTarget = target;
      }
    });
    unawaited(_loadRoute(target));
  }

  void _animateMarkerTo(LatLng target) {
    _markerAnimationTimer?.cancel();
    final start = _driverPosition ?? target;
    _animationFrom = start;
    _animationTarget = target;
    _animationStartedAt = DateTime.now();
    const duration = Duration(milliseconds: 1500);
    _markerAnimationTimer = Timer.periodic(
      const Duration(milliseconds: 40),
      (timer) {
        final from = _animationFrom;
        final to = _animationTarget;
        final startedAt = _animationStartedAt;
        if (!mounted || from == null || to == null || startedAt == null) {
          timer.cancel();
          return;
        }
        final progress = (DateTime.now().difference(startedAt).inMilliseconds /
                duration.inMilliseconds)
            .clamp(0.0, 1.0);
        setState(() {
          _driverPosition = LatLng(
            from.latitude + (to.latitude - from.latitude) * progress,
            from.longitude + (to.longitude - from.longitude) * progress,
          );
        });
        if (progress >= 1) {
          timer.cancel();
          _markerAnimationTimer = null;
        }
      },
    );
  }

  Future<void> _loadRoute(LatLng origin, {bool force = false}) async {
    if (_routeRequestInFlight) {
      if (force) _routeReloadRequested = true;
      return;
    }
    final lastOrigin = _lastRouteOrigin;
    final movedEnough = lastOrigin == null ||
        Geolocator.distanceBetween(
              lastOrigin.latitude,
              lastOrigin.longitude,
              origin.latitude,
              origin.longitude,
            ) >=
            30;
    final requestedRecently = _lastRouteRequestedAt != null &&
        DateTime.now().difference(_lastRouteRequestedAt!) <
            const Duration(seconds: 45);
    if (!force && (!movedEnough || requestedRecently)) return;

    _routeRequestInFlight = true;
    final generation = _routeGeneration;
    final destination = _destination;
    if (_routePoints.isEmpty && mounted) setState(() => _loading = true);
    try {
      final route = await _routeRepository.getDrivingRoute(
        origin: origin,
        destination: destination,
        includeSteps: true,
      );
      if (!mounted || generation != _routeGeneration) return;
      _lastRouteOrigin = origin;
      _lastRouteRequestedAt = DateTime.now();
      setState(() {
        _error = null;
        _routePoints = route.points;
        _distanceMeters = route.distanceMeters;
        _durationSeconds = route.durationSeconds;
        final nextStep = route.steps.isEmpty ? null : route.steps.first;
        _nextInstruction = nextStep?.instruction ?? '';
        _nextManeuver = nextStep?.maneuver ?? '';
        _nextStepDistanceMeters = nextStep?.distanceMeters ?? 0;
      });
    } catch (_) {
      if (mounted && generation == _routeGeneration) {
        setState(() => _error = 'تعذر تحديث مسار القيادة الآن.');
      }
    } finally {
      _routeRequestInFlight = false;
      if (mounted) {
        if (_routeReloadRequested || generation != _routeGeneration) {
          _routeReloadRequested = false;
          unawaited(_loadRoute(_driverPosition ?? _origin, force: true));
        } else {
          setState(() => _loading = false);
        }
      }
    }
  }

  List<LatLng> get _remainingRoutePoints {
    final current = _driverPosition;
    if (current == null || _routePoints.length < 2) return _routePoints;
    var nearestIndex = 0;
    var nearestMeters = double.infinity;
    for (var index = 0; index < _routePoints.length; index++) {
      final point = _routePoints[index];
      final meters = Geolocator.distanceBetween(
        current.latitude,
        current.longitude,
        point.latitude,
        point.longitude,
      );
      if (meters < nearestMeters) {
        nearestMeters = meters;
        nearestIndex = index;
      }
    }
    final nextIndex = (nearestIndex + 1).clamp(0, _routePoints.length - 1);
    return <LatLng>[current, ..._routePoints.skip(nextIndex)];
  }

  int get _remainingDistanceMeters {
    final points = _remainingRoutePoints;
    if (points.length < 2) return _distanceMeters;
    var distance = 0.0;
    for (var index = 1; index < points.length; index++) {
      distance += Geolocator.distanceBetween(
        points[index - 1].latitude,
        points[index - 1].longitude,
        points[index].latitude,
        points[index].longitude,
      );
    }
    return distance.round();
  }

  int get _remainingDurationSeconds {
    if (_distanceMeters <= 0) return _durationSeconds;
    return (_durationSeconds * _remainingDistanceMeters / _distanceMeters)
        .round();
  }

  Set<Marker> get _markers => <Marker>{
        if (_driverPosition != null)
          Marker(
            markerId: const MarkerId('driver'),
            position: _driverPosition!,
            rotation: _bearing,
            flat: true,
            anchor: const Offset(0.5, 0.5),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueAzure,
            ),
            infoWindow: const InfoWindow(title: 'موقعك'),
          ),
        if (_passengerPosition != null)
          Marker(
            markerId: MarkerId('passenger-${_rideId ?? 'current'}'),
            position: _passengerPosition!,
            rotation: _passengerBearing ?? 0,
            flat: _passengerBearing != null,
            anchor: const Offset(0.5, 0.5),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueRed,
            ),
            infoWindow: const InfoWindow(title: 'موقع الراكب المباشر'),
          ),
        Marker(
          markerId: const MarkerId('target'),
          position: _destination,
          infoWindow: InfoWindow(title: _title),
        ),
      };

  Set<Polyline> get _currentPolylines {
    final points = _remainingRoutePoints;
    if (points.length < 2) return const <Polyline>{};
    return <Polyline>{
      Polyline(
        polylineId: const PolylineId('driver-route'),
        points: points,
        color: Theme.of(context).colorScheme.primary,
        width: 6,
      ),
    };
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_title)),
        bottomNavigationBar: _rideId == null
            ? null
            : SafeArea(
                child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * .4),
                child: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  RideWaitingPanel(
                    rideId: _rideId,
                    isDriver: true,
                    onChanged: () => unawaited(_driverController
                        .refreshRide(_rideId)
                        .catchError((Object _) {})),
                  ),
                  if ('${_ride?['status']}' == '5')
                    RideRouteChangePanel(
                      rideId: _rideId,
                      isDriver: true,
                      selectDestination: () async => null,
                      onRouteChanged: () =>
                          _driverController.refreshRide(_rideId),
                    ),
                ])),
              )),
        body: Stack(
          children: <Widget>[
            AppGoogleMap(
              initialTarget: _driverPosition ?? _destination,
              initialZoom: 15,
              followTarget: _cameraFollowTarget,
              myLocationEnabled: true,
              markers: _markers,
              polylines: _currentPolylines,
            ),
            Positioned(
              right: 16,
              left: 16,
              bottom: 20,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (_followsDestination && _ride != null) ...[
                        Text(
                            '${_ride!['destinationDisplayName'] ?? _ride!['destinationAddress'] ?? 'وجهة الرحلة'}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        Text(
                            'الإجمالي الحالي: ${_ride!['totalAmount'] ?? _ride!['customerPrice'] ?? '-'} ر.ي'),
                        const SizedBox(height: 8),
                      ],
                      Row(
                        children: <Widget>[
                          const Icon(Icons.route_rounded),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _loading && _distanceMeters == 0
                                ? const Text('جارٍ حساب المسار…')
                                : Text(
                                    '${(_remainingDistanceMeters / 1000).toStringAsFixed(1)} كم · ${(_remainingDurationSeconds / 60).ceil()} دقيقة',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                          ),
                          if (_loading && _distanceMeters > 0)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            ),
                        ],
                      ),
                      if (_nextInstruction.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 8),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Icon(_maneuverIcon(_nextManeuver), size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${_nextStepDistanceMeters > 0 ? 'بعد $_nextStepDistanceMeters م: ' : ''}$_nextInstruction',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (_error != null) ...<Widget>[
                        const SizedBox(height: 6),
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        TextButton(
                          onPressed: () => _loadRoute(
                            _driverPosition ?? _origin,
                            force: true,
                          ),
                          child: const Text('إعادة المحاولة'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  IconData _maneuverIcon(String maneuver) {
    final value = maneuver.toUpperCase();
    if (value.contains('LEFT')) return Icons.turn_left_rounded;
    if (value.contains('RIGHT')) return Icons.turn_right_rounded;
    if (value.contains('UTURN')) return Icons.u_turn_left_rounded;
    return Icons.straight_rounded;
  }

  double _number(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('${value ?? ''}') ?? 0;

  @override
  void dispose() {
    _positionWorker.dispose();
    _passengerLocationWorker.dispose();
    _rideWorker.dispose();
    _markerAnimationTimer?.cancel();
    super.dispose();
  }
}
