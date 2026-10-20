import 'package:get/get.dart';

import '../../../../core/services/auth_session_service.dart';
import '../../../../core/services/startup_connection_service.dart';
import '../../../driver/driver_routes.dart';

class SplashController extends GetxController {
  SplashController(this.connection);

  final StartupConnectionService connection;
  bool _continuing = false;

  @override
  void onReady() {
    super.onReady();
    retry();
  }

  Future<void> retry() async {
    if (_continuing) return;
    _continuing = true;
    try {
      final connected = connection.isVerified || await connection.verify();
      if (!connected || isClosed) return;
      _continueAfterSplash();
    } finally {
      _continuing = false;
    }
  }

  void _continueAfterSplash() {
    final session = Get.find<AuthSessionService>();
    if (session.hasPendingNotificationOpen) {
      if (session.isAuthenticated.value) {
        session.continueAfterAuthentication(fallbackRoute: DriverRoutes.home);
      } else {
        Get.offAllNamed<void>(DriverRoutes.login);
      }
      return;
    }
    Get.offAllNamed<void>(
      session.isAuthenticated.value ? DriverRoutes.home : DriverRoutes.login,
    );
  }
}
