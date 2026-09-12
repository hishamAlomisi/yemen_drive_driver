import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/driver_login_controller.dart';

class DriverLoginView extends GetView<DriverLoginController> {
  const DriverLoginView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Obx(
                () => ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    const Icon(Icons.local_taxi_rounded,
                        size: 72, color: Color(0xff087ea6)),
                    const SizedBox(height: 12),
                    Text(
                      'يمن درايف للسائق',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      controller.challengeId.value == null
                          ? 'سجل الدخول لإدارة رحلاتك وعروضك'
                          : 'أدخل رمز OTP المطبوع في Console',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: controller.phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'رقم الهاتف',
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (controller.challengeId.value == null)
                      TextField(
                        controller: controller.passwordController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'كلمة المرور',
                          prefixIcon: Icon(Icons.lock_outline),
                        ),
                      ),
                    if (controller.challengeId.value != null)
                      TextField(
                        controller: controller.otpController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'رمز OTP',
                          prefixIcon: Icon(Icons.verified_outlined),
                        ),
                      ),
                    const SizedBox(height: 16),
                    if (controller.error.value != null)
                      Text(
                        controller.error.value!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: controller.isLoading.value
                          ? null
                          : controller.challengeId.value == null
                              ? controller.submit
                              : controller.verifyOtp,
                      icon: controller.isLoading.value
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login),
                      label: Text(
                        controller.challengeId.value == null
                            ? 'تسجيل الدخول'
                            : 'تحقق ودخول',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
