import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';

import '../../../../core/services/auth_session_service.dart';
import '../../../driver/driver_routes.dart';
import '../../routes/auth_routes.dart';

class SplashController extends GetxController {
  SplashController({GetStorage? storage}) : _storage = storage ?? GetStorage();
  final GetStorage _storage;

  @override
  void onReady() {
    super.onReady();
    _continueAfterSplash();
  }

  Future<void> _continueAfterSplash() async {
    await Future<void>.delayed(const Duration(milliseconds: 1450));
    if (isClosed) return;
    final hasSeenOnboarding =
        _storage.read<bool>('has_seen_onboarding') ?? false;
    final session = Get.find<AuthSessionService>();
    if (session.hasPendingNotificationOpen) {
      if (session.isAuthenticated.value) {
        session.continueAfterAuthentication(fallbackRoute: DriverRoutes.home);
      } else {
        Get.offAllNamed<void>(DriverRoutes.login);
      }
      return;
    }
    if (!hasSeenOnboarding) {
      Get.offAllNamed<void>(AuthRoutes.onboardingOne);
      return;
    }
    Get.offAllNamed<void>(
      session.isAuthenticated.value ? DriverRoutes.home : DriverRoutes.login,
    );
  }
}
