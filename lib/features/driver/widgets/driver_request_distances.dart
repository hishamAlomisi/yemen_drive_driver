import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/services/startup_connection_service.dart';
import '../controllers/driver_controller.dart';
import '../models/driver_request_route.dart';
import '../repositories/route_repository.dart';

class DriverRequestDistances extends StatefulWidget {
  const DriverRequestDistances({required this.ride, super.key});
  final Map<String, Object?> ride;

  @override
  State<DriverRequestDistances> createState() => _DriverRequestDistancesState();
}

class _DriverRequestDistancesState extends State<DriverRequestDistances> {
  late final DriverController _driver;
  late final Worker _positionWorker;
  LatLng? _pickup;
  LatLng? _destination;
  LatLng? _origin;
  DateTime? _pickupRequestedAt;
  Future<DrivingRoute>? _tripRoute;
  Future<DrivingRoute>? _pickupRoute;
  StreamSubscription<void>? _connectionRecovery;

  @override
  void initState() {
    super.initState();
    _driver = Get.find<DriverController>();
    _syncRide();
    _positionWorker = ever<Position?>(_driver.currentPosition, (_) {
      if (mounted) setState(() => _syncPosition());
    });
    if (Get.isRegistered<StartupConnectionService>()) {
      _connectionRecovery =
          Get.find<StartupConnectionService>().recovered.listen((_) {
        if (!mounted) return;
        setState(() {
          if (_pickup != null && _destination != null) {
            _tripRoute = _driver.requestRouteCache
                .route(_pickup!, _destination!, retry: true);
            _tripRoute?.ignore();
          }
          _syncPosition(retry: true);
        });
      });
    }
  }

  @override
  void didUpdateWidget(covariant DriverRequestDistances oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncRide();
  }

  void _syncRide() {
    final pickup = requestCoordinates(
        widget.ride['pickupLatitude'], widget.ride['pickupLongitude']);
    final destination = requestCoordinates(widget.ride['destinationLatitude'],
        widget.ride['destinationLongitude']);
    if (pickup != _pickup || destination != _destination) {
      _tripRoute = pickup == null || destination == null
          ? null
          : _driver.requestRouteCache.route(pickup, destination);
      // FutureBuilder will attach on the next frame, before async failures.
      _tripRoute?.ignore();
      if (pickup != _pickup) {
        _origin = null;
        _pickupRoute = null;
      }
      _pickup = pickup;
      _destination = destination;
    }
    _syncPosition();
  }

  void _syncPosition({bool retry = false}) {
    final origin = currentRequestOrigin(_driver.currentPosition.value);
    final pickup = _pickup;
    if (origin == null || pickup == null) {
      _origin = null;
      _pickupRoute = null;
      return;
    }
    final previous = _origin;
    if (!retry && previous != null) {
      final moved = Geolocator.distanceBetween(previous.latitude,
          previous.longitude, origin.latitude, origin.longitude);
      if (moved < 100 ||
          (_pickupRequestedAt != null &&
              DateTime.now().difference(_pickupRequestedAt!) <
                  const Duration(seconds: 15))) return;
    }
    _origin = origin;
    _pickupRequestedAt = DateTime.now();
    _pickupRoute =
        _driver.requestRouteCache.route(origin, pickup, retry: retry);
    _pickupRoute?.ignore();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _distance(
            label: 'من الانطلاق إلى الوجهة',
            icon: Icons.route_outlined,
            future: _tripRoute,
            missing: 'إحداثيات المسار غير متاحة',
            retry: () => setState(() {
              _tripRoute = _driver.requestRouteCache
                  .route(_pickup!, _destination!, retry: true);
            }),
          ),
          const SizedBox(height: 5),
          _distance(
            label: 'من موقعك إلى الانطلاق',
            icon: Icons.near_me_outlined,
            future: _pickupRoute,
            missing: _pickup == null
                ? 'إحداثيات الانطلاق غير متاحة'
                : 'بانتظار موقعك الحالي بدقة مناسبة',
            retry: () => setState(() => _syncPosition(retry: true)),
          ),
        ]),
      );

  Widget _distance({
    required String label,
    required IconData icon,
    required Future<DrivingRoute>? future,
    required String missing,
    required VoidCallback retry,
  }) =>
      FutureBuilder<DrivingRoute>(
        future: future,
        builder: (context, snapshot) {
          final route = snapshot.connectionState == ConnectionState.done
              ? snapshot.data
              : null;
          final failed = future != null &&
              snapshot.connectionState == ConnectionState.done &&
              snapshot.hasError;
          final value = future == null
              ? missing
              : failed
                  ? 'المسافة غير متاحة'
                  : route == null
                      ? 'جارٍ حساب المسافة…'
                      : '${requestDistanceText(route.distanceMeters)} بالطريق';
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
                child: Text('$label: $value',
                    style: Theme.of(context).textTheme.bodySmall)),
            if (failed)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'إعادة حساب المسافة',
                onPressed: retry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
          ]);
        },
      );

  @override
  void dispose() {
    _connectionRecovery?.cancel();
    _positionWorker.dispose();
    super.dispose();
  }
}
