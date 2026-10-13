import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/config/app_environment.dart';
import '../../../core/realtime/tracking_hub_service.dart';
import '../../../core/services/auth_session_service.dart';
import '../../../core/services/connectivity_service.dart';
import '../../../core/services/ride_preferences.dart';
import '../../account/account_routes.dart';
import '../home/repositories/service_kind_repository.dart';
import '../negotiation/repositories/ride_negotiation_repository.dart';
import '../vehicle_selection/repositories/service_catalog_repository.dart';
import '../models/ride_models.dart';
import '../models/service_kind_models.dart';
import '../ride_routes.dart';
import '../location_selection/controllers/location_selection_controller.dart';

class RideController extends GetxController {
  RideController(this._repository, this._session,
      [this._catalogRepository, ServiceKindRepository? serviceKinds])
      : _serviceKinds = serviceKinds;

  // Render at 3x and display as a balanced 28x36 logical marker.
  static const int _driverMarkerWidth = 84;
  static const int _driverMarkerHeight = 108;
  static const double _driverMarkerBaseWidth = 56;
  static const double _driverMarkerBaseHeight = 72;
  static const double _driverMarkerPixelRatio = 3;

  final RideNegotiationRepository _repository;
  final AuthSessionService _session;
  final ServiceCatalogRepository? _catalogRepository;
  final ServiceKindRepository? _serviceKinds;
  final Rx<RideServiceType> serviceType = RideServiceType.transport.obs;
  final RxnInt selectedServiceKindId = RxnInt();
  final Rx<RideVehicleType> selectedTransport = RideVehicleType.car.obs;
  final RxBool hasSelectedTransport = false.obs;
  final Rxn<RideVehicle> selectedVehicle = Rxn<RideVehicle>();
  final RxList<RideVehicle> catalogVehicles = <RideVehicle>[].obs;
  final RxBool isCatalogLoading = false.obs;
  final RxString catalogError = ''.obs;
  final RxBool isUsingCatalogFallback = true.obs;
  final RxInt bottomNavigationIndex = 0.obs;
  final RxInt homeServiceIndex = (-1).obs;
  final RxList<RideHomeService> homeServices =
      <RideHomeService>[...demoHomeServices].obs;
  final RxBool autoStartTransport = RidePreferences.autoStartTransport.obs;
  final RxBool isSearchingForDriver = false.obs;
  final RxBool isDriverAssigned = false.obs;
  final RxString cancellationReason = ''.obs;
  final Rx<NegotiationStatus> negotiationStatus = NegotiationStatus.idle.obs;
  final Rxn<RideQuote> quote = Rxn<RideQuote>();
  final Rxn<RideRequestDraft> currentDraft = Rxn<RideRequestDraft>();
  final Rxn<DriverOffer> acceptedOffer = Rxn<DriverOffer>();
  final RxDouble offeredPrice = 0.0.obs;
  final RxList<DriverOffer> driverOffers = <DriverOffer>[].obs;
  final RxSet<String> removingOfferIds = <String>{}.obs;
  final RxBool offersExhausted = false.obs;
  final RxBool offersStreamDone = false.obs;
  final RxInt receivedOffersCount = 0.obs;
  final RxList<NearbyDriver> nearbyDrivers = <NearbyDriver>[].obs;

  /// Drivers that have received the current request, ordered by arrival.
  final RxList<NearbyDriver> requestRecipients = <NearbyDriver>[].obs;
  final Rxn<NearbyDriver> selectedNearbyDriver = Rxn<NearbyDriver>();
  final Rxn<BitmapDescriptor> _nearbyDriverIcon = Rxn<BitmapDescriptor>();
  final Rxn<DriverTrackingSnapshot> trackedDriver =
      Rxn<DriverTrackingSnapshot>();
  final Rxn<RideCoordinate> trackedPassenger = Rxn<RideCoordinate>();
  StreamSubscription<TrackingHubEvent>? _hubEventSubscription;
  StreamSubscription<void>? _hubConnectionSubscription;
  Timer? _trackingTimer;
  Timer? _recipientTimer;
  Timer? _offersDeadlineTimer;
  StreamSubscription<Position>? _passengerPositionSubscription;
  String? _requestId;
  bool _isResumingRequest = false;
  int _catalogRequestId = 0;
  bool hasShownTripSharePrompt = false;

