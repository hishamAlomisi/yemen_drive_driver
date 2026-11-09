import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../shared/widgets/app_google_map.dart';
import '../../../shared/widgets/live_tracking_marker_icons.dart';
import '../../../shared/widgets/live_route_polyline.dart';
import '../../../shared/widgets/ride_waiting_panel.dart';
import '../../../shared/widgets/ride_financial_follow_up.dart';
import '../../../shared/widgets/ride_route_change_panel.dart';
import '../../../shared/widgets/ride_chat_badge.dart';
import 'driver_chat_view.dart';
import '../controllers/driver_controller.dart';
import '../models/driving_route_progress.dart';
import '../models/driver_map_motion.dart';
import '../repositories/route_repository.dart';

/// In-app navigation preview for the assigned driver's pickup or destination.
/// GPS stays local for the driver's marker; SignalR publishes that same fix to
/// the ride participants through the normal driver controller.
class DriverNavigationView extends StatefulWidget {
  const DriverNavigationView({super.key});

  @override
  State<DriverNavigationView> createState() => _DriverNavigationViewState();
}

class _DriverNavigationViewState extends State<DriverNavigationView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  LatLng? _origin;
  late LatLng _destination;
  late String _title;
  late bool _followsDestination;
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
  DateTime? _lastRouteAttemptedAt;
  DateTime? _lastObservedAt;
  Position? _lastGpsPosition;
  LatLng? _animationFrom;
  LatLng? _animationTarget;
  double _animationFromBearing = 0;
  double _animationTargetBearing = 0;
  late final AnimationController _markerAnimation;
  final _markerFrameRevision = ValueNotifier<int>(0);
  Duration? _lastMarkerFrameElapsed;
  int _followRequestId = 0;
  bool _followingDriver = true;
  bool _foreground = true;
  bool _tickerEnabled = true;
  bool get _mapWorkEnabled => _foreground && _tickerEnabled;
  List<LatLng> _routePoints = const <LatLng>[];
  List<LatLng> _remainingRoutePoints = const <LatLng>[];
  DrivingRouteProgress? _routeProgress;
  int _remainingDistanceMeters = 0;
  List<LatLng>? _polylinePoints;
  Color? _polylineColor;
  Set<Polyline> _routePolylines = const <Polyline>{};
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
  DateTime? _passengerObservedAt;
  Timer? _locationAgeTimer;
  int _distanceMeters = 0;
  int _durationSeconds = 0;
  int _nextStepDistanceMeters = 0;
  BitmapDescriptor? _approachIcon;
  BitmapDescriptor? _tripIcon;
  BitmapDescriptor? _pickupIcon;
  BitmapDescriptor? _destinationIcon;
  bool get _tripStarted =>
      '${_ride?['status']}' == '5' ||
      ('${_ride?['status']}' == '8' && _ride?['startedAtUtc'] != null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _markerAnimation = AnimationController(vsync: this)
      ..addListener(_updateAnimatedMarker);
    final data = Map<Object?, Object?>.from(
      (Get.arguments as Map?) ?? const <Object?, Object?>{},
    );
    _origin = _coordinates(data['originLatitude'], data['originLongitude']);
    _destination = LatLng(
      _number(data['destinationLatitude']),
      _number(data['destinationLongitude']),
    );
    _title = '${data['title'] ?? 'مسار الرحلة'}';
    _followsDestination = data['followsDestination'] == true;
    _rideId = int.tryParse('${data['rideId'] ?? ''}');
    _driverController = Get.find<DriverController>();
    unawaited(_loadMarkerIcons());
    final initialPosition = _driverController.currentPosition.value;
    _lastGpsPosition = initialPosition;
    _lastObservedAt = initialPosition?.timestamp;
    if (initialPosition != null && _hasReliableHeading(initialPosition)) {
      _bearing = initialPosition.heading % 360;
    }
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
    _locationAgeTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && _mapWorkEnabled) setState(() {});
    });
    if (_driverPosition != null) {
      unawaited(_loadRoute(_driverPosition!, force: true));
    } else {
      _loading = false;
    }
    unawaited(_driverController.updateLocation());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wasEnabled = _mapWorkEnabled;
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _syncMapWork(wasEnabled);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasEnabled = _mapWorkEnabled;
    _foreground = state == AppLifecycleState.resumed;
    _syncMapWork(wasEnabled);
    if (mounted && _mapWorkEnabled) setState(() {});
  }

  void _syncMapWork(bool wasEnabled) {
    if (!_mapWorkEnabled) {
      _markerAnimation.stop();
    } else if (!wasEnabled) {
      final position = _lastGpsPosition;
      if (position == null) return;
      _driverPosition = LatLng(position.latitude, position.longitude);
      _cameraFollowTarget = _driverPosition;
      _bearing = DriverMapMotion.heading(null, position, _bearing);
      _refreshRouteProgress();
      unawaited(_loadRoute(_driverPosition!));
    }
  }

  Future<void> _loadMarkerIcons() async {
    try {
      final icons = await Future.wait([
        LiveTrackingMarkerIcons.build(inProgress: false),
        LiveTrackingMarkerIcons.build(inProgress: true),
        LiveTrackingMarkerIcons.buildStop(
            destination: false, label: 'نقطة الانطلاق'),
        LiveTrackingMarkerIcons.buildStop(destination: true, label: 'الوجهة'),
      ]);
      if (!mounted) return;
      setState(() {
        _approachIcon = icons[0];
        _tripIcon = icons[1];
        _pickupIcon = icons[2];
        _destinationIcon = icons[3];
      });
    } on Object {
      // A failed bitmap render keeps the location marker visible.
    }
  }

  void _syncRide() {
    if (!mounted || _rideId == null) return;
    final ride = _driverController.rides
        .where((item) => '${item['id']}' == '$_rideId')
        .firstOrNull;
    if (ride == null) return;
    final status = int.tryParse('${ride['status']}');
    final started =
        status == 5 || (status == 8 && ride['startedAtUtc'] != null);
    final phaseChanged = started && !_followsDestination;
    if (started) {
      _followsDestination = true;
      _title = 'تتبع الرحلة إلى الوجهة';
    }
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
    final routeChanged = canFollow &&
        (phaseChanged ||
            destination != _destination ||
            version != _routeVersion);
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
        _refreshRouteProgress();
      }
    });
    final origin = _driverPosition ?? _origin;
    if (routeChanged && origin != null) {
      unawaited(_loadRoute(origin, force: true));
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
    _passengerObservedAt = location?.observedAtUtc;
  }

  void _handlePosition(Position? position) {
    if (position == null ||
        !position.latitude.isFinite ||
        !position.longitude.isFinite ||
        position.latitude.abs() > 90 ||
        position.longitude.abs() > 180 ||
        !position.accuracy.isFinite ||
        position.accuracy <= 0) {
      return;
    }
    final previousTime = _lastObservedAt;
    if (previousTime != null && !position.timestamp.isAfter(previousTime))
      return;
    final age = DateTime.now().toUtc().difference(position.timestamp.toUtc());
    if (age > const Duration(seconds: 30) || age < const Duration(seconds: -5))
      return;
    final sampleGap = previousTime == null
        ? null
        : position.timestamp.difference(previousTime);
    _lastObservedAt = position.timestamp;

    final target = LatLng(position.latitude, position.longitude);
    final bearing =
        DriverMapMotion.heading(_lastGpsPosition, position, _bearing);
    _lastGpsPosition = position;
    if (!_mapWorkEnabled) {
      _markerAnimation.stop();
      _driverPosition = target;
      _cameraFollowTarget = target;
      _bearing = bearing;
      return;
    }
    setState(() {
      _refreshRouteProgress();
      _animateMarkerTo(target, bearing, sampleGap);
    });
    if (position.accuracy <= 75) unawaited(_loadRoute(target));
  }

  bool _hasReliableHeading(Position position) =>
      position.heading.isFinite &&
      position.heading >= 0 &&
      position.speed.isFinite &&
      position.speed > 0.7;

  void _animateMarkerTo(LatLng target, double bearing, Duration? sampleGap) {
    _markerAnimation.stop();
    _lastMarkerFrameElapsed = null;
    final start = _driverPosition;
    if (start == null ||
        sampleGap == null ||
        sampleGap > const Duration(seconds: 10) ||
        Geolocator.distanceBetween(start.latitude, start.longitude,
                target.latitude, target.longitude) >
            250) {
      _driverPosition = target;
      _cameraFollowTarget = target;
      _bearing = bearing;
      return;
    }
    _animationFrom = start;
    _animationTarget = target;
    _animationFromBearing = _bearing;
    _animationTargetBearing = bearing;
    // Animate only between received fixes; stop exactly at the latest GPS.
    _markerAnimation.duration = DriverMapMotion.duration(sampleGap);
    _markerAnimation.forward(from: 0);
  }

  void _updateAnimatedMarker() {
    final from = _animationFrom;
    final to = _animationTarget;
    if (!mounted || !_mapWorkEnabled || from == null || to == null) return;
    final progress = _markerAnimation.value;
    final elapsed = _markerAnimation.lastElapsedDuration ?? Duration.zero;
    if (progress < 1 &&
        _lastMarkerFrameElapsed != null &&
        elapsed - _lastMarkerFrameElapsed! < const Duration(milliseconds: 33)) {
      return;
    }
    _lastMarkerFrameElapsed = elapsed;
    final headingDelta =
        (_animationTargetBearing - _animationFromBearing + 540) % 360 - 180;
    final longitudeDelta = (to.longitude - from.longitude + 540) % 360 - 180;
    _driverPosition = progress >= 1
        ? to
        : LatLng(
            from.latitude + (to.latitude - from.latitude) * progress,
            (from.longitude + longitudeDelta * progress + 540) % 360 - 180,
          );
    _bearing = (_animationFromBearing + headingDelta * progress + 360) % 360;
    _cameraFollowTarget = _driverPosition;
    // Marker updates are paced to roughly 30/second. Panels, route scans,
    // and distance calculations only update for real fixes or business events.
    _markerFrameRevision.value++;
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
    final offRoute = (_routeProgress?.offRouteMeters ?? 0) > 75;
    final attemptedRecently = _lastRouteAttemptedAt != null &&
        DateTime.now().difference(_lastRouteAttemptedAt!) <
            const Duration(seconds: 5);
    if (!force &&
        (attemptedRecently ||
            (!offRoute && (!movedEnough || requestedRecently)))) {
      return;
    }

    _routeRequestInFlight = true;
    _lastRouteAttemptedAt = DateTime.now();
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
        _refreshRouteProgress();
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
          final nextOrigin = _driverPosition ?? _origin;
          if (nextOrigin != null) {
            unawaited(_loadRoute(nextOrigin, force: true));
          }
        } else {
          setState(() => _loading = false);
        }
      }
    }
  }

  void _refreshRouteProgress() {
    final fix = _lastGpsPosition;
    final current =
        fix == null ? _driverPosition : LatLng(fix.latitude, fix.longitude);
    _routeProgress = current == null || _routePoints.length < 2
        ? null
        : DrivingRouteProgress.from(_routePoints, current);
    final points =
        _remainingRoutePoints = _routeProgress?.points ?? _routePoints;
    if (points.length < 2) {
      _remainingDistanceMeters = _distanceMeters;
      return;
    }
    var distance = 0.0;
    for (var index = 1; index < points.length; index++) {
      distance += Geolocator.distanceBetween(
        points[index - 1].latitude,
        points[index - 1].longitude,
        points[index].latitude,
        points[index].longitude,
      );
    }
    _remainingDistanceMeters = distance.round();
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
            icon: (_tripStarted ? _tripIcon : _approachIcon) ??
                BitmapDescriptor.defaultMarkerWithHue(
                    BitmapDescriptor.hueAzure),
            infoWindow: InfoWindow(
                title: _tripStarted
                    ? 'موقعك · الرحلة جارية'
                    : 'موقعك · الطريق إلى الراكب'),
          ),
        if (!_tripStarted &&
            _passengerPosition != null &&
            (_followsDestination ||
                Geolocator.distanceBetween(
                        _passengerPosition!.latitude,
                        _passengerPosition!.longitude,
                        _destination.latitude,
                        _destination.longitude) >
                    20))
          Marker(
            markerId: MarkerId('passenger-${_rideId ?? 'current'}'),
            position: _passengerPosition!,
            anchor: LiveTrackingMarkerIcons.stopAnchor,
            icon: _pickupIcon ??
                BitmapDescriptor.defaultMarkerWithHue(
                    BitmapDescriptor.hueAzure),
            infoWindow: const InfoWindow(title: 'موقع الراكب المباشر'),
          ),
        Marker(
          markerId: const MarkerId('target'),
          position: _destination,
          anchor: LiveTrackingMarkerIcons.stopAnchor,
          icon: (_followsDestination ? _destinationIcon : _pickupIcon) ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: InfoWindow(
              title: _followsDestination ? 'الوجهة' : 'نقطة الانطلاق'),
        ),
      };

  Set<Polyline> get _currentPolylines {
    final points = _remainingRoutePoints;
    if (points.length < 2) return const <Polyline>{};
    final color = Theme.of(context).colorScheme.primary;
    if (identical(_polylinePoints, points) && _polylineColor == color) {
      return _routePolylines;
    }
    _polylinePoints = points;
    _polylineColor = color;
    return _routePolylines = <Polyline>{
      LiveRoutePolyline(
        polylineId: const PolylineId('driver-route'),
        points: points,
        color: color,
        width: 6,
      ),
    };
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_title), actions: [
          if (_rideId != null &&
              '${_ride?['driverId']}' == '${_driverController.currentUserId}' &&
              {3, 4, 5, 8, 9}.contains(int.tryParse('${_ride?['status']}')))
            IconButton(
              tooltip: 'محادثة العميل',
              onPressed: () =>
                  Get.to<void>(() => DriverChatView(rideId: '$_rideId')),
              icon: RideChatBadge(rideId: _rideId),
            ),
        ]),
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
            ValueListenableBuilder<int>(
              valueListenable: _markerFrameRevision,
              builder: (context, revision, child) => AppGoogleMap(
                initialTarget: _driverPosition ?? _destination,
                initialZoom: 15,
                followTarget: _cameraFollowTarget,
                smoothFollow: true,
                pauseOnUserInteraction: true,
                followRequestId: _followRequestId,
                onUserInteraction: () {
                  if (_followingDriver)
                    setState(() => _followingDriver = false);
                },
                markers: _markers,
                polylines: _currentPolylines,
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                elevation: 3,
                shape: const CircleBorder(),
                child: IconButton(
                  key: const ValueKey('driver-recenter'),
                  tooltip: _followingDriver ? 'توسيط موقعك' : 'متابعة موقعك',
                  icon: Icon(_followingDriver
                      ? Icons.my_location_rounded
                      : Icons.location_searching_rounded),
                  onPressed: _driverPosition == null
                      ? null
                      : () {
                          setState(() {
                            _followingDriver = true;
                            _followRequestId++;
                          });
                        },
                ),
              ),
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
                      Text(_locationAge(
                          operationalText('موقعك', 'Your position'),
                          _driverController.currentPosition.value?.timestamp)),
                      if ((_driverController.currentPosition.value?.accuracy ??
                              0) >
                          75)
                        const Text(
                            'الموقع تقريبي · فعّل الموقع الدقيق لتحسين التتبع.'),
                      if (!_followsDestination)
                        Text(_locationAge(
                            operationalText('موقع الراكب', 'Rider position'),
                            _passengerObservedAt)),
                      const SizedBox(height: 6),
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
                          onPressed: () {
                            final origin = _driverPosition ?? _origin;
                            if (origin != null)
                              unawaited(_loadRoute(origin, force: true));
                          },
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

  String _locationAge(String label, DateTime? observed) {
    if (observed == null)
      return operationalText('$label: لا يتوفر تحديث موقع موثوق.',
          '$label: no verified location update.');
    final seconds = DateTime.now()
        .toUtc()
        .difference(observed.toUtc())
        .inSeconds
        .clamp(0, 2147483647);
    return operationalText(
        '$label: آخر تحديث منذ $seconds ثانية. الخريطة تعرض آخر موقع مستلم.',
        '$label: last update $seconds seconds ago. The map shows the last received position.');
  }

  IconData _maneuverIcon(String maneuver) {
    final value = maneuver.toUpperCase();
    if (value.contains('LEFT')) return Icons.turn_left_rounded;
    if (value.contains('RIGHT')) return Icons.turn_right_rounded;
    if (value.contains('UTURN')) return Icons.u_turn_left_rounded;
    return Icons.straight_rounded;
  }

  double _number(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('${value ?? ''}') ?? 0;

  LatLng? _coordinates(Object? latitude, Object? longitude) {
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionWorker.dispose();
    _passengerLocationWorker.dispose();
    _rideWorker.dispose();
    _markerAnimation.dispose();
    _markerFrameRevision.dispose();
    _locationAgeTimer?.cancel();
    super.dispose();
  }
}
