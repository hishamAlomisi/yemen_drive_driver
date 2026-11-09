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
    _bindRepository();
    Get.lazyPut<DriverController>(
      () => DriverController(
        Get.find<DriverRepository>(),
        Get.find<AuthSessionService>(),
      ),
    );
  }
}

class DriverLoginBinding extends Bindings {
  @override
  void dependencies() {
    _bindRepository();
    Get.lazyPut<DriverLoginController>(
      () => DriverLoginController(
        Get.find<DriverRepository>(),
        Get.find<AuthSessionService>(),
      ),
    );
  }
}

void _bindRepository() {
  final provider = DriverProvider(Get.find<ApiClient>());
  Get.lazyPut<DriverRepository>(() => ApiDriverRepository(provider));
}