  @override
  void onInit() {
    super.onInit();
    if (!AppEnvironment.useDemoData) {
      homeServices.clear();
    }
    unawaited(loadServiceCatalog());
    unawaited(_loadHomeServices());
    if (Get.isRegistered<TrackingHubService>()) {
      final hub = Get.find<TrackingHubService>();
      _hubEventSubscription = hub.events.listen(_handleHubEvent);
      _hubConnectionSubscription = hub.connectionRestored.listen((_) {
        final rideId = _requestId;
        if (rideId != null && isSearchingForDriver.value) {
          unawaited(_refreshOffersSnapshotSafely(rideId));
        }
      });
    }
  }

  Future<void> _loadHomeServices() async {
    final serviceKinds = _serviceKinds;
    if (serviceKinds == null || AppEnvironment.useDemoData) return;
    try {
      final values = await serviceKinds.getServices();
      homeServices.assignAll(values);
    } catch (_) {}
  }

  Future<void> setAutoStartTransport(bool value) async {
    autoStartTransport.value = value;
    await RidePreferences.setAutoStartTransport(value);
  }

  List<RideVehicle> get vehicles =>
      isUsingCatalogFallback.value ? _fallbackVehicles : catalogVehicles;

  List<RideVehicleType> get availableVehicleTypes {
    final types = <RideVehicleType>{
      for (final vehicle in vehicles) vehicle.type,
    };
    return RideVehicleType.values.where(types.contains).toList(growable: false);
  }

  List<RideVehicle> get _fallbackVehicles {
    if (serviceType.value != RideServiceType.delivery) {
      return demoRideVehicles;
    }
    final deliveryVehicles = demoRideVehicles
        .where(
          (vehicle) =>
              vehicle.type == RideVehicleType.bike ||
              vehicle.type == RideVehicleType.cycle,
        )
        .toList(growable: false);
    return deliveryVehicles.isEmpty ? demoRideVehicles : deliveryVehicles;
  }

  Future<void> loadServiceCatalog({int? requestedKindId}) async {
    final targetKindId = requestedKindId ?? selectedServiceKindId.value;
    final requestId = ++_catalogRequestId;
    catalogError.value = '';

    if (!_canUseCatalogApi || targetKindId == null) {
      catalogVehicles.clear();
      isUsingCatalogFallback.value = AppEnvironment.useDemoData;
      return;
    }

    isUsingCatalogFallback.value = false;
    isCatalogLoading.value = true;
    try {
      final services = await _catalogRepository!.getServices(
        serviceKindId: targetKindId,
      );
      if (requestId != _catalogRequestId ||
          targetKindId != selectedServiceKindId.value) {
        return;
      }
      if (services.isEmpty) {
        catalogVehicles.clear();
        isUsingCatalogFallback.value = false;
        catalogError.value = 'لا توجد خدمات متاحة لهذا النوع حاليًا.';
      } else {
        catalogVehicles.assignAll(services);
        isUsingCatalogFallback.value = false;
      }
    } catch (_) {
      if (requestId != _catalogRequestId ||
          targetKindId != selectedServiceKindId.value) {
        return;
      }
      catalogVehicles.clear();
      isUsingCatalogFallback.value = AppEnvironment.useDemoData;
      catalogError.value = 'تعذّر تحميل الخدمات، تم عرض الخيارات المحفوظة.';
    } finally {
      if (requestId == _catalogRequestId) {
        isCatalogLoading.value = false;
      }
    }
  }

  bool get _canUseCatalogApi =>
      _catalogRepository != null &&
      AppEnvironment.isConfigured &&
      !AppEnvironment.useDemoData &&
      !AppEnvironment.baseUrl.contains('example.com');

  Set<Marker> nearbyDriverMarkersFor({
    required ValueChanged<NearbyDriver> onTap,
  }) =>
      nearbyDrivers
          .map(
            (driver) => Marker(
              markerId: MarkerId('nearby-${driver.id}'),
              position: LatLng(
                driver.location.latitude,
                driver.location.longitude,
              ),
              anchor: const Offset(.5, 1),
              onTap: () => onTap(driver),
              icon: _nearbyDriverIcon.value ??
                  BitmapDescriptor.defaultMarkerWithHue(
                    BitmapDescriptor.hueAzure,
                  ),
            ),
          )
          .toSet();

