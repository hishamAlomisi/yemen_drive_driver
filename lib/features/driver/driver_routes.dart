import 'package:get/get.dart';

import 'bindings/driver_binding.dart';
import 'views/driver_home_view.dart';
import 'views/driver_history_view.dart';
import 'views/driver_login_view.dart';
import 'views/driver_navigation_view.dart';
import 'views/driver_wallet_view.dart';

abstract final class DriverRoutes {
  static const login = '/driver/login';
  static const home = '/driver/home';
  static const history = '/driver/history';
  static const navigation = '/driver/navigation';
  static const wallet = '/driver/wallet';
}

final List<GetPage<dynamic>> driverPages = <GetPage<dynamic>>[
  GetPage<dynamic>(
    name: DriverRoutes.login,
    page: DriverLoginView.new,
    binding: DriverBinding(),
  ),
  GetPage<dynamic>(
    name: DriverRoutes.home,
    page: DriverHomeView.new,
    binding: DriverBinding(),
  ),
  GetPage<dynamic>(
    name: DriverRoutes.history,
    page: DriverHistoryView.new,
    binding: DriverBinding(),
  ),
  GetPage<dynamic>(
    name: DriverRoutes.navigation,
    page: DriverNavigationView.new,
    binding: DriverBinding(),
  ),
  GetPage<dynamic>(
    name: DriverRoutes.wallet,
    page: DriverWalletView.new,
    binding: DriverBinding(),
  ),
];
