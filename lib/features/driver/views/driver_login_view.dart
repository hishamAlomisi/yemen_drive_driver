import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../controllers/driver_login_controller.dart';
import '../widgets/driver_design.dart';

class DriverLoginView extends StatefulWidget {
  const DriverLoginView({super.key});
  @override
  State<DriverLoginView> createState() => _DriverLoginViewState();
}

class _DriverLoginViewState extends State<DriverLoginView> {
  DriverLoginController get controller => Get.find<DriverLoginController>();
  bool _obscure = true;
  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          body: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 800;
              if (wide) {
                return Row(
                  children: [
                    Expanded(child: _intro(context, true)),
                    Expanded(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 480),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(32),
                            child: _form(context),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              }
              return SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: Column(
                  children: [
                    _intro(context, false),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 26, 24, 24),
                      child: _form(context),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );

  Widget _intro(BuildContext context, bool wide) => Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          color: forest,
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(36)),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding:
                EdgeInsets.fromLTRB(wide ? 48 : 28, 26, wide ? 48 : 28, 20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [DriverBrand(light: true), _PartnerTag()],
                ),
                const SizedBox(height: 28),
                const Text(
                  'الطريق لك.\nوالفرص أمامك.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 34,
                    height: 1.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'كل رحلة بداية جديدة مع يمن درايف.',
                  style: TextStyle(color: Color(0xFFBED0C8), fontSize: 13),
                ),
                SizedBox(
                  height: wide ? 250 : 135,
                  width: double.infinity,
                  child: const JourneyArtwork(),
                ),
                Row(
                  children: [
                    Container(
                      width: 24,
                      height: 3,
                      decoration: BoxDecoration(
                        color: copper,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(width: 6, height: 3, color: Colors.white24),
                    const SizedBox(width: 6),
                    Container(width: 6, height: 3, color: Colors.white24),
                    const Spacer(),
                    const Flexible(
                      child: Text(
                        'YEMEN DRIVE  /  DRIVER',
                        textDirection: TextDirection.ltr,
                        style: TextStyle(
                          color: copper,
                          fontSize: 9,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );

  Widget _form(BuildContext context) => Obx(() {
        final otp = controller.challengeId.value != null;
        return AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                otp ? 'خطوة واحدة وننطلق' : 'أهلًا بعودتك، شريكنا',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              Text(
                otp
                    ? 'أدخل رمز التحقق المرسل إلى هاتفك.'
                    : 'سجّل دخولك، وابدأ رحلتك القادمة.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              TextField(
                key: const ValueKey('driver-phone'),
                controller: controller.phoneController,
                enabled: !controller.isLoading.value,
                keyboardType: TextInputType.phone,
                textDirection: TextDirection.ltr,
                autofillHints: const [AutofillHints.username],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'رقم الهاتف',
                  prefixIcon: Icon(Icons.phone_outlined),
                  hintText: '7XX XXX XXX',
                ),
              ),
              const SizedBox(height: 14),
              if (!otp)
                TextField(
                  key: const ValueKey('driver-password'),
                  controller: controller.passwordController,
                  enabled: !controller.isLoading.value,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.password],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => controller.submit(),
                  decoration: InputDecoration(
                    labelText: 'كلمة المرور',
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      tooltip:
                          _obscure ? 'إظهار كلمة المرور' : 'إخفاء كلمة المرور',
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                ),
              if (otp)
                TextField(
                  key: const ValueKey('driver-otp'),
                  controller: controller.otpController,
                  enabled: !controller.isLoading.value,
                  keyboardType: TextInputType.number,
                  textDirection: TextDirection.ltr,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => controller.verifyOtp(),
                  decoration: const InputDecoration(
                    labelText: 'رمز التحقق',
                    prefixIcon: Icon(Icons.verified_user_outlined),
                  ),
                ),
              if (!otp)
                CheckboxListTile(
                  value: controller.rememberMe.value,
                  onChanged: controller.isLoading.value
                      ? null
                      : controller.toggleRememberMe,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    'تذكرني على هذا الجهاز',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              if (controller.error.value != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      controller.error.value!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: controller.isLoading.value
                    ? null
                    : otp
                        ? controller.verifyOtp
                        : controller.submit,
                child: controller.isLoading.value
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(otp ? 'تحقق ودخول' : 'تسجيل الدخول'),
                          const SizedBox(width: 14),
                          const Icon(Icons.arrow_back_rounded, size: 20),
                        ],
                      ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 15,
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      'حسابك بأمان، وطريقك بثقة',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      });
}

class _PartnerTag extends StatelessWidget {
  const _PartnerTag();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(color: copper.withValues(alpha: .3)),
          borderRadius: BorderRadius.circular(30),
        ),
        child:
            const Text('للسائق', style: TextStyle(color: copper, fontSize: 11)),
      );
}
