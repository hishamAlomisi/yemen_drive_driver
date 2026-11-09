import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/services/startup_connection_service.dart';
import '../../../shared/widgets/app_google_map.dart';
import '../../../shared/widgets/live_tracking_marker_icons.dart';
import '../controllers/driver_controller.dart';
import '../models/driver_map_motion.dart';
import '../models/driver_request_route.dart';
import '../repositories/route_repository.dart';

/// A request preview always draws pickup to destination, independent of the
/// driver's current location or whether an offer has been submitted.
class DriverRequestRouteView extends StatefulWidget {
  const DriverRequestRouteView({
    required this.ride,
    required this.cache,
    required this.pickup,
    required this.destination,
    this.driverOrigin,
    super.key,
  });

  final Map<String, Object?> ride;
  final DriverRequestRouteCache cache;
  final LatLng pickup;
  final LatLng destination;
  final LatLng? driverOrigin;

  @override
  State<DriverRequestRouteView> createState() => _DriverRequestRouteViewState();
}

class _DriverRequestRouteViewState extends State<DriverRequestRouteView> {
  GoogleMapController? _map;
  DrivingRoute? _trip;
  DrivingRoute? _approach;
  bool _loadingTrip = true;
  bool _loadingApproach = false;
  bool _tripFailed = false;
  bool _approachFailed = false;
  StreamSubscription<void>? _connectionRecovery;
  BitmapDescriptor? _pickupIcon;
  BitmapDescriptor? _destinationIcon;
  BitmapDescriptor? _driverIcon;
  double _driverBearing = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMarkerIcons());
    if (Get.isRegistered<DriverController>()) {
      final position = Get.find<DriverController>().currentPosition.value;
      if (position != null) {
        _driverBearing = DriverMapMotion.heading(null, position, 0);
      }
    }
    unawaited(_loadTrip());
    if (widget.driverOrigin != null) unawaited(_loadApproach());
    if (Get.isRegistered<StartupConnectionService>()) {
      _connectionRecovery =
          Get.find<StartupConnectionService>().recovered.listen((_) {
        if (!mounted) return;
        if (_tripFailed) unawaited(_loadTrip(retry: true));
        if (_approachFailed) unawaited(_loadApproach(retry: true));
      });
    }
  }

  Future<void> _loadMarkerIcons() async {
    try {
      final icons = await Future.wait([
        LiveTrackingMarkerIcons.buildStop(
            destination: false, label: 'نقطة الانطلاق'),
        LiveTrackingMarkerIcons.buildStop(destination: true, label: 'الوجهة'),
        LiveTrackingMarkerIcons.build(inProgress: false),
      ]);
      if (!mounted) return;
      setState(() {
        _pickupIcon = icons[0];
        _destinationIcon = icons[1];
        _driverIcon = icons[2];
      });
    } on Object {
      // Preserve the positions if the native bitmap could not be loaded.
    }
  }

  Future<void> _loadTrip({bool retry = false}) async {
    setState(() {
      _loadingTrip = true;
      _tripFailed = false;
    });
    try {
      final route = await widget.cache
          .route(widget.pickup, widget.destination, retry: retry);
      if (!mounted) return;
      setState(() => _trip = route);
      _fitRoute();
    } catch (_) {
      if (mounted) setState(() => _tripFailed = true);
    } finally {
      if (mounted) setState(() => _loadingTrip = false);
    }
  }

  Future<void> _loadApproach({bool retry = false}) async {
    final origin = widget.driverOrigin;
    if (origin == null) return;
    setState(() {
      _loadingApproach = true;
      _approachFailed = false;
    });
    try {
      final route =
          await widget.cache.route(origin, widget.pickup, retry: retry);
      if (!mounted) return;
      setState(() => _approach = route);
      _fitRoute();
    } catch (_) {
      if (mounted) setState(() => _approachFailed = true);
    } finally {
      if (mounted) setState(() => _loadingApproach = false);
    }
  }

  void _fitRoute() {
    final map = _map;
    if (map == null) return;
    final points = <LatLng>[
      widget.pickup,
      widget.destination,
      if (widget.driverOrigin != null) widget.driverOrigin!,
      ...?_trip?.points,
      ...?_approach?.points,
    ];
    var south = points.first.latitude;
    var north = south;
    var west = points.first.longitude;
    var east = west;
    for (final point in points.skip(1)) {
      if (point.latitude < south) south = point.latitude;
      if (point.latitude > north) north = point.latitude;
      if (point.longitude < west) west = point.longitude;
      if (point.longitude > east) east = point.longitude;
    }
    unawaited(map
        .animateCamera(CameraUpdate.newLatLngBounds(
            LatLngBounds(
                southwest: LatLng(south, west), northeast: LatLng(north, east)),
            48))
        .catchError((Object _) {}));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('عرض مسار الرحلة')),
        body: Column(children: [
          Expanded(
            child: AppGoogleMap(
              initialTarget: widget.pickup,
              onMapCreated: (map) {
                _map = map;
                _fitRoute();
              },
              markers: {
                Marker(
                  markerId: const MarkerId('request-pickup'),
                  position: widget.pickup,
                  infoWindow: const InfoWindow(title: 'نقطة الانطلاق'),
                  anchor: LiveTrackingMarkerIcons.stopAnchor,
                  icon: _pickupIcon ??
                      BitmapDescriptor.defaultMarkerWithHue(
                          BitmapDescriptor.hueAzure),
                ),
                Marker(
                  markerId: const MarkerId('request-destination'),
                  position: widget.destination,
                  infoWindow: const InfoWindow(title: 'الوجهة'),
                  anchor: LiveTrackingMarkerIcons.stopAnchor,
                  icon: _destinationIcon ??
                      BitmapDescriptor.defaultMarkerWithHue(
                          BitmapDescriptor.hueAzure),
                ),
                if (widget.driverOrigin != null)
                  Marker(
                    markerId: const MarkerId('request-driver'),
                    position: widget.driverOrigin!,
                    infoWindow:
                        const InfoWindow(title: 'موقعك عند فتح المعاينة'),
                    rotation: _driverBearing,
                    flat: true,
                    anchor: const Offset(0.5, 0.5),
                    icon: _driverIcon ??
                        BitmapDescriptor.defaultMarkerWithHue(
                            BitmapDescriptor.hueAzure),
                  ),
              },
              polylines: {
                if (_approach != null)
                  Polyline(
                    polylineId: const PolylineId('request-approach'),
                    points: _approach!.points,
                    color: Colors.blue.shade700,
                    width: 4,
                  ),
                if (_trip != null)
                  Polyline(
                    polylineId: const PolylineId('request-trip'),
                    points: _trip!.points,
                    color: Colors.green.shade700,
                    width: 5,
                  ),
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                        '${widget.ride['pickupDisplayName'] ?? widget.ride['pickupAddress'] ?? 'الانطلاق'} ← '
                        '${widget.ride['destinationDisplayName'] ?? widget.ride['destinationAddress'] ?? 'الوجهة'}'),
                    const SizedBox(height: 8),
                    _leg(
                      'من الانطلاق إلى الوجهة',
                      _trip,
                      color: Colors.green.shade700,
                      loading: _loadingTrip,
                      failed: _tripFailed,
                      retry: () => _loadTrip(retry: true),
                    ),
                    const SizedBox(height: 6),
                    if (widget.driverOrigin != null)
                      _leg(
                        'من موقعك إلى الانطلاق',
                        _approach,
                        color: Colors.blue.shade700,
                        loading: _loadingApproach,
                        failed: _approachFailed,
                        retry: () => _loadApproach(retry: true),
                      )
                    else
                      const Text(
                          'تحتاج مسافة الوصول إلى الانطلاق إلى موقعك الحالي بدقة مناسبة.'),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('العودة إلى الطلب وتقديم العرض'),
                    ),
                  ]),
            ),
          ),
        ]),
      );

  Widget _leg(
    String title,
    DrivingRoute? route, {
    required Color color,
    required bool loading,
    required bool failed,
    required VoidCallback retry,
  }) =>
      Row(children: [
        Icon(Icons.route, color: color, size: 18),
        const SizedBox(width: 8),
        Expanded(
            child: Text(
                '$title: ${loading ? 'جارٍ تحميل المسار…' : failed ? 'تعذر تحميل مسار الطريق' : route == null ? 'غير متاح' : '${requestDistanceText(route.distanceMeters)} · ${(route.durationSeconds / 60).ceil()} دقيقة'}')),
        if (failed)
          TextButton(onPressed: retry, child: const Text('إعادة المحاولة')),
      ]);

  @override
  void dispose() {
    _connectionRecovery?.cancel();
    // AppGoogleMap owns its native controller.
    _map = null;
    super.dispose();
  }
}
