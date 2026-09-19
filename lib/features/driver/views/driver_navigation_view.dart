import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../shared/widgets/app_google_map.dart';
import '../../ride/location_selection/repositories/route_repository.dart';

/// In-app navigation preview for the assigned driver's pickup or destination.
/// It deliberately keeps the driver in YemenDrive; external Maps is not opened.
class DriverNavigationView extends StatefulWidget {
  const DriverNavigationView({super.key});

  @override
  State<DriverNavigationView> createState() => _DriverNavigationViewState();
}

class _DriverNavigationViewState extends State<DriverNavigationView> {
  late final LatLng _origin;
  late final LatLng _destination;
  late final String _title;
  final _routeRepository = ApiRoutesRepository(Get.find());
  Set<Polyline> _polylines = const <Polyline>{};
  bool _loading = true;
  String? _error;
  int? _distanceMeters;
  int? _durationSeconds;

  @override
  void initState() {
    super.initState();
    final data = Map<Object?, Object?>.from((Get.arguments as Map?) ?? const <Object?, Object?>{});
    _origin = LatLng(_number(data['originLatitude']), _number(data['originLongitude']));
    _destination = LatLng(_number(data['destinationLatitude']), _number(data['destinationLongitude']));
    _title = '${data['title'] ?? 'مسار الرحلة'}';
    _loadRoute();
  }

  Future<void> _loadRoute() async {
    setState(() { _loading = true; _error = null; });
    try {
      final route = await _routeRepository.getDrivingRoute(origin: _origin, destination: _destination);
      if (!mounted) return;
      setState(() {
        _distanceMeters = route.distanceMeters;
        _durationSeconds = route.durationSeconds;
        _polylines = <Polyline>{Polyline(polylineId: const PolylineId('driver-route'), points: route.points, color: Theme.of(context).colorScheme.primary, width: 6)};
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'تعذر تحميل مسار القيادة الآن.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_title)),
    body: Stack(children: [
      AppGoogleMap(
        initialTarget: _destination,
        initialZoom: 14,
        myLocationEnabled: true,
        showDemoMarker: false,
        markers: <Marker>{
          Marker(markerId: const MarkerId('driver'), position: _origin, icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure), infoWindow: const InfoWindow(title: 'موقعك')),
          Marker(markerId: const MarkerId('target'), position: _destination, infoWindow: InfoWindow(title: _title)),
        },
        polylines: _polylines,
      ),
      Positioned(
        right: 16, left: 16, bottom: 20,
        child: Card(child: Padding(
          padding: const EdgeInsets.all(14),
          child: _loading ? const Row(children: [CircularProgressIndicator(), SizedBox(width: 12), Text('جارٍ حساب المسار…')])
              : _error != null ? Row(children: [Expanded(child: Text(_error!)), TextButton(onPressed: _loadRoute, child: const Text('إعادة المحاولة'))])
              : Row(children: [const Icon(Icons.route_rounded), const SizedBox(width: 10), Expanded(child: Text('${(_distanceMeters! / 1000).toStringAsFixed(1)} كم · ${(_durationSeconds! / 60).ceil()} دقيقة', style: const TextStyle(fontWeight: FontWeight.bold)))]),
        )),
      ),
    ]),
  );

  double _number(Object? value) => value is num ? value.toDouble() : double.tryParse('${value ?? ''}') ?? 0;
}
