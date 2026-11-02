import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:yemen_drive_driver/core/config/app_environment.dart';
import 'package:yemen_drive_driver/core/network/api_client.dart';
import 'package:yemen_drive_driver/core/realtime/tracking_hub_service.dart';
import 'package:yemen_drive_driver/core/storage/secure_storage_service.dart';

class _Storage extends SecureStorageService {
  @override
  Future<String?> get accessToken async => null;
}

class _Adapter implements HttpClientAdapter {
  RequestOptions? request;
  bool reject = false;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancel) async {
    request = options;
    return ResponseBody.fromString('{}', reject ? 400 : 200, headers: {
      Headers.contentTypeHeader: ['application/json']
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AppEnvironment.configure(baseUrl: 'http://localhost/api'));
  tearDown(Get.reset);
  test('unavailable Hub retries GPS through the authenticated HTTP client',
      () async {
    final storage = _Storage();
    final client = await ApiClient(storage).init();
    final adapter = _Adapter();
    client.dio.httpClientAdapter = adapter;
    Get.put<ApiClient>(client);
    final hub = TrackingHubService(storage);
    final payload = <String, Object?>{
      'latitude': 15.36,
      'longitude': 44.19,
      'accuracy': 10,
      'observedAtUtc': '2026-11-02T16:00:00Z'
    };
    expect(await hub.publishDriverLocation(payload), true);
    expect(adapter.request?.uri.path, '/api/tracking/driver-location');
    expect(adapter.request?.data, payload);
    adapter.reject = true;
    expect(await hub.publishDriverLocation(payload), false,
        reason: 'Rejected GPS must not be shown as successfully sent.');
    await hub.disconnect();
  });
}
