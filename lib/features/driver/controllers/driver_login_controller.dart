import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/services/auth_session_service.dart';
import '../models/driver_models.dart';
import '../repositories/driver_repository.dart';
import '../driver_routes.dart';

class DriverLoginController extends GetxController {
  DriverLoginController(this._repository, this._session);
  final DriverRepository _repository;
  final AuthSessionService _session;
  final phoneController = TextEditingController();
  final passwordController = TextEditingController();
  final otpController = TextEditingController();
  final isLoading = false.obs;
  final RxnString challengeId = RxnString();
  final RxnString error = RxnString();

  Future<void> submit() async {
    if (isLoading.value) return;
    await _run(() async {
      final result = await _repository.login(DriverLoginRequest(
          phone: phoneController.text.trim(),
          password: passwordController.text));
      if (result.requiresOtp) {
        challengeId.value = result.challengeId;
        return;
      }
      await _activate(result);
    });
  }

  Future<void> verifyOtp() async {
    if (isLoading.value || challengeId.value == null) return;
    await _run(() async {
      final result = await _repository.verifyOtp(
          phone: phoneController.text.trim(),
          code: otpController.text.trim(),
          challengeId: challengeId.value!);
      await _activate(result);
    });
  }

  Future<void> _activate(DriverAuthResult result) async {
    final access = result.accessToken;
    if (access == null || access.isEmpty)
      throw const FormatException('لم يتم استلام رمز الدخول');
    await _session.activate(
        accessToken: access,
        refreshToken: result.refreshToken ?? '',
        remember: true,
        userId: result.userId);
    Get.offAllNamed<void>(DriverRoutes.home);
  }

  Future<void> _run(Future<void> Function() action) async {
    isLoading.value = true;
    error.value = null;
    try {
      await action();
    } catch (exception) {
      error.value = exception.toString();
    } finally {
      isLoading.value = false;
    }
  }

  @override
  void onClose() {
    phoneController.dispose();
    passwordController.dispose();
    otpController.dispose();
    super.onClose();
  }
}