  Set<Marker> get trackingMarkers => <Marker>{
        if (trackedDriver.value != null)
          Marker(
            markerId: const MarkerId('tracked-driver'),
            position: LatLng(
              trackedDriver.value!.location.latitude,
              trackedDriver.value!.location.longitude,
            ),
            rotation: trackedDriver.value!.heading ?? 0,
            flat: true,
            infoWindow: const InfoWindow(title: 'السائق'),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueAzure,
            ),
          ),
        if (trackedPassenger.value != null)
          Marker(
            markerId: const MarkerId('tracked-passenger'),
            position: LatLng(
              trackedPassenger.value!.latitude,
              trackedPassenger.value!.longitude,
            ),
            infoWindow: const InfoWindow(title: 'موقعي الحالي'),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueOrange,
            ),
          ),
      };

  void loadDemoNearbyDrivers({LatLng? center}) {
    _loadDemoDriverIcon();
    final location = Get.find<LocationController>();
    final origin = center ?? location.pickup.value;
    if (origin == null) {
      nearbyDrivers.clear();
      return;
    }
    // Keep demo drivers deterministic and close enough to fit in one map view.
    final distancesKm = <double>[.18, .32, .48, .65, .82, 1.0, 1.18, 1.4];
    final bearings = <double>[0, 45, 90, 135, 180, 225, 270, 315];
    LatLng nearbyPoint(int index) {
      final distanceMeters = distancesKm[index] * 1000;
      final bearing = bearings[index] * math.pi / 180;
      final latitudeDelta = distanceMeters * math.cos(bearing) / 111320.0;
      final longitudeScale = 111320.0 *
          math.cos(origin.latitude * math.pi / 180).abs().clamp(.2, 1.0);
      final longitudeDelta =
          distanceMeters * math.sin(bearing) / longitudeScale;
      return LatLng(
        origin.latitude + latitudeDelta,
        origin.longitude + longitudeDelta,
      );
    }

    nearbyDrivers.assignAll(<NearbyDriver>[
      NearbyDriver(
        id: 'nearby-1',
        name: 'محمد علي',
        location: RideCoordinate(
          latitude: nearbyPoint(0).latitude,
          longitude: nearbyPoint(0).longitude,
        ),
        photoUrl: '',
        vehicleType: RideVehicleType.car,
        rating: 4.9,
        vehicleModel: 'Toyota Yaris 2023',
        plateNumber: '01 - 45872',
        completedTrips: 1248,
      ),
      NearbyDriver(
        id: 'nearby-2',
        name: 'أحمد صالح',
        location: RideCoordinate(
          latitude: nearbyPoint(1).latitude,
          longitude: nearbyPoint(1).longitude,
        ),
        photoUrl: '',
        vehicleType: RideVehicleType.taxi,
        rating: 4.8,
        vehicleModel: 'Hyundai Accent 2022',
        plateNumber: '01 - 79314',
        completedTrips: 936,
      ),
      NearbyDriver(
        id: 'nearby-3',
        name: 'عبدالله حسن',
        location: RideCoordinate(
          latitude: nearbyPoint(2).latitude,
          longitude: nearbyPoint(2).longitude,
        ),
        photoUrl: '',
        vehicleType: RideVehicleType.car,
        rating: 4.7,
        vehicleModel: 'Kia Rio 2021',
        plateNumber: '01 - 32689',
        completedTrips: 711,
      ),
      NearbyDriver(
        id: 'nearby-4',
        name: 'خالد محمد',
        location: RideCoordinate(
          latitude: nearbyPoint(3).latitude,
          longitude: nearbyPoint(3).longitude,
        ),
        photoUrl: '',
        vehicleType: RideVehicleType.taxi,
        rating: 4.6,
        vehicleModel: 'Toyota Corolla 2022',
        plateNumber: '01 - 61428',
        completedTrips: 602,
      ),
      NearbyDriver(
        id: 'nearby-5',
        name: 'سامر أحمد',
        location: RideCoordinate(
          latitude: nearbyPoint(4).latitude,
          longitude: nearbyPoint(4).longitude,
        ),
        photoUrl: '',
        vehicleType: RideVehicleType.car,
        rating: 4.5,
        vehicleModel: 'Hyundai Elantra 2021',
        plateNumber: '01 - 78215',
        completedTrips: 488,
      ),
      NearbyDriver(
        id: 'nearby-6',
        name: 'مازن علي',
        location: RideCoordinate(
          latitude: nearbyPoint(5).latitude,
          longitude: nearbyPoint(5).longitude,
        ),
        photoUrl: '',
        vehicleType: RideVehicleType.car,
        rating: 4.4,
        vehicleModel: 'Kia Cerato 2020',
        plateNumber: '01 - 29541',
        completedTrips: 371,
      ),
      NearbyDriver(
        id: 'nearby-7',
        name: 'ياسر عبدالله',
        location: RideCoordinate(
          latitude: nearbyPoint(6).latitude,
          longitude: nearbyPoint(6).longitude,
        ),
        photoUrl: '',
        vehicleType: RideVehicleType.taxi,
        rating: 4.3,
        vehicleModel: 'Suzuki Dzire 2022',
        plateNumber: '01 - 83672',
        completedTrips: 295,
      ),
      NearbyDriver(
        id: 'nearby-8',
        name: 'فارس حسن',
        location: RideCoordinate(
          latitude: nearbyPoint(7).latitude,
          longitude: nearbyPoint(7).longitude,
        ),
        photoUrl: '',
        vehicleType: RideVehicleType.car,
        rating: 4.2,
        vehicleModel: 'Toyota Vitz 2020',
        plateNumber: '01 - 94713',
        completedTrips: 214,
      ),
    ]);
  }

  void closeNearbyDriverCard() => selectedNearbyDriver.value = null;

  void selectNearbyDriver(NearbyDriver driver) {
    if (selectedNearbyDriver.value?.id == driver.id) return;
    selectedNearbyDriver.value = driver;
  }

  Future<void> _loadDemoDriverIcon() async {
    try {
      final bytes = await rootBundle.load(
        'assets/images/branding/yemen_drive_logo.png',
      );
      final codec = await ui.instantiateImageCodec(
        bytes.buffer.asUint8List(),
        targetWidth: 48,
        targetHeight: 48,
      );
      final frame = await codec.getNextFrame();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final paint = ui.Paint()..isAntiAlias = true;
      canvas.scale(
        _driverMarkerWidth / _driverMarkerBaseWidth,
        _driverMarkerHeight / _driverMarkerBaseHeight,
      );

      final shadowPath = _driverMarkerPath(const ui.Offset(0, 3));
      canvas.drawPath(
        shadowPath,
        ui.Paint()
          ..isAntiAlias = true
          ..color = const ui.Color(0x45000000),
      );

      final markerPath = _driverMarkerPath(ui.Offset.zero);
      canvas.drawPath(
        markerPath,
        paint..color = const ui.Color(0xFFFFA000),
      );
      canvas.drawPath(
        markerPath,
        ui.Paint()
          ..isAntiAlias = true
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const ui.Color(0xFFFFFFFF),
      );

      const photoBounds = ui.Rect.fromLTWH(7, 6, 42, 42);
      canvas.drawOval(
        photoBounds.inflate(3),
        ui.Paint()
          ..isAntiAlias = true
          ..color = const ui.Color(0xFFFFFFFF),
      );
      canvas.save();
      canvas.clipPath(ui.Path()..addOval(photoBounds));
      canvas.drawImageRect(
        frame.image,
        ui.Rect.fromLTWH(
          0,
          0,
          frame.image.width.toDouble(),
          frame.image.height.toDouble(),
        ),
        photoBounds,
        paint,
      );
      canvas.restore();
      final image = await recorder.endRecording().toImage(
            _driverMarkerWidth,
            _driverMarkerHeight,
          );
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data != null) {
        _nearbyDriverIcon.value = BitmapDescriptor.bytes(
          Uint8List.sublistView(data),
          imagePixelRatio: _driverMarkerPixelRatio,
        );
      }
    } catch (_) {}
  }

  ui.Path _driverMarkerPath(ui.Offset offset) => ui.Path()
    ..moveTo(28 + offset.dx, 68 + offset.dy)
    ..cubicTo(
      24 + offset.dx,
      62 + offset.dy,
      2 + offset.dx,
      52 + offset.dy,
      2 + offset.dx,
      30 + offset.dy,
    )
    ..cubicTo(
      2 + offset.dx,
      14 + offset.dy,
      13 + offset.dx,
      3 + offset.dy,
      28 + offset.dx,
      3 + offset.dy,
    )
    ..cubicTo(
      43 + offset.dx,
      3 + offset.dy,
      54 + offset.dx,
      14 + offset.dy,
      54 + offset.dx,
      30 + offset.dy,
    )
    ..cubicTo(
      54 + offset.dx,
      52 + offset.dy,
      32 + offset.dx,
      62 + offset.dy,
      28 + offset.dx,
      68 + offset.dy,
    )
    ..close();

  void startDemoTracking() {
    _trackingTimer?.cancel();
    final location = Get.find<LocationController>();
    final points = location.routePoints.isNotEmpty
        ? location.routePoints.toList(growable: false)
        : <LatLng>[
            location.pickup.value ?? const LatLng(15.3694, 44.1910),
            location.destination.value ?? const LatLng(15.3567, 44.2066),
          ];
    var index = 0;
    trackedPassenger.value = RideCoordinate(
      latitude: points.first.latitude,
      longitude: points.first.longitude,
    );
    _startPassengerPositionTracking();
    _trackingTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      if (points.isEmpty) return;
      final point = points[index.clamp(0, points.length - 1)];
      trackedDriver.value = DriverTrackingSnapshot(
        driverId: 'demo-driver',
        location: RideCoordinate(
          latitude: point.latitude,
          longitude: point.longitude,
        ),
        heading:
            index + 1 < points.length ? _bearing(point, points[index + 1]) : 0,
        updatedAt: DateTime.now(),
      );
      trackedPassenger.value = RideCoordinate(
        latitude: point.latitude,
        longitude: point.longitude,
      );
      if (index < points.length - 1) index++;
    });
  }

  Future<void> _startPassengerPositionTracking() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      await _passengerPositionSubscription?.cancel();
      _passengerPositionSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 5,
        ),
      ).listen((position) {
        trackedPassenger.value = RideCoordinate(
          latitude: position.latitude,
          longitude: position.longitude,
        );
      });
    } catch (_) {
      // Demo tracking remains active when a device does not provide location.
    }
  }

  double _bearing(LatLng from, LatLng to) {
    final deltaLongitude = to.longitude - from.longitude;
    return (deltaLongitude >= 0 ? 90 : 270).toDouble();
  }

  void selectService(RideServiceType value) {
    // The catalog is loaded once during controller initialization and again
    // only when the selected service type actually changes. Views consume the
    // cached [catalogVehicles] through [vehicles] and never call the API.
    if (serviceType.value == value) return;
    serviceType.value = value;
    catalogVehicles.clear();
    selectedVehicle.value = null;
    hasSelectedTransport.value = false;
    unawaited(loadServiceCatalog());
  }

  Future<void> startHomeService() async {
    final connectivity = Get.find<ConnectivityService>();
    if (!await connectivity.refresh()) {
      Get.snackbar(
        'لا يوجد اتصال بالإنترنت',
        'اتصل بالإنترنت ثم حاول اختيار الخدمة مرة أخرى.',
      );
      return;
    }
    if (AppEnvironment.useDemoData) loadDemoNearbyDrivers();
    hasSelectedTransport.value = false;
    final selected = homeServiceIndex.value >= 0 &&
            homeServiceIndex.value < homeServices.length
        ? homeServices[homeServiceIndex.value]
        : null;
    if (selected?.id != null) {
      selectedServiceKindId.value = selected!.id;
      unawaited(loadServiceCatalog(requestedKindId: selected.id));
      Get.toNamed<void>(RideRoutes.locationPicker);
    } else if (selected != null) {
      Get.snackbar(selected.name, 'هذا النوع سيُتاح قريبًا.');
    } else {
      switch (homeServiceIndex.value) {
        case 0:
          selectService(RideServiceType.transport);
          Get.toNamed<void>(RideRoutes.locationPicker);
        case 1:
          selectService(RideServiceType.delivery);
          Get.toNamed<void>(RideRoutes.locationPicker);
        case 2:
          Get.toNamed<void>(RideRoutes.locationPicker);
        case 3:
          Get.toNamed<void>(RideRoutes.locationPicker);
        default:
          Get.snackbar('اختر الخدمة', 'حدد نوع الخدمة أولًا للمتابعة.');
      }
    }
  }

  void chooseTransport(RideVehicleType value) {
    selectedTransport.value = value;
    hasSelectedTransport.value = true;
  }

  /// Selects a catalog item returned by the API while keeping the existing
  /// vehicle-type contract used by quote/request endpoints.
  void chooseCatalogVehicle(RideVehicle vehicle) {
    selectedVehicle.value = vehicle;
    chooseTransport(vehicle.type);
  }

  Future<void> selectCatalogVehicle(RideVehicle vehicle) async {
    chooseCatalogVehicle(vehicle);
    await _quoteForSelection(vehicle);
  }

  Future<void> selectTransport(RideVehicleType value) async {
    RideVehicle? vehicle = selectedVehicle.value;
    if (vehicle == null) {
      for (final item in vehicles) {
        if (item.type == value) {
          vehicle = item;
          break;
        }
      }
    }
    if (vehicle == null) {
      Get.snackbar('الخدمة غير مكتملة', 'اختر خدمة من القائمة أولاً.');
      return;
    }
    await _quoteForSelection(vehicle);
  }

  Future<void> _quoteForSelection(RideVehicle vehicle) async {
    if (vehicle.serviceKindId == null || vehicle.serviceCatalogItemId == null) {
      Get.snackbar('الخدمة غير مكتملة', 'بيانات الخدمة غير متاحة من الخادم.');
      return;
    }
    final location = Get.find<LocationController>();
    final pickupPoint = location.pickup.value;
    final destinationPoint = location.destination.value;
    if (pickupPoint == null || destinationPoint == null) {
      Get.snackbar('المسار غير مكتمل', 'حدد نقطة الانطلاق والوجهة أولًا.');
      return;
    }
    chooseCatalogVehicle(vehicle);
    negotiationStatus.value = NegotiationStatus.quoting;
    Get.toNamed<void>(RideRoutes.negotiationQuote);

    final result = await _repository.getQuote(
      serviceKindId: vehicle.serviceKindId!,
      serviceCatalogItemId: vehicle.serviceCatalogItemId!,
      pickup: RideCoordinate(
        latitude: pickupPoint.latitude,
        longitude: pickupPoint.longitude,
      ),
      destination: RideCoordinate(
        latitude: destinationPoint.latitude,
        longitude: destinationPoint.longitude,
      ),
    );

    quote.value = result;
    offeredPrice.value = result.suggestedPrice;
    negotiationStatus.value = NegotiationStatus.ready;
  }

  void increasePrice() => _changePrice(1);
  void decreasePrice() => _changePrice(-1);

  void _changePrice(int direction) {
    final value = quote.value;
    if (value == null) return;
    offeredPrice.value = (offeredPrice.value + value.priceStep * direction)
        .clamp(value.minPrice, value.maxPrice)
        .toDouble();
  }

  Future<void> resumePendingRequestIfNeeded() async {
    final arguments = Get.arguments;
    final shouldResume = arguments is Map && arguments['resumeRequest'] == true;
    if (!shouldResume ||
        !_session.isAuthenticated.value ||
        _isResumingRequest) {
      return;
    }
    _isResumingRequest = true;
    if (quote.value == null) {
      final location = Get.find<LocationController>();
      final pickup = location.pickup.value;
      final destination = location.destination.value;
      if (pickup == null || destination == null) return;
      final vehicle = selectedVehicle.value;
      if (vehicle == null) return;
      await _quoteForSelection(vehicle);
    }
    await requestRide();
  }

  void selectVehicle(RideVehicle vehicle) {
    selectedVehicle.value = vehicle;
    Get.toNamed<void>(RideRoutes.vehicleDetails);
  }

  Future<void> requestRide({bool later = false}) async {
    if (!_session.requireAuthentication(
      returnRoute: RideRoutes.negotiationQuote,
      arguments: <String, Object?>{'resumeRequest': true},
    )) {
      return;
    }
    final location = Get.find<LocationController>();
    final pickupPoint = location.pickup.value;
    final destinationPoint = location.destination.value;
    if (pickupPoint == null || destinationPoint == null) {
      Get.snackbar('المسار غير مكتمل', 'حدد نقطة الانطلاق والوجهة أولًا.');
      return;
    }
    if (quote.value == null) {
      await selectTransport(selectedTransport.value);
      if (quote.value == null) return;
    }
    isSearchingForDriver.value = true;
    hasShownTripSharePrompt = false;
    offersExhausted.value = false;
    offersStreamDone.value = false;
    receivedOffersCount.value = 0;
    requestRecipients.clear();
    _recipientTimer?.cancel();
    var recipientIndex = 0;
    _recipientTimer =
        Timer.periodic(const Duration(milliseconds: 1300), (timer) {
      if (!isSearchingForDriver.value ||
          recipientIndex >= nearbyDrivers.length) {
        timer.cancel();
        return;
      }
      requestRecipients.add(nearbyDrivers[recipientIndex++]);
    });
    removingOfferIds.clear();
    negotiationStatus.value = NegotiationStatus.searching;
    driverOffers.clear();
    final draft = RideRequestDraft(
      customerId: _session.currentUserId.value,
      pickup: 'موقعي الحالي',
      destination: 'الوجهة المحددة',
      pickupCoordinate: RideCoordinate(
        latitude: pickupPoint.latitude,
        longitude: pickupPoint.longitude,
      ),
      destinationCoordinate: RideCoordinate(
        latitude: destinationPoint.latitude,
        longitude: destinationPoint.longitude,
      ),
      serviceKindId: selectedVehicle.value?.serviceKindId ??
          selectedServiceKindId.value ??
          0,
      serviceCatalogItemId: selectedVehicle.value?.serviceCatalogItemId ?? 0,
      offeredPrice: offeredPrice.value,
      pickupAddress: location.fromController.text.trim(),
      destinationAddress: location.toController.text.trim(),
      destinationAddressName: location.addressNameController.text.trim(),
      destinationStreet: location.streetController.text.trim(),
      destinationDetails: location.detailsController.text.trim(),
      idempotencyKey: DateTime.now().microsecondsSinceEpoch.toString(),
    );
    currentDraft.value = draft;
    _requestId = await _repository.createRequest(draft);
    _offersDeadlineTimer?.cancel();
    _offersDeadlineTimer = Timer(const Duration(minutes: 2), () {
      offersStreamDone.value = true;
      _updateOffersExhausted();
    });
    await _watchOffers(_requestId!);
  }

  Future<void> _watchOffers(String requestId) async {
    final rideId = int.tryParse(requestId);
    if (rideId == null || !Get.isRegistered<TrackingHubService>()) return;
    try {
      await Get.find<TrackingHubService>()
          .setRideSubscriptions(<int>{rideId});
      await _refreshOffersSnapshot(requestId);
    } catch (_) {
      Get.snackbar('تعذر تحديث حالة البحث', 'تحقق من الاتصال ثم أعد المحاولة.');
    }
  }

  Future<void> _refreshOffersSnapshot([String? requestId]) async {
    final id = requestId ?? _requestId;
    if (id == null || id != _requestId) return;
    final detail = await _repository.getRideDetail(id);
    if (id != _requestId || !isSearchingForDriver.value) return;
    final rawRide = detail['ride'];
    final ride = rawRide is Map
        ? Map<Object?, Object?>.from(rawRide)
        : const <Object?, Object?>{};
    final status = int.tryParse('${ride['status'] ?? ''}');
    final rawOffers = detail['offers'];
    final allOffers = rawOffers is List
        ? rawOffers
            .whereType<Map<Object?, Object?>>()
            .map((item) => Map<String, Object?>.from(item))
            .map(_repository.mapRealtimeOffer)
            .whereType<DriverOffer>()
            .toList(growable: false)
        : const <DriverOffer>[];
    if (status != null && <int>{3, 4, 5, 8}.contains(status)) {
      acceptedOffer.value = allOffers
          .where((offer) => offer.status == DriverOfferStatus.accepted)
          .firstOrNull;
      driverFound();
      return;
    }
    final offers = allOffers
        .where((offer) => offer.status == DriverOfferStatus.pending)
        .where((offer) => offer.expiresAt == null ||
            offer.expiresAt!.isAfter(DateTime.now()))
        .toList(growable: false);
    driverOffers.assignAll(offers);
    receivedOffersCount.value = offers.length;
    _updateOffersExhausted();
  }

  Future<void> _refreshOffersSnapshotSafely(String requestId) async {
    try {
      await _refreshOffersSnapshot(requestId);
    } catch (_) {
      // The next reconnect or explicit retry can restore the current snapshot.
    }
  }

  void _handleHubEvent(TrackingHubEvent event) {
    final payload = event.payload;
    final rideId = '${payload['rideId'] ?? payload['rideID'] ?? ''}';
    if (rideId != _requestId) return;
    if (event.name == 'rideUnavailable') {
      if (!isSearchingForDriver.value) return;
      isSearchingForDriver.value = false;
      offersExhausted.value = true;
      driverOffers.clear();
      _offersDeadlineTimer?.cancel();
      unawaited(Get.find<TrackingHubService>()
          .setRideSubscriptions(const <int>{}));
      return;
    }
    if (event.name != 'offerReceived' && event.name != 'offerUpdated') return;
    final offer = _repository.mapRealtimeOffer(payload);
    if (offer == null) return;
    final index = driverOffers.indexWhere((item) => item.id == offer.id);
    if (offer.status == DriverOfferStatus.pending) {
      if (index < 0) {
        driverOffers.add(offer);
        receivedOffersCount.value++;
      } else {
        driverOffers[index] = offer;
      }
      offersExhausted.value = false;
    } else if (offer.status == DriverOfferStatus.accepted &&
        int.tryParse('${payload['rideStatus']}') == 3) {
      acceptedOffer.value = offer;
      negotiationStatus.value = NegotiationStatus.accepted;
      _offersDeadlineTimer?.cancel();
      if (!isDriverAssigned.value) driverFound();
    } else if (offer.status == DriverOfferStatus.rejected ||
        offer.status == DriverOfferStatus.expired) {
      _dismissOffer(offer.id);
    }
  }

  Future<void> acceptOffer(DriverOffer offer) async {
    final requestId = _requestId;
    if (requestId == null) return;
    await _repository.acceptOffer(requestId, offer.id);
    acceptedOffer.value = offer;
    driverOffers.assignAll(
      driverOffers.map(
        (item) => item.copyWith(
          status: item.id == offer.id
              ? DriverOfferStatus.accepted
              : DriverOfferStatus.rejected,
        ),
      ),
    );
    negotiationStatus.value = NegotiationStatus.accepted;
    driverFound();
  }

  Future<void> rejectOffer(DriverOffer offer) async {
    final requestId = _requestId;
    if (requestId == null) return;
    await _repository.rejectOffer(requestId, offer.id);
    _dismissOffer(offer.id);
  }

  void expireOffer(DriverOffer offer) {
    final index = driverOffers.indexWhere((item) => item.id == offer.id);
    if (index < 0 || driverOffers[index].status != DriverOfferStatus.pending) {
      return;
    }
    _dismissOffer(offer.id);
  }

  void _dismissOffer(String offerId) {
    if (!driverOffers.any((offer) => offer.id == offerId) ||
        removingOfferIds.contains(offerId)) {
      return;
    }
    removingOfferIds.add(offerId);
    Future<void>.delayed(const Duration(milliseconds: 320), () {
      driverOffers.removeWhere((offer) => offer.id == offerId);
      removingOfferIds.remove(offerId);
      _updateOffersExhausted();
    });
  }

  void _updateOffersExhausted() {
    offersExhausted.value = offersStreamDone.value && driverOffers.isEmpty;
    if (offersExhausted.value) {
      _recipientTimer?.cancel();
      _offersDeadlineTimer?.cancel();
      isSearchingForDriver.value = false;
      if (Get.isRegistered<TrackingHubService>()) {
        unawaited(Get.find<TrackingHubService>()
            .setRideSubscriptions(const <int>{}));
      }
    }
  }

  void acknowledgeOffersExhausted() => offersExhausted.value = false;

  Future<void> retryDriverSearch() async {
    offersExhausted.value = false;
    offersStreamDone.value = false;
    await requestRide();
  }

  Future<void> cancelDriverSearch() async {
    final requestId = _requestId;
    if (requestId != null) await _repository.cancelRequest(requestId);
    offersExhausted.value = false;
    driverOffers.clear();
    requestRecipients.clear();
    _recipientTimer?.cancel();
    _offersDeadlineTimer?.cancel();
    isSearchingForDriver.value = false;
    cancelRide('ألغى المستخدم البحث عن سائق');
  }

  Future<void> cancelActiveRide(String reason) async {
    final requestId = _requestId;
    if (requestId != null) await _repository.cancelRequest(requestId);
    _trackingTimer?.cancel();
    await _passengerPositionSubscription?.cancel();
    trackedDriver.value = null;
    trackedPassenger.value = null;
    isDriverAssigned.value = false;
    acceptedOffer.value = null;
    cancelRide(reason);
  }

  void driverFound() {
    _recipientTimer?.cancel();
    _offersDeadlineTimer?.cancel();
    isSearchingForDriver.value = false;
    isDriverAssigned.value = true;
    if (AppEnvironment.useDemoData) startDemoTracking();
    Get.offNamed<void>(RideRoutes.driverLocation);
  }

  void cancelRide(String reason) {
    _recipientTimer?.cancel();
    _offersDeadlineTimer?.cancel();
    cancellationReason.value = reason;
    isSearchingForDriver.value = false;
    if (Get.isRegistered<TrackingHubService>()) {
      unawaited(Get.find<TrackingHubService>()
          .setRideSubscriptions(const <int>{}));
    }
    Get.offNamed<void>(RideRoutes.requestThanks);
  }

  void updateBottomNavigation(int index) {
    if (bottomNavigationIndex.value == index) return;
    final route = switch (index) {
      0 => RideRoutes.homeTransport,
      1 => autoStartTransport.value
          ? RideRoutes.homeTransport
          : AccountRoutes.favourites,
      2 => AccountRoutes.wallet,
      3 => AccountRoutes.offers,
      _ => AccountRoutes.profile,
    };
    if (index != 0 && !_session.requireAuthentication(returnRoute: route)) {
      return;
    }
    bottomNavigationIndex.value = index;
  }

  @override
  void onClose() {
    _hubEventSubscription?.cancel();
    _hubConnectionSubscription?.cancel();
    _trackingTimer?.cancel();
    _recipientTimer?.cancel();
    _offersDeadlineTimer?.cancel();
    _passengerPositionSubscription?.cancel();
    super.onClose();
  }
}

