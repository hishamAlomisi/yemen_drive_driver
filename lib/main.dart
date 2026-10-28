import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/config/app_environment.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await Firebase.initializeApp();
  }
  AppEnvironment.configure(
    baseUrl: AppEnvironment.defaultBaseUrl,
    signalRHubUrl: const String.fromEnvironment('SIGNALR_HUB_URL'),
  );
  runApp(const EasyRideApp());
}
