import 'package:get/get.dart';

import '../../features/auth/routes/auth_routes.dart';
import '../../features/driver/driver_routes.dart';

abstract final class AppPages {
  static List<GetPage<dynamic>> get pages => appPages;
}

List<GetPage<dynamic>> get appPages => <GetPage<dynamic>>[
      ...driverPages,
      ...authPages,
    ];
