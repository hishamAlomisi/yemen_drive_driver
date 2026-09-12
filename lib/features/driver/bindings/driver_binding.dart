import 'package:get/get.dart';

import '../../../core/network/api_client.dart';
import '../../../core/services/auth_session_service.dart';
import '../controllers/driver_controller.dart';
import '../controllers/driver_login_controller.dart';
import '../providers/driver_provider.dart';
import '../repositories/driver_repository.dart';

class DriverBinding extends Bindings {
  @override
  void dependencies() {
    final provider = DriverProvider(Get.find<ApiClient>());
    Get.lazyPut<DriverRepository>(() => ApiDriverRepository(provider));
    Get.lazyPut<DriverLoginController>(
      () => DriverLoginController(
        Get.find<DriverRepository>(),
        Get.find<AuthSessionService>(),
      ),
    );
    Get.lazyPut<DriverController>(
      () => DriverController(
        Get.find<DriverRepository>(),
        Get.find<AuthSessionService>(),
      ),
    );
  }
}
